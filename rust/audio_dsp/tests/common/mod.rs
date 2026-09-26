//! Helpers for the fixture driven tests: reading the recordings in
//! `testdata/`, simulating what a loudspeaker in a room does to them before
//! the microphone picks them up, and running blocks through the DSP while
//! collecting a per-frame report.
//!
//! Not every test binary uses every helper here.
#![allow(dead_code)]

use audio_dsp::resample::Resampler;
use audio_dsp::{
    Dsp, Report, FRAME_SIZE, REPORT_FLAG_DEEP_FILTER, REPORT_FLAG_DUCKING, REPORT_FLAG_GATE_OPEN,
    REPORT_FLAG_SPEAKER_BLEED,
};

pub const RATE: usize = 48_000;

// ---------------------------------------------------------------- fixtures

fn read_wav_pcm16(bytes: &[u8]) -> (usize, Vec<f32>) {
    assert_eq!(&bytes[0..4], b"RIFF");
    let mut pos = 12;
    let mut rate = 0usize;
    let mut data = Vec::new();
    while pos + 8 <= bytes.len() {
        let id = &bytes[pos..pos + 4];
        let len = u32::from_le_bytes(bytes[pos + 4..pos + 8].try_into().unwrap()) as usize;
        let body = &bytes[pos + 8..(pos + 8 + len).min(bytes.len())];
        if id == b"fmt " {
            assert_eq!(u16::from_le_bytes(body[2..4].try_into().unwrap()), 1, "channels");
            rate = u32::from_le_bytes(body[4..8].try_into().unwrap()) as usize;
            assert_eq!(u16::from_le_bytes(body[14..16].try_into().unwrap()), 16, "bits");
        } else if id == b"data" {
            data = body
                .chunks_exact(2)
                .map(|c| i16::from_le_bytes([c[0], c[1]]) as f32)
                .collect();
        }
        pos += 8 + len + (len & 1);
    }
    (rate, data)
}

/// A 16 kHz fixture brought to 48 kHz with the crate's own resampler and
/// truncated to whole 10 ms blocks.
fn fixture_48k(bytes: &[u8]) -> Vec<f32> {
    let (rate, data) = read_wav_pcm16(bytes);
    assert_eq!(rate, 16_000);
    let mut up = Resampler::new(16_000, RATE);
    let mut out = vec![0.0; up.output_len(data.len())];
    up.process(&data, &mut out);
    out.truncate(out.len() / FRAME_SIZE * FRAME_SIZE);
    out
}

/// The user talking into their microphone (CMU ARCTIC bdl, US male).
pub fn local_speech() -> Vec<f32> {
    fixture_48k(include_bytes!("../../testdata/local_speech_16k.wav"))
}

/// Dialogue from whatever the user is watching (CMU ARCTIC slt, US female).
/// A different voice from [`local_speech`] so leakage is attributable.
pub fn media_dialogue() -> Vec<f32> {
    fixture_48k(include_bytes!("../../testdata/media_dialogue_16k.wav"))
}

/// Another participant's voice as it reaches playout (CMU ARCTIC clb).
pub fn far_end_voice() -> Vec<f32> {
    fixture_48k(include_bytes!("../../testdata/far_end_voice_16k.wav"))
}

/// Knuckles knocking on a wooden table (a cut of "Bulerías con nudillos",
/// CC0), peaking 1 dB under full scale.
pub fn knuckles_on_table() -> Vec<f32> {
    fixture_48k(include_bytes!("../../testdata/knuckles_on_table_16k.wav"))
}

/// One of the background noise recordings (`testdata/background_*`,
/// see its README), at 48 kHz, -20 dBFS RMS.
pub fn background(name: &str) -> Vec<f32> {
    let bytes: &[u8] = match name {
        "applause" => include_bytes!("../../testdata/background_applause_16k.wav"),
        "hand_claps" => include_bytes!("../../testdata/background_hand_claps_16k.wav"),
        "keyboard_mechanical" => include_bytes!("../../testdata/background_keyboard_mechanical_16k.wav"),
        "keyboard_desktop" => include_bytes!("../../testdata/background_keyboard_desktop_16k.wav"),
        "mouse_click" => include_bytes!("../../testdata/background_mouse_click_16k.wav"),
        "pen_on_paper" => include_bytes!("../../testdata/background_pen_on_paper_16k.wav"),
        "crowd_talking" => include_bytes!("../../testdata/background_crowd_talking_16k.wav"),
        "restaurant" => include_bytes!("../../testdata/background_restaurant_16k.wav"),
        "piano" => include_bytes!("../../testdata/background_piano_16k.wav"),
        "electronic_beat" => include_bytes!("../../testdata/background_electronic_beat_16k.wav"),
        "pop_song" => include_bytes!("../../testdata/background_pop_song_16k.wav"),
        other => panic!("no background recording {other}"),
    };
    fixture_48k(bytes)
}

// ------------------------------------------------------------------ levels

pub fn rms_dbfs(x: &[f32]) -> f32 {
    if x.is_empty() {
        return -120.0;
    }
    let mean_sq = x.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>() / x.len() as f64;
    let rms = mean_sq.sqrt() as f32 / 32768.0;
    if rms <= 1e-9 {
        -120.0
    } else {
        20.0 * rms.log10()
    }
}

pub fn scale_to(x: &[f32], target_dbfs: f32) -> Vec<f32> {
    let g = 10f32.powf((target_dbfs - rms_dbfs(x)) / 20.0);
    x.iter().map(|s| s * g).collect()
}

/// Scale-invariant signal-to-distortion ratio of `estimate` against
/// `reference` (same length, aligned), in dB, and the gain the estimate
/// carries the reference with, in dB: how much of the voice is left, and
/// how clean it is.
pub fn si_sdr(reference: &[f32], estimate: &[f32]) -> (f32, f32) {
    let dot = |a: &[f32], b: &[f32]| a.iter().zip(b).map(|(x, y)| *x as f64 * *y as f64).sum::<f64>();
    let alpha = dot(estimate, reference) / dot(reference, reference);
    let (mut target, mut error) = (0.0f64, 0.0f64);
    for (r, e) in reference.iter().zip(estimate) {
        let t = alpha * *r as f64;
        target += t * t;
        error += (*e as f64 - t) * (*e as f64 - t);
    }
    (
        (10.0 * (target / error.max(1e-12)).log10()) as f32,
        (20.0 * alpha.abs().max(1e-12).log10()) as f32,
    )
}

pub fn mix(a: &[f32], b: &[f32]) -> Vec<f32> {
    let n = a.len().min(b.len());
    (0..n).map(|i| a[i] + b[i]).collect()
}

/// Repeat (or cut) `x` until it is `n` samples long.
pub fn fit(x: &[f32], n: usize) -> Vec<f32> {
    (0..n).map(|i| x[i % x.len()]).collect()
}

// ------------------------------------------------------------------- noise

pub struct Lcg(pub u64);

impl Lcg {
    pub fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 33) as f32 / (1u64 << 31) as f32) * 2.0 - 1.0
    }
}

/// Full-band white noise, `n` samples, scaled later.
pub fn white_noise(n: usize, seed: u64) -> Vec<f32> {
    let mut r = Lcg(seed);
    (0..n).map(|_| r.next()).collect()
}

/// Pink noise (3 dB per octave down), Paul Kellet's economy filter.
pub fn pink_noise(n: usize, seed: u64) -> Vec<f32> {
    let mut r = Lcg(seed);
    let (mut b0, mut b1, mut b2) = (0.0f32, 0.0f32, 0.0f32);
    (0..n)
        .map(|_| {
            let w = r.next();
            b0 = 0.99765 * b0 + w * 0.099_046;
            b1 = 0.963 * b1 + w * 0.296_516_4;
            b2 = 0.57 * b2 + w * 1.052_691_3;
            b0 + b1 + b2 + w * 0.1848
        })
        .collect()
}

/// Brown noise (6 dB per octave down from about 40 Hz): wind, traffic
/// through a wall, rumble through the desk.
pub fn brown_noise(n: usize, seed: u64) -> Vec<f32> {
    let mut r = Lcg(seed);
    let mut y = 0.0f32;
    (0..n)
        .map(|_| {
            y = 0.995 * y + r.next();
            y
        })
        .collect()
}

/// Mains hum: 50 Hz and eleven harmonics, each 2 dB under the last, as a
/// ground loop or a cheap power supply puts into a microphone.
pub fn mains_hum(n: usize) -> Vec<f32> {
    let two_pi = 2.0 * std::f32::consts::PI;
    (0..n)
        .map(|i| {
            let t = i as f32 / RATE as f32;
            (0..12)
                .map(|k| 0.8f32.powi(k) * (two_pi * 50.0 * (k + 1) as f32 * t + k as f32).sin())
                .sum()
        })
        .collect()
}

/// Low passed noise: a fan, a PC, the room. RNNoise barely reacts to pure
/// white noise, real background noise is coloured.
pub fn room_tone(n: usize, level_dbfs: f32, seed: u64) -> Vec<f32> {
    let mut r = Lcg(seed);
    let mut y = 0.0f32;
    let raw: Vec<f32> = (0..n)
        .map(|_| {
            y += (r.next() - y) * 0.08;
            y
        })
        .collect();
    scale_to(&raw, level_dbfs)
}

/// Something musical: a repeating chord progression with a bass line and a
/// hi-hat, nothing like speech. Synthesised rather than downloaded so the
/// fixtures stay small and unencumbered.
pub fn music(n: usize) -> Vec<f32> {
    const CHORDS: [[f32; 3]; 4] = [
        [220.0, 261.63, 329.63],
        [196.0, 246.94, 293.66],
        [174.61, 220.0, 261.63],
        [164.81, 196.0, 246.94],
    ];
    let mut r = Lcg(99);
    let bar = RATE; // one chord per second
    let out: Vec<f32> = (0..n)
        .map(|i| {
            let t = i as f32 / RATE as f32;
            let chord = CHORDS[(i / bar) % CHORDS.len()];
            let mut s = 0.0;
            for (k, f) in chord.iter().enumerate() {
                // a little detune and a slow tremolo keep it from sounding
                // like a static test tone
                let d = 1.0 + 0.002 * k as f32;
                s += (2.0 * std::f32::consts::PI * f * d * t).sin() * 0.3;
                s += (4.0 * std::f32::consts::PI * f * d * t).sin() * 0.08;
            }
            // bass, one octave below the root, plucked every half bar
            let env = 1.0 - ((i % (bar / 2)) as f32 / (bar as f32 / 2.0)).min(1.0);
            s += (std::f32::consts::PI * chord[0] * t).sin() * 0.5 * env;
            // hi-hat on every eighth
            let eighth = bar / 4;
            let hat_env = (-8.0 * (i % eighth) as f32 / eighth as f32).exp();
            s += r.next() * 0.25 * hat_env;
            s
        })
        .collect();
    out
}

/// One knock of a knuckle on a wooden table, 150 ms, peaking at 1.0: a
/// short contact click exciting the board's modes, the low ones ringing
/// longest. Each seed moves the modes a little, like knocking somewhere
/// else on the table.
pub fn knock(seed: u64) -> Vec<f32> {
    // (Hz, time to decay by 60 dB in s, relative amplitude)
    const MODES: [(f32, f32, f32); 9] = [
        (150.0, 0.10, 0.6),
        (290.0, 0.08, 1.0),
        (470.0, 0.06, 0.9),
        (720.0, 0.05, 0.8),
        (1050.0, 0.04, 0.6),
        (1500.0, 0.03, 0.45),
        (2100.0, 0.02, 0.3),
        (2900.0, 0.015, 0.2),
        (3800.0, 0.01, 0.12),
    ];
    let mut r = Lcg(seed);
    let two_pi = 2.0 * std::f32::consts::PI;
    let mut out = vec![0.0f32; RATE * 150 / 1000];
    for (hz, t60, amp) in MODES {
        let hz = hz * (1.0 + 0.08 * r.next());
        let amp = amp * (1.0 + 0.3 * r.next());
        let phase = r.next() * std::f32::consts::PI;
        for (i, s) in out.iter_mut().enumerate() {
            let t = i as f32 / RATE as f32;
            // the knuckle takes a millisecond to land
            let onset = if t < 0.001 { 0.5 - 0.5 * (std::f32::consts::PI * t / 0.001).cos() } else { 1.0 };
            *s += amp * onset * (two_pi * hz * t + phase).sin() * (-6.9 * t / t60).exp();
        }
    }
    for (i, s) in out.iter_mut().enumerate().take(RATE * 3 / 1000) {
        let t = i as f32 / RATE as f32;
        *s += 1.5 * r.next() * (-t / 0.0004).exp();
    }
    let peak = out.iter().fold(0.0f32, |m, s| m.max(s.abs()));
    out.iter().map(|s| s / peak).collect()
}

/// "Toc toc toc": three knocks 170 ms apart every 1.6 s, `n` samples, each
/// group peaking somewhere between -20 and -6 dBFS.
pub fn knocking(n: usize) -> Vec<f32> {
    let mut out = vec![0.0f32; n];
    let mut r = Lcg(99);
    let mut seed = 1;
    let mut group = RATE / 2;
    while group + RATE < n {
        let peak = 32768.0 * 10f32.powf((-13.0 + 7.0 * r.next()) / 20.0);
        for k in 0..3 {
            let at = group + k * RATE * 170 / 1000 + (r.next().abs() * 400.0) as usize;
            for (i, s) in knock(seed).iter().enumerate() {
                if at + i < n {
                    out[at + i] += s * peak;
                }
            }
            seed += 1;
        }
        group += RATE * 16 / 10;
    }
    out
}

// ------------------------------------------------------- loudspeaker + room

/// What a desktop loudspeaker and a room do to a signal before the
/// microphone hears it: band limiting (small drivers roll off at both ends),
/// a delay for the metre or so of air, and a Schroeder reverb for the
/// reflections. The result is scaled to `level_dbfs`, the level the bleed
/// arrives at in the microphone.
pub fn speaker_bleed(clean: &[f32], level_dbfs: f32) -> Vec<f32> {
    let delayed = delay(clean, RATE * 20 / 1000);
    let band = low_pass(&high_pass(&delayed, 130.0), 9000.0);
    let wet = reverb(&band);
    let mixed: Vec<f32> = band.iter().zip(wet.iter()).map(|(d, w)| d * 0.75 + w * 0.45).collect();
    scale_to(&mixed, level_dbfs)
}

/// `x` shifted later by `ms`, same length.
pub fn delay_ms(x: &[f32], ms: usize) -> Vec<f32> {
    delay(x, RATE * ms / 1000)
}

fn delay(x: &[f32], n: usize) -> Vec<f32> {
    let mut out = vec![0.0; x.len()];
    out[n..].copy_from_slice(&x[..x.len() - n]);
    out
}

fn high_pass(x: &[f32], hz: f32) -> Vec<f32> {
    // Two one-pole sections, 12 dB/octave.
    let a = (-2.0 * std::f32::consts::PI * hz / RATE as f32).exp();
    let mut out = x.to_vec();
    for _ in 0..2 {
        let (mut yp, mut xp) = (0.0f32, 0.0f32);
        for s in out.iter_mut() {
            let y = a * (yp + *s - xp);
            xp = *s;
            yp = y;
            *s = y;
        }
    }
    out
}

fn low_pass(x: &[f32], hz: f32) -> Vec<f32> {
    let a = 1.0 - (-2.0 * std::f32::consts::PI * hz / RATE as f32).exp();
    let mut out = x.to_vec();
    for _ in 0..2 {
        let mut y = 0.0f32;
        for s in out.iter_mut() {
            y += (*s - y) * a;
            *s = y;
        }
    }
    out
}

/// Four combs into two allpasses, the classic cheap room. About 0.4 s of
/// decay, which is a normal living room.
fn reverb(x: &[f32]) -> Vec<f32> {
    const COMBS: [(usize, f32); 4] = [(1557, 0.78), (1617, 0.77), (1491, 0.79), (1422, 0.80)];
    const ALLPASS: [(usize, f32); 2] = [(225, 0.5), (556, 0.5)];
    let mut out = vec![0.0f32; x.len()];
    for (len, fb) in COMBS {
        let len = len * RATE / 44_100;
        let mut buf = vec![0.0f32; len];
        let mut i = 0;
        for (n, s) in x.iter().enumerate() {
            let y = buf[i];
            buf[i] = s + y * fb;
            i = (i + 1) % len;
            out[n] += y * 0.25;
        }
    }
    for (len, g) in ALLPASS {
        let len = len * RATE / 44_100;
        let mut buf = vec![0.0f32; len];
        let mut i = 0;
        for s in out.iter_mut() {
            let y = buf[i];
            let v = *s + y * g;
            buf[i] = v;
            i = (i + 1) % len;
            *s = y - v * g;
        }
    }
    out
}

// --------------------------------------------------------------- the runner

#[derive(Clone, Copy, Debug)]
pub struct Frame {
    pub level_db: f32,
    pub vad: f32,
    pub gain_db: f32,
    pub far_db: f32,
    pub gate_open: bool,
    pub ducking: bool,
    pub bleed: bool,
    /// DeepFilterNet suppressed this block (RNNoise otherwise).
    pub deep_filter: bool,
}

pub struct Run {
    pub out: Vec<f32>,
    pub frames: Vec<Frame>,
}

impl Run {
    pub fn gate_open_fraction(&self) -> f32 {
        let n = self.frames.iter().filter(|f| f.gate_open).count();
        n as f32 / self.frames.len() as f32
    }

    pub fn ducking_fraction(&self) -> f32 {
        let n = self.frames.iter().filter(|f| f.ducking).count();
        n as f32 / self.frames.len() as f32
    }

    pub fn bleed_fraction(&self) -> f32 {
        let n = self.frames.iter().filter(|f| f.bleed).count();
        n as f32 / self.frames.len() as f32
    }

    pub fn mean_vad(&self) -> f32 {
        self.frames.iter().map(|f| f.vad).sum::<f32>() / self.frames.len() as f32
    }

    /// Output level of the loudest 10 ms in the run: what the other end
    /// hears at its worst, which is what gives an echo away.
    pub fn peak_block_dbfs(&self) -> f32 {
        self.out
            .chunks(FRAME_SIZE)
            .map(rms_dbfs)
            .fold(-120.0f32, f32::max)
    }
}

/// What else the DSP is told about, besides the microphone.
#[derive(Clone, Copy, Default)]
pub struct Feeds<'a> {
    /// WebRTC playout, fed block by block before each capture block.
    pub render: Option<&'a [f32]>,
    /// The system mix from a loopback capturer.
    pub reference: Option<&'a [f32]>,
    /// Deliver the reference in bursts of this many blocks, all at once
    /// after a stall, the way WASAPI loopback does. 0 or 1: steady.
    pub reference_burst: usize,
}

/// Push `capture` through the DSP in 10 ms blocks, feeding render and
/// reference audio for each block first, as the native hooks do.
pub fn run(dsp: &mut Dsp, capture: &[f32], feeds: Feeds) -> Run {
    let mut out = capture.to_vec();
    out.truncate(out.len() / FRAME_SIZE * FRAME_SIZE);
    let mut frames = Vec::with_capacity(out.len() / FRAME_SIZE);
    let block = |x: &[f32], i: usize| -> Option<Vec<f32>> {
        let start = i * FRAME_SIZE;
        (start + FRAME_SIZE <= x.len()).then(|| x[start..start + FRAME_SIZE].to_vec())
    };
    for (i, b) in out.chunks_mut(FRAME_SIZE).enumerate() {
        if let Some(r) = feeds.render.and_then(|r| block(r, i)) {
            dsp.feed_render(&r);
        }
        if let Some(reference) = feeds.reference {
            let burst = feeds.reference_burst.max(1);
            if (i + 1) % burst == 0 {
                for j in (i + 1 - burst)..=i {
                    if let Some(r) = block(reference, j) {
                        dsp.feed_reference(&r, RATE);
                    }
                }
            }
        }
        dsp.process_block(b);
        frames.push(frame(dsp.report()));
    }
    Run { out, frames }
}

fn frame(r: Report) -> Frame {
    Frame {
        level_db: r.level_db,
        vad: r.vad,
        gain_db: r.gain_db,
        far_db: r.far_level_db,
        gate_open: r.flags & REPORT_FLAG_GATE_OPEN != 0,
        ducking: r.flags & REPORT_FLAG_DUCKING != 0,
        bleed: r.flags & REPORT_FLAG_SPEAKER_BLEED != 0,
        deep_filter: r.flags & REPORT_FLAG_DEEP_FILTER != 0,
    }
}
