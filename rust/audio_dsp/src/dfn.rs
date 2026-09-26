//! DeepFilterNet3 (`third_party/deep_filter`), the noise suppressor.
//!
//! RNNoise, which used to do the job alone, takes steady noise out (a fan,
//! a PC) but lets impulsive noise through: knocking on a wooden table came
//! out 6 dB down, and at full level while the user talked, because it also
//! opens the gate. DeepFilterNet3 is trained on those noises too.
//!
//! It works on the same 10 ms, 48 kHz frames as the rest of the crate, with
//! 20 ms more latency than RNNoise (two frames of lookahead). Its inference
//! (tract) allocates, unlike everything else on the audio thread.

use df::tract::ndarray::Array2;
use df::tract::{DfParams, DfTract, RuntimeParams, DEFAULT_MODEL};

use crate::{FRAME_SIZE, NATIVE_RATE};

const I16_SCALE: f32 = 32768.0;

/// libDF skips its decoders on frames whose estimated SNR is above these
/// (35 dB by default): "clean speech, leave it". A knock in a quiet room is
/// exactly such a frame, so they always run.
const ALWAYS_PROCESS_DB: f32 = 100.0;
/// Below this estimated SNR a frame is taken as noise only and zeroed.
const NOISE_ONLY_DB: f32 = -15.0;

/// Blocks of room tone the model hears before its first real one.
const SETTLE_BLOCKS: usize = 50;
/// Scales the settling noise (low-passed white noise, RMS about 0.13) to
/// about -68 dBFS: a quiet room through a decent microphone.
const SETTLE_SCALE: f32 = 100.0;

/// Samples by which the output of [`DeepFilter::process`] trails its input:
/// the STFT's overlap plus the model's two frames of lookahead.
pub const LATENCY: usize = 3 * FRAME_SIZE;

/// Blocks a model that arrives mid-stream runs before its output is used:
/// until its lookahead and normalisation have heard the microphone, its
/// output is the settling noise.
pub const WARMUP_BLOCKS: u32 = 20;

/// What a block of inference may cost on average before the model gives way
/// to RNNoise. The capture thread has 10 ms per block for everything;
/// DeepFilterNet takes about 1 ms on a 2017 laptop.
#[cfg(not(target_arch = "wasm32"))]
pub const BUDGET: std::time::Duration = std::time::Duration::from_millis(6);
/// Blocks timed before the average is judged; the first ones allocate.
#[cfg(not(target_arch = "wasm32"))]
const COST_SETTLE_BLOCKS: u32 = 100;

/// A running average of inference time.
#[cfg(not(target_arch = "wasm32"))]
pub struct CostMeter {
    blocks: u32,
    average_us: f32,
}

#[cfg(not(target_arch = "wasm32"))]
impl CostMeter {
    pub fn new() -> CostMeter {
        CostMeter {
            blocks: 0,
            average_us: 0.0,
        }
    }

    /// Adds one block's time. True when the average is over [`BUDGET`].
    pub fn too_slow(&mut self, took: std::time::Duration) -> bool {
        let us = took.as_secs_f32() * 1e6;
        self.blocks = self.blocks.saturating_add(1);
        // About the last 64 blocks.
        self.average_us += (us - self.average_us) / self.blocks.min(64) as f32;
        self.blocks >= COST_SETTLE_BLOCKS && self.average_us > BUDGET.as_secs_f32() * 1e6
    }
}

pub struct DeepFilter {
    model: DfTract,
    input: Array2<f32>,
    output: Array2<f32>,
}

impl DeepFilter {
    /// Builds the model: decompresses and optimises it, and lets it settle,
    /// a few hundred milliseconds natively. Never on the audio thread.
    pub fn new() -> Result<DeepFilter, String> {
        let params = DfParams::from_bytes(DEFAULT_MODEL).map_err(|e| format!("{e:#}"))?;
        let runtime = RuntimeParams::default_with_ch(1).with_thresholds(
            NOISE_ONLY_DB,
            ALWAYS_PROCESS_DB,
            ALWAYS_PROCESS_DB,
        );
        let model = DfTract::new(params, &runtime).map_err(|e| format!("{e:#}"))?;
        if model.hop_size != FRAME_SIZE || model.sr != NATIVE_RATE {
            return Err(format!(
                "model runs {} samples at {} Hz, the DSP {} at {}",
                model.hop_size, model.sr, FRAME_SIZE, NATIVE_RATE
            ));
        }
        let mut filter = DeepFilter {
            model,
            input: Array2::zeros((1, FRAME_SIZE)),
            output: Array2::zeros((1, FRAME_SIZE)),
        };
        filter.settle();
        Ok(filter)
    }

    /// Runs [`SETTLE_BLOCKS`] of a quiet room through the model. Its input
    /// normalisation starts far from any real microphone and takes about a
    /// second to get there; until then a knock half a second into a call
    /// came through at 20 dB down and opened the gate.
    fn settle(&mut self) {
        let mut state = 0x5eed_u64;
        let mut low = 0.0f32;
        let mut frame = [0.0f32; FRAME_SIZE];
        let mut out = [0.0f32; FRAME_SIZE];
        for _ in 0..SETTLE_BLOCKS {
            for s in frame.iter_mut() {
                state = state
                    .wrapping_mul(6364136223846793005)
                    .wrapping_add(1442695040888963407);
                let white = ((state >> 33) as f32 / (1u64 << 31) as f32) * 2.0 - 1.0;
                low += (white - low) * 0.1;
                *s = low * SETTLE_SCALE;
            }
            self.process(&frame, &mut out);
        }
    }

    /// Suppresses noise in one 480-sample frame of int16-scale audio.
    /// Returns the model's estimate of the frame's speech-to-noise ratio in
    /// dB, or `None` when inference failed and `output` holds the input.
    pub fn process(&mut self, input: &[f32], output: &mut [f32]) -> Option<f32> {
        for (d, s) in self.input.iter_mut().zip(input) {
            *d = s / I16_SCALE;
        }
        match self
            .model
            .process(self.input.view(), self.output.view_mut())
        {
            Ok(lsnr) => {
                for (d, s) in output.iter_mut().zip(self.output.iter()) {
                    *d = s * I16_SCALE;
                }
                Some(lsnr)
            }
            Err(_) => {
                output.copy_from_slice(input);
                None
            }
        }
    }
}
