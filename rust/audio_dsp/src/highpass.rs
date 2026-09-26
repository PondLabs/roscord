//! A 4th-order Butterworth high-pass: two biquads.
//!
//! After noise suppression. Voices have next to nothing below 70 Hz, and
//! DeepFilterNet leaves that band alone: rumble through the desk, brown
//! noise and handling noise came through it under speech at full level.
//! In front of the model it made mains hum worse: without its 50 Hz
//! fundamental, the harmonics left read as a voice to the model.

/// Where it starts cutting: -3 dB at 70 Hz, -0.8 dB at 85 Hz (about the
/// lowest male voice), -12 dB at 50 Hz, -29 dB at 30 Hz.
pub const CUTOFF_HZ: f32 = 70.0;

#[derive(Clone)]
pub struct HighPass {
    coefs: [[f32; 5]; 2],
    state: [[f32; 4]; 2],
}

impl HighPass {
    pub fn new(cutoff_hz: f32, sample_rate: f32) -> HighPass {
        // The two sections' Q for a 4th-order Butterworth.
        let qs = [0.541_196_1f32, 1.306_563];
        let mut coefs = [[0.0; 5]; 2];
        for (c, q) in coefs.iter_mut().zip(qs) {
            let w0 = 2.0 * std::f32::consts::PI * cutoff_hz / sample_rate;
            let (sin, cos) = w0.sin_cos();
            let alpha = sin / (2.0 * q);
            let a0 = 1.0 + alpha;
            *c = [
                (1.0 + cos) / 2.0 / a0,
                -(1.0 + cos) / a0,
                (1.0 + cos) / 2.0 / a0,
                -2.0 * cos / a0,
                (1.0 - alpha) / a0,
            ];
        }
        HighPass {
            coefs,
            state: [[0.0; 4]; 2],
        }
    }

    pub fn reset(&mut self) {
        self.state = [[0.0; 4]; 2];
    }

    /// Filters `buf` in place.
    pub fn process(&mut self, buf: &mut [f32]) {
        for (c, st) in self.coefs.iter().zip(self.state.iter_mut()) {
            let [b0, b1, b2, a1, a2] = *c;
            let [mut x1, mut x2, mut y1, mut y2] = *st;
            for s in buf.iter_mut() {
                let x = *s;
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2;
                x2 = x1;
                x1 = x;
                y2 = y1;
                y1 = y;
                *s = y;
            }
            *st = [x1, x2, y1, y2];
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gain_db(hz: f32) -> f32 {
        let mut f = HighPass::new(CUTOFF_HZ, 48_000.0);
        let tone: Vec<f32> = (0..48_000)
            .map(|i| (2.0 * std::f32::consts::PI * hz * i as f32 / 48_000.0).sin())
            .collect();
        let mut out = tone.clone();
        f.process(&mut out);
        let rms = |x: &[f32]| (x.iter().map(|s| s * s).sum::<f32>() / x.len() as f32).sqrt();
        20.0 * (rms(&out[24_000..]) / rms(&tone[24_000..])).log10()
    }

    #[test]
    fn keeps_voices_and_cuts_rumble() {
        assert!(gain_db(1000.0).abs() < 0.1);
        assert!(gain_db(100.0) > -0.5, "100 Hz {}", gain_db(100.0));
        assert!(gain_db(85.0) > -1.0, "85 Hz {}", gain_db(85.0));
        assert!(gain_db(50.0) < -10.0, "50 Hz {}", gain_db(50.0));
        assert!(gain_db(30.0) < -25.0, "30 Hz {}", gain_db(30.0));
    }
}
