//! Writes the "speech in a noisy room" fixture the end-to-end noise
//! suppression loops use (the browser loop in `tools/voice_dsp/`, the Dart
//! FFI test and the native loop). Generated rather than committed: it is the
//! committed `testdata/local_speech_16k.wav` over synthetic room noise, and
//! everything here is deterministic.
//!
//!   cargo run -p audio_dsp --example noisy_speech -- <out dir>
//!
//! Writes into `<out dir>`:
//!
//! * `noisy_speech_48k.wav`: mono PCM16 at 48 kHz. [`LEAD_S`] of noise, the
//!   speech over the same noise, [`TAIL_S`] of noise.
//! * `noisy_speech_48k.labels`: one character per 10 ms block of that file:
//!   `s` the user is talking, `n` only noise and far enough from speech that
//!   the gate's hold and release are over, `.` neither (do not measure).
//! * `room_noise_48k.wav`: [`ROOM_NOISE_S`] of the same noise, nobody
//!   talking.
//!
//! The levels are the ones `tests/speaker_bleed.rs` calls typical: the user
//! at -22 dBFS RMS, the room at about -40 dBFS.

use std::path::PathBuf;

use audio_dsp::resample::Resampler;
use audio_dsp::FRAME_SIZE;

const RATE: usize = 48_000;
const LEAD_S: f32 = 3.0;
const TAIL_S: f32 = 2.0;
const ROOM_NOISE_S: f32 = 16.0;
/// Only the first two utterances: long enough to measure, short enough that
/// a real-time loop stays under ten seconds.
const SPEECH_S: f32 = 5.5;
const SPEECH_DBFS: f32 = -22.0;
/// A low rumble (fan, PC) and a hiss on top of it.
const RUMBLE_DBFS: f32 = -41.0;
const HISS_DBFS: f32 = -47.0;
/// A block is speech when the clean speech in it is at least this loud.
const SPEECH_BLOCK_DBFS: f32 = -45.0;
/// Noise blocks keep this far from any speech block: the gate holds for
/// 150 ms and releases over 200 ms, and the loops add some latency.
const NOISE_GUARD_BLOCKS: usize = 45;

fn main() {
    let out_dir = PathBuf::from(
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| usage("missing <out dir>")),
    );
    std::fs::create_dir_all(&out_dir).unwrap();

    let speech_16k = read_wav_pcm16(include_bytes!("../testdata/local_speech_16k.wav"));
    let mut up = Resampler::new(16_000, RATE);
    let mut speech = vec![0.0; up.output_len(speech_16k.len())];
    up.process(&speech_16k, &mut speech);
    speech.truncate(((SPEECH_S * RATE as f32) as usize) / FRAME_SIZE * FRAME_SIZE);
    let speech = scale_to(&speech, SPEECH_DBFS);

    let lead = ((LEAD_S * RATE as f32) as usize) / FRAME_SIZE * FRAME_SIZE;
    let tail = ((TAIL_S * RATE as f32) as usize) / FRAME_SIZE * FRAME_SIZE;
    let total = lead + speech.len() + tail;

    let rumble = coloured_noise(total, 0.08, RUMBLE_DBFS, 0x5eed);
    let hiss = coloured_noise(total, 0.6, HISS_DBFS, 0xf00d);
    let mut clean = vec![0.0f32; total];
    clean[lead..lead + speech.len()].copy_from_slice(&speech);
    let noisy: Vec<f32> = (0..total).map(|i| clean[i] + rumble[i] + hiss[i]).collect();

    let blocks = total / FRAME_SIZE;
    let is_speech: Vec<bool> = (0..blocks)
        .map(|b| rms_dbfs(&clean[b * FRAME_SIZE..(b + 1) * FRAME_SIZE]) >= SPEECH_BLOCK_DBFS)
        .collect();
    let labels: String = (0..blocks)
        .map(|b| {
            if is_speech[b] {
                's'
            } else {
                let lo = b.saturating_sub(NOISE_GUARD_BLOCKS);
                let hi = (b + NOISE_GUARD_BLOCKS).min(blocks - 1);
                if is_speech[lo..=hi].iter().any(|&s| s) {
                    '.'
                } else {
                    'n'
                }
            }
        })
        .collect();

    std::fs::write(
        out_dir.join("noisy_speech_48k.wav"),
        write_wav_pcm16(RATE, &noisy),
    )
    .unwrap();
    std::fs::write(out_dir.join("noisy_speech_48k.labels"), &labels).unwrap();

    // The same room without anyone talking, long enough to hold a noise
    // level through several changes (native_noise_test.dart, the custom
    // audio source test).
    let room = (ROOM_NOISE_S * RATE as f32) as usize;
    let rumble = coloured_noise(room, 0.08, RUMBLE_DBFS, 0x5eed);
    let hiss = coloured_noise(room, 0.6, HISS_DBFS, 0xf00d);
    let room_noise: Vec<f32> = (0..room).map(|i| rumble[i] + hiss[i]).collect();
    std::fs::write(
        out_dir.join("room_noise_48k.wav"),
        write_wav_pcm16(RATE, &room_noise),
    )
    .unwrap();
    let noise_only: Vec<f32> = (0..total).map(|i| rumble[i] + hiss[i]).collect();
    println!(
        "{}: {:.1} s, speech {:.1} dBFS, noise {:.1} dBFS, {} speech / {} noise blocks",
        out_dir.join("noisy_speech_48k.wav").display(),
        total as f32 / RATE as f32,
        rms_dbfs(&speech),
        rms_dbfs(&noise_only),
        labels.matches('s').count(),
        labels.matches('n').count(),
    );
}

fn usage(why: &str) -> ! {
    eprintln!("{why}\nusage: cargo run -p audio_dsp --example noisy_speech -- <out dir>");
    std::process::exit(2);
}

/// White noise through a one-pole low pass (`a` closer to 1 is brighter),
/// scaled to `level_dbfs` RMS.
fn coloured_noise(n: usize, a: f32, level_dbfs: f32, seed: u64) -> Vec<f32> {
    let mut state = seed;
    let mut y = 0.0f32;
    let raw: Vec<f32> = (0..n)
        .map(|_| {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let white = ((state >> 33) as f32 / (1u64 << 31) as f32) * 2.0 - 1.0;
            y += (white - y) * a;
            y
        })
        .collect();
    scale_to(&raw, level_dbfs)
}

fn rms_dbfs(x: &[f32]) -> f32 {
    let mean_sq = x.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>() / x.len().max(1) as f64;
    let rms = mean_sq.sqrt() as f32 / 32768.0;
    if rms <= 1e-9 {
        -120.0
    } else {
        20.0 * rms.log10()
    }
}

fn scale_to(x: &[f32], target_dbfs: f32) -> Vec<f32> {
    let g = 10f32.powf((target_dbfs - rms_dbfs(x)) / 20.0);
    x.iter().map(|s| s * g).collect()
}

fn read_wav_pcm16(bytes: &[u8]) -> Vec<f32> {
    assert_eq!(&bytes[0..4], b"RIFF");
    let mut pos = 12;
    let mut data = Vec::new();
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let len = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap()) as usize;
        let body = &bytes[pos + 8..(pos + 8 + len).min(bytes.len())];
        if id == b"fmt " {
            assert_eq!(
                u16::from_le_bytes(body[2..4].try_into().unwrap()),
                1,
                "channels"
            );
            assert_eq!(
                u32::from_le_bytes(body[4..8].try_into().unwrap()),
                16_000,
                "rate"
            );
        } else if id == b"data" {
            data = body
                .chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32)
                .collect();
        }
        pos += 8 + len + (len & 1);
    }
    data
}

fn write_wav_pcm16(rate: usize, samples: &[f32]) -> Vec<u8> {
    let data_len = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_len);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes()); // PCM
    out.extend_from_slice(&1u16.to_le_bytes()); // mono
    out.extend_from_slice(&(rate as u32).to_le_bytes());
    out.extend_from_slice(&((rate * 2) as u32).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&(data_len as u32).to_le_bytes());
    for &s in samples {
        out.extend_from_slice(&(s.round().clamp(-32768.0, 32767.0) as i16).to_le_bytes());
    }
    out
}
