//! Files still being downloaded, so a song plays while yt-dlp writes it.
//!
//! Dart registers a path before yt-dlp has finished it (`begin`) and says
//! when the download ends (`finish`). A reader of a registered file waits
//! for bytes that aren't there yet instead of taking the current end of the
//! file for the end of the song. Seeking works anywhere: reading past what
//! has arrived waits for it.

use std::collections::HashMap;
use std::fs::File;
use std::io::{self, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use symphonia::core::io::MediaSource;

const GROWING: u8 = 0;
const COMPLETE: u8 = 1;
const FAILED: u8 = 2;

/// How often a reader waiting for data looks again.
const POLL: Duration = Duration::from_millis(20);

pub(crate) struct Growth {
    /// Final size in bytes, 0 when unknown.
    total: AtomicU64,
    /// Length yt-dlp reported, 0 when unknown: stands in for a duration
    /// scan, which would wait for the whole file.
    duration_ms: u64,
    state: AtomicU8,
}

impl Growth {
    pub fn duration_ms(&self) -> Option<u64> {
        (self.duration_ms > 0).then_some(self.duration_ms)
    }
}

fn registry() -> &'static Mutex<HashMap<PathBuf, Arc<Growth>>> {
    static REGISTRY: OnceLock<Mutex<HashMap<PathBuf, Arc<Growth>>>> = OnceLock::new();
    REGISTRY.get_or_init(Default::default)
}

fn lock() -> std::sync::MutexGuard<'static, HashMap<PathBuf, Arc<Growth>>> {
    registry().lock().unwrap_or_else(|e| e.into_inner())
}

/// `path` is being written; `total_len` and `duration_ms` are 0 if unknown.
pub fn begin(path: &Path, total_len: u64, duration_ms: u64) {
    lock().insert(
        path.to_path_buf(),
        Arc::new(Growth {
            total: AtomicU64::new(total_len),
            duration_ms,
            state: AtomicU8::new(GROWING),
        }),
    );
}

/// The download of `path` ended: readers take its end as final, or fail
/// if it broke off.
pub fn finish(path: &Path, ok: bool) {
    if let Some(g) = lock().remove(path) {
        if ok {
            // The finished file is the truth, whatever was announced.
            if let Ok(meta) = std::fs::metadata(path) {
                g.total.store(meta.len(), Ordering::Release);
            }
        }
        g.state
            .store(if ok { COMPLETE } else { FAILED }, Ordering::Release);
    }
}

pub(crate) fn lookup(path: &Path) -> Option<Arc<Growth>> {
    lock().get(path).cloned()
}

/// Reads a file that may still be growing. Waits never outlast `stop`.
pub(crate) struct GrowingFile {
    file: File,
    pos: u64,
    growth: Arc<Growth>,
    stop: Arc<AtomicBool>,
}

fn stopped() -> io::Error {
    // Not `Interrupted`: `read_exact` would retry that forever.
    io::Error::other("stopped")
}

impl GrowingFile {
    /// Opens `path`, waiting for yt-dlp to create it.
    pub fn open(path: &Path, growth: Arc<Growth>, stop: Arc<AtomicBool>) -> io::Result<Self> {
        loop {
            match File::open(path) {
                Ok(file) => {
                    return Ok(GrowingFile {
                        file,
                        pos: 0,
                        growth,
                        stop,
                    })
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => {
                    if growth.state.load(Ordering::Acquire) != GROWING {
                        return Err(e);
                    }
                    if stop.load(Ordering::Acquire) {
                        return Err(stopped());
                    }
                    thread::sleep(POLL);
                }
                Err(e) => return Err(e),
            }
        }
    }

    fn total(&self) -> Option<u64> {
        match self.growth.total.load(Ordering::Acquire) {
            0 => None,
            n => Some(n),
        }
    }

    /// The final length, waiting for the download to end if it wasn't
    /// announced.
    fn wait_for_total(&self) -> io::Result<u64> {
        loop {
            if let Some(total) = self.total() {
                return Ok(total);
            }
            match self.growth.state.load(Ordering::Acquire) {
                COMPLETE => return Ok(self.file.metadata()?.len()),
                FAILED => return Err(io::ErrorKind::UnexpectedEof.into()),
                _ => {}
            }
            if self.stop.load(Ordering::Acquire) {
                return Err(stopped());
            }
            thread::sleep(POLL);
        }
    }
}

impl Read for GrowingFile {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        loop {
            // Read the state before the file: bytes written before it said
            // complete are then sure to be seen.
            let state = self.growth.state.load(Ordering::Acquire);
            if self.total().is_some_and(|t| self.pos >= t) && state != FAILED {
                return Ok(0);
            }
            let n = self.file.read(buf)?;
            if n > 0 {
                self.pos += n as u64;
                return Ok(n);
            }
            match state {
                COMPLETE => return Ok(0),
                FAILED => return Err(io::ErrorKind::UnexpectedEof.into()),
                _ => {}
            }
            if self.stop.load(Ordering::Acquire) {
                return Err(stopped());
            }
            thread::sleep(POLL);
        }
    }
}

impl Seek for GrowingFile {
    fn seek(&mut self, pos: SeekFrom) -> io::Result<u64> {
        let to = match pos {
            SeekFrom::Start(n) => n,
            SeekFrom::Current(d) => self
                .pos
                .checked_add_signed(d)
                .ok_or(io::ErrorKind::InvalidInput)?,
            SeekFrom::End(d) => self
                .wait_for_total()?
                .checked_add_signed(d)
                .ok_or(io::ErrorKind::InvalidInput)?,
        };
        // Past what has arrived is fine: reads there wait.
        self.pos = self.file.seek(SeekFrom::Start(to))?;
        Ok(self.pos)
    }
}

impl MediaSource for GrowingFile {
    fn is_seekable(&self) -> bool {
        true
    }

    fn byte_len(&self) -> Option<u64> {
        self.total().or_else(|| {
            (self.growth.state.load(Ordering::Acquire) == COMPLETE)
                .then(|| self.file.metadata().ok().map(|m| m.len()))
                .flatten()
        })
    }
}
