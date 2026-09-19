//! Playing files while they download (`dj_audio::growing`): a writer thread
//! copies a fixture to disk bit by bit, the way yt-dlp does, while the
//! player reads it.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use dj_audio::ffi::*;
use dj_audio::{growing, Player, State};

const RATE: usize = 48_000;
const BLOCK: usize = 480;

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

fn temp_path(name: &str) -> PathBuf {
    static N: AtomicUsize = AtomicUsize::new(0);
    let n = N.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("dj_growing_{}_{n}_{name}", std::process::id()))
}

fn append(path: &Path, bytes: &[u8]) {
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .unwrap();
    f.write_all(bytes).unwrap();
    f.flush().unwrap();
}

/// Pulls until the track ends (or `limit` passes), in 10 ms blocks taken
/// only when there is audio for them. Returns the left channel.
fn play_out(p: &Player, limit: Duration) -> Vec<f32> {
    let deadline = Instant::now() + limit;
    let mut left = Vec::new();
    let mut buf = [0i16; BLOCK * 2];
    loop {
        let (avail, done) = p.buffer_state();
        if avail >= BLOCK || (done && avail > 0) {
            let n = p.pull(&mut buf, 2, RATE as i32);
            left.extend(buf[..n * 2].chunks(2).map(|s| s[0] as f32 / 32767.0));
            continue;
        }
        let state = p.status().state;
        if matches!(state, State::Ended | State::Error) {
            return left;
        }
        assert!(Instant::now() < deadline, "stuck in {state:?}");
        thread::sleep(Duration::from_millis(2));
    }
}

fn zero_crossings(x: &[f32]) -> usize {
    x.windows(2)
        .filter(|w| (w[0] < 0.0) != (w[1] < 0.0))
        .count()
}

/// The fixtures' left channel is a 1 kHz tone: about 2000 crossings a
/// second.
fn assert_tone(x: &[f32], label: &str) {
    let crossings = zero_crossings(x) as f64 / (x.len() as f64 / RATE as f64);
    assert!(
        (1900.0..2100.0).contains(&crossings),
        "{label}: {crossings} crossings/s"
    );
}

/// Writes `data` to `path` in `parts`, `pause` apart, then reports the
/// download done.
fn spawn_writer(
    path: PathBuf,
    data: Vec<u8>,
    parts: usize,
    pause: Duration,
    ok: bool,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let size = data.len().div_ceil(parts);
        for chunk in data.chunks(size) {
            append(&path, chunk);
            thread::sleep(pause);
        }
        growing::finish(&path, ok);
    })
}

#[test]
fn plays_while_downloading() {
    for (name, announce_len) in [
        ("tone_gap_frag_elst.m4a", true),
        ("tone_gap_frag.m4a", false),
        ("tone_gap.mp3", true),
        ("tone_gap.mp3", false),
        // moov at the end: nothing plays before the whole file is in, but
        // it still plays.
        ("tone_gap.m4a", true),
    ] {
        let label = format!("{name} (length announced: {announce_len})");
        let data = std::fs::read(fixture(name)).unwrap();
        let path = temp_path(name);
        let total = if announce_len { data.len() as u64 } else { 0 };
        growing::begin(&path, total, 4000);

        // The first slice lands before the player opens, the rest over
        // about a second, far slower than the player could read a file.
        let first = data.len() / 10;
        append(&path, &data[..first]);
        let p = Player::new();
        let started = Instant::now();
        assert_eq!(p.open(&path, 0, 1), 0, "{label}");
        assert!(
            started.elapsed() < Duration::from_millis(200),
            "{label}: open waited for the download"
        );
        let writer = spawn_writer(
            path.clone(),
            data[first..].to_vec(),
            20,
            Duration::from_millis(50),
            true,
        );

        let left = play_out(&p, Duration::from_secs(20));
        writer.join().unwrap();
        let status = p.status();
        assert_eq!(status.state, State::Ended, "{label}");
        let secs = left.len() as f64 / RATE as f64;
        assert!((3.9..4.1).contains(&secs), "{label}: played {secs} s");
        assert_tone(&left[RATE / 10..RATE * 19 / 10], &label);
        assert!(
            (3900..4100).contains(&status.duration_ms),
            "{label}: duration {}",
            status.duration_ms
        );
        let _ = std::fs::remove_file(&path);
    }
}

#[test]
fn starts_before_the_download_ends() {
    let data = std::fs::read(fixture("tone_gap_frag_elst.m4a")).unwrap();
    let path = temp_path("early.m4a");
    growing::begin(&path, data.len() as u64, 4000);
    let half = data.len() / 2;
    append(&path, &data[..half]);

    let p = Player::new();
    assert_eq!(p.open(&path, 0, 1), 0);
    // Half the file is there and the rest never comes until we say so:
    // audio must flow anyway.
    let deadline = Instant::now() + Duration::from_secs(5);
    while p.buffer_state().0 < RATE {
        assert!(Instant::now() < deadline, "no audio from half a file");
        thread::sleep(Duration::from_millis(5));
    }
    assert_ne!(p.status().state, State::Error);

    append(&path, &data[half..]);
    growing::finish(&path, true);
    let left = play_out(&p, Duration::from_secs(10));
    let secs = left.len() as f64 / RATE as f64;
    assert!((3.9..4.1).contains(&secs), "played {secs} s");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn file_appears_after_open() {
    let data = std::fs::read(fixture("tone_gap.mp3")).unwrap();
    let path = temp_path("late.mp3");
    growing::begin(&path, 0, 4000);
    let p = Player::new();
    assert_eq!(p.open(&path, 0, 1), 0);
    thread::sleep(Duration::from_millis(100));
    assert_eq!(p.status().state, State::Buffering);
    let writer = spawn_writer(path.clone(), data, 4, Duration::from_millis(20), true);
    let left = play_out(&p, Duration::from_secs(10));
    writer.join().unwrap();
    assert!(left.len() > RATE * 39 / 10, "played {} frames", left.len());
    let _ = std::fs::remove_file(&path);
}

#[test]
fn broken_download_ends_early() {
    let data = std::fs::read(fixture("tone_gap_frag_elst.m4a")).unwrap();
    let path = temp_path("broken.m4a");
    growing::begin(&path, data.len() as u64, 4000);
    let p = Player::new();
    assert_eq!(p.open(&path, 0, 1), 0);
    let writer = spawn_writer(
        path.clone(),
        data[..data.len() / 2].to_vec(),
        4,
        Duration::from_millis(20),
        false,
    );
    let left = play_out(&p, Duration::from_secs(10));
    writer.join().unwrap();
    let secs = left.len() as f64 / RATE as f64;
    assert!((1.0..3.0).contains(&secs), "played {secs} s of half a file");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn missing_download_fails() {
    let path = temp_path("never.m4a");
    growing::begin(&path, 0, 0);
    let p = Player::new();
    assert_eq!(p.open(&path, 0, 7), 0);
    thread::sleep(Duration::from_millis(50));
    growing::finish(&path, false);
    let deadline = Instant::now() + Duration::from_secs(5);
    while p.status().state != State::Error {
        assert!(Instant::now() < deadline, "{:?}", p.status());
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(p.status().track_id, 7);
}

#[test]
fn seek_past_what_arrived_waits_for_it() {
    let data = std::fs::read(fixture("tone_gap_frag_elst.m4a")).unwrap();
    let path = temp_path("seek.m4a");
    growing::begin(&path, data.len() as u64, 4000);
    let quarter = data.len() / 4;
    append(&path, &data[..quarter]);
    let p = Player::new();
    assert_eq!(p.open(&path, 0, 1), 0);
    // Returns at once although 3 s isn't on disk yet.
    let started = Instant::now();
    assert_eq!(p.seek(3000), 0);
    assert!(started.elapsed() < Duration::from_millis(200));
    thread::sleep(Duration::from_millis(100));
    assert_eq!(p.status().state, State::Buffering);
    assert_eq!(p.status().position_ms, 3000);

    let writer = spawn_writer(
        path.clone(),
        data[quarter..].to_vec(),
        6,
        Duration::from_millis(30),
        true,
    );
    let left = play_out(&p, Duration::from_secs(10));
    writer.join().unwrap();
    let secs = left.len() as f64 / RATE as f64;
    assert!((0.9..1.1).contains(&secs), "played {secs} s after 3 s");
    assert_tone(&left[RATE / 10..RATE * 9 / 10], "after seek");
    let _ = std::fs::remove_file(&path);
}

#[test]
fn stop_and_free_while_waiting_do_not_hang() {
    let path = temp_path("stalled.m4a");
    let data = std::fs::read(fixture("tone_gap_frag_elst.m4a")).unwrap();
    growing::begin(&path, data.len() as u64, 4000);
    append(&path, &data[..64]);

    let p = Player::new();
    assert_eq!(p.open(&path, 0, 1), 0);
    thread::sleep(Duration::from_millis(50));
    let started = Instant::now();
    p.stop();
    assert_eq!(p.status().state, State::Idle);

    assert_eq!(p.open(&path, 0, 2), 0);
    thread::sleep(Duration::from_millis(50));
    drop(p);
    assert!(started.elapsed() < Duration::from_secs(1));
    growing::finish(&path, false);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn ffi_growing_calls() {
    unsafe {
        commet_music_file_growing(std::ptr::null(), 0, 0);
        commet_music_file_done(std::ptr::null(), 1);
    }
    assert_eq!(commet_music_abi_version(), 2);

    let data = std::fs::read(fixture("tone_gap.mp3")).unwrap();
    let path = temp_path("ffi.mp3");
    let c_path = std::ffi::CString::new(path.to_str().unwrap()).unwrap();
    unsafe {
        commet_music_file_growing(c_path.as_ptr(), data.len() as u64, 4000);
        let h = commet_music_new();
        assert_eq!(commet_music_open(h, c_path.as_ptr(), 0, 1), 0);
        append(&path, &data);
        commet_music_file_done(c_path.as_ptr(), 1);
        let (tx, rx) = mpsc::channel();
        let hh = h as usize;
        thread::spawn(move || {
            let h = hh as *mut std::ffi::c_void;
            let mut buf = [0i16; BLOCK * 2];
            let mut audio = 0;
            let deadline = Instant::now() + Duration::from_secs(10);
            while audio < RATE && Instant::now() < deadline {
                audio += commet_music_pull(h, buf.as_mut_ptr(), BLOCK, 2, RATE as i32);
                thread::sleep(Duration::from_millis(1));
            }
            tx.send(audio).unwrap();
        });
        assert!(rx.recv().unwrap() >= RATE);
        commet_music_free(h);
    }
    let _ = std::fs::remove_file(&path);
}
