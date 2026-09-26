//! Puts a recording through the voice DSP and writes what would leave the
//! client, for listening to and for measuring outside the tests.
//!
//!   cargo run -p audio_dsp --release --example process_wav -- \
//!       <in.wav> <out.wav> [--rnnoise] [--no-gate] [--no-ns] [--blocks <csv>]
//!
//! `in.wav` is mono PCM16 at 48 kHz. The shipping settings are used unless
//! told otherwise: `--rnnoise` keeps DeepFilterNet out (RNNoise alone, as
//! before it), `--no-gate` turns the input gate off, `--no-ns` noise
//! suppression. `--blocks` writes one line per 10 ms block: the level after
//! noise suppression, the speech probability, whether the gate was open,
//! the gain it applied, the report flags and DeepFilterNet's estimate of
//! the speech-to-noise ratio.

use audio_dsp::{Dsp, ModelLoad, Params, FRAME_SIZE, REPORT_FLAG_GATE_OPEN};

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |f: &str| args.iter().any(|a| a == f);
    let value = |f: &str| {
        args.iter()
            .position(|a| a == f)
            .and_then(|i| args.get(i + 1))
    };
    let files: Vec<&String> = args
        .iter()
        .enumerate()
        .filter(|(i, a)| !a.starts_with("--") && (*i == 0 || args[i - 1] != "--blocks"))
        .map(|(_, a)| a)
        .collect();
    if files.len() != 2 {
        eprintln!("usage: process_wav <in.wav> <out.wav> [--rnnoise] [--no-gate] [--no-ns] [--blocks <csv>]");
        std::process::exit(2);
    }
    let (rate, mut samples) = read_wav_pcm16(&std::fs::read(files[0]).expect("read input"));
    assert_eq!(rate, 48_000, "{}: needs 48 kHz", files[0]);

    let mut params = Params::default();
    if flag("--no-gate") {
        params.gate_mode = 0;
    }
    if flag("--no-ns") {
        params.noise_suppression = 0;
    }
    let load = if flag("--rnnoise") {
        ModelLoad::Never
    } else {
        ModelLoad::Now
    };
    let mut dsp = Dsp::with_model(params, load);

    let mut blocks = String::from("block,level_db,vad,gate_open,gain_db,flags,snr_db\n");
    samples.truncate(samples.len() / FRAME_SIZE * FRAME_SIZE);
    for (i, block) in samples.chunks_mut(FRAME_SIZE).enumerate() {
        dsp.process_block(block);
        let r = dsp.report();
        blocks.push_str(&format!(
            "{i},{:.1},{:.3},{},{:.1},{},{:.1}\n",
            r.level_db,
            r.vad,
            (r.flags & REPORT_FLAG_GATE_OPEN != 0) as u8,
            r.gain_db,
            r.flags,
            dsp.speech_to_noise_db().unwrap_or(f32::NAN)
        ));
    }
    std::fs::write(files[1], write_wav_pcm16(rate, &samples)).expect("write output");
    if let Some(path) = value("--blocks") {
        std::fs::write(path, blocks).expect("write blocks");
    }
}

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
            assert_eq!(
                u16::from_le_bytes(body[2..4].try_into().unwrap()),
                1,
                "channels"
            );
            rate = u32::from_le_bytes(body[4..8].try_into().unwrap()) as usize;
            assert_eq!(
                u16::from_le_bytes(body[14..16].try_into().unwrap()),
                16,
                "bits"
            );
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

fn write_wav_pcm16(rate: usize, samples: &[f32]) -> Vec<u8> {
    let data_len = samples.len() * 2;
    let mut out = Vec::with_capacity(44 + data_len);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&((36 + data_len) as u32).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
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
