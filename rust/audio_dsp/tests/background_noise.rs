//! Everything else in a room that is not the user's voice, through the DSP
//! at its shipping settings: steady noise (fans, hiss, hum, rumble),
//! impulsive noise (claps, keyboards, a mouse, a pen), other people and
//! music.
//!
//! Every noise is measured four ways:
//!
//! * alone at -38 dBFS, the user not talking: how far down it comes out,
//!   and how often it opened the gate;
//! * alone at -25 dBFS, nearly as loud as the voice: how often it opened
//!   the gate;
//! * under the user's speech (-22 dBFS) at 10 dB and at 0 dB speech to
//!   noise: how clean the voice comes out (SI-SDR against the clean voice,
//!   through the same high-pass), how much of it is left, and how much of
//!   the time the gate let it through.
//!
//! The recordings are in `testdata/` (see its README), the synthetic noises
//! in `common`. Each test holds DeepFilterNet to what it measured on
//! 2026-09-25, with margin; `-- --nocapture` prints the numbers. The noises
//! the DSP cannot remove are recorded as such in their own tests at the
//! end, so that a change in them is noticed either way.

mod common;

use audio_dsp::highpass::{HighPass, CUTOFF_HZ};
use audio_dsp::{dfn, Dsp, Params, FRAME_SIZE};
use common::*;

/// Levels: the noise alone, the loud noise alone, the user.
const QUIET_DBFS: f32 = -38.0;
const LOUD_DBFS: f32 = -25.0;
const SPEECH_DBFS: f32 = -22.0;
/// The first half second is the gate and the models settling.
const SKIP: usize = RATE / 2;

struct Measured {
    down_db: f32,
    gate_quiet: f32,
    gate_loud: f32,
    /// At 10 dB and at 0 dB speech to noise: SI-SDR in, SI-SDR out, voice
    /// gain (dB), fraction of the speech the gate let through.
    snr10: (f32, f32, f32, f32),
    snr0: (f32, f32, f32, f32),
}

fn run_shipping(capture: &[f32]) -> Run {
    let mut dsp = Dsp::new(Params::default());
    let r = run(&mut dsp, capture, Feeds::default());
    assert!(
        r.frames.iter().skip(1).all(|f| f.deep_filter),
        "DeepFilterNet did not run on every block"
    );
    r
}

fn alone(noise: &[f32], level: f32) -> (f32, f32) {
    let capture = scale_to(&fit(noise, RATE * 6), level);
    let r = run_shipping(&capture);
    let down = rms_dbfs(&capture[SKIP..r.out.len()]) - rms_dbfs(&r.out[SKIP..]);
    let frames = &r.frames[SKIP / FRAME_SIZE..];
    let open = frames.iter().filter(|f| f.gate_open).count() as f32 / frames.len() as f32;
    (down.min(99.0), open)
}

fn under_speech(noise: &[f32], snr: f32) -> (f32, f32, f32, f32) {
    let speech = scale_to(&local_speech(), SPEECH_DBFS);
    let n = speech.len();
    let talking: Vec<bool> = speech
        .chunks(FRAME_SIZE)
        .map(|b| rms_dbfs(b) > -45.0)
        .collect();
    let active: Vec<f32> = speech
        .chunks(FRAME_SIZE)
        .zip(&talking)
        .filter(|(_, t)| **t)
        .flat_map(|(b, _)| b.iter().copied())
        .collect();
    let noise = scale_to(&fit(noise, n), rms_dbfs(&active) - snr);
    let capture = mix(&speech, &noise);
    let r = run_shipping(&capture);

    // What the voice should come out as: through the same high-pass, as
    // late as the model makes it.
    let mut reference = speech.clone();
    HighPass::new(CUTOFF_HZ, RATE as f32).process(&mut reference);
    let lag = dfn::LATENCY;
    let len = r.out.len() - lag;
    let (sdr_out, voice) = si_sdr(&reference[SKIP..len], &r.out[SKIP + lag..]);
    let (sdr_in, _) = si_sdr(&speech[SKIP..len], &capture[SKIP..len]);
    let lag_blocks = lag / FRAME_SIZE;
    let (mut open, mut total) = (0, 0);
    for (b, t) in talking.iter().enumerate() {
        if *t && b + lag_blocks < r.frames.len() {
            total += 1;
            open += r.frames[b + lag_blocks].gate_open as usize;
        }
    }
    (sdr_in, sdr_out, voice, open as f32 / total as f32)
}

fn measure(name: &str, noise: &[f32]) -> Measured {
    let (down_db, gate_quiet) = alone(noise, QUIET_DBFS);
    let (_, gate_loud) = alone(noise, LOUD_DBFS);
    let m = Measured {
        down_db,
        gate_quiet,
        gate_loud,
        snr10: under_speech(noise, 10.0),
        snr0: under_speech(noise, 0.0),
    };
    println!(
        "{name:<20} alone {:>5.1} dB down, gate {:>4.1}%, loud gate {:>4.1}% | 10 dB: SI-SDR {:>5.1} -> {:>5.1}, voice {:+.1} dB, gate {:>5.1}% | 0 dB: {:>5.1} -> {:>5.1}, voice {:+.1} dB, gate {:>5.1}%",
        m.down_db,
        m.gate_quiet * 100.0,
        m.gate_loud * 100.0,
        m.snr10.0,
        m.snr10.1,
        m.snr10.2,
        m.snr10.3 * 100.0,
        m.snr0.0,
        m.snr0.1,
        m.snr0.2,
        m.snr0.3 * 100.0,
    );
    m
}

/// What a noise the DSP removes has to keep doing.
struct Expect {
    /// Alone at -38 dBFS: at least this far down.
    down_db: f32,
    /// Alone: the gate open at most this often, quiet and loud.
    gate_quiet: f32,
    gate_loud: f32,
    /// Under speech at 10 and 0 dB: SI-SDR at least this much better than
    /// the input.
    gain10_db: f32,
    gain0_db: f32,
}

/// The voice under any of these noises: at most this much of it lost, and
/// the gate open for at least this much of it. Measured worst: 1.0 dB and
/// 96.8 % at 10 dB, 4.3 dB and 83 % at 0 dB (piano, as loud as the voice).
const VOICE_LOSS_10_DB: f32 = 1.5;
const VOICE_LOSS_0_DB: f32 = 5.0;
const GATE_SPEECH_10: f32 = 0.95;
const GATE_SPEECH_0: f32 = 0.80;

fn check(name: &str, noise: &[f32], e: Expect) {
    let m = measure(name, noise);
    assert!(
        m.down_db >= e.down_db,
        "{name}: alone only {:.1} dB down (want {})",
        m.down_db,
        e.down_db
    );
    assert!(
        m.gate_quiet <= e.gate_quiet,
        "{name}: opened the gate {:.1}% of the time",
        m.gate_quiet * 100.0
    );
    assert!(
        m.gate_loud <= e.gate_loud,
        "{name}: loud, opened the gate {:.1}% of the time",
        m.gate_loud * 100.0
    );
    for (snr, (sdr_in, sdr_out, voice, open), gain, loss, gate) in [
        (10, m.snr10, e.gain10_db, VOICE_LOSS_10_DB, GATE_SPEECH_10),
        (0, m.snr0, e.gain0_db, VOICE_LOSS_0_DB, GATE_SPEECH_0),
    ] {
        assert!(
            sdr_out - sdr_in >= gain,
            "{name} at {snr} dB: SI-SDR {sdr_in:.1} -> {sdr_out:.1}, want +{gain}"
        );
        assert!(
            voice >= -loss,
            "{name} at {snr} dB: the voice lost {:.1} dB",
            -voice
        );
        assert!(
            open >= gate,
            "{name} at {snr} dB: the gate let {:.0}% of the speech through",
            open * 100.0
        );
    }
}

macro_rules! removed {
    ($test:ident, $noise:expr, $down:expr, $gate_quiet:expr, $gate_loud:expr, $gain10:expr, $gain0:expr) => {
        #[test]
        fn $test() {
            check(
                stringify!($test),
                &$noise,
                Expect {
                    down_db: $down,
                    gate_quiet: $gate_quiet,
                    gate_loud: $gate_loud,
                    gain10_db: $gain10,
                    gain0_db: $gain0,
                },
            );
        }
    };
}

// Measured on 2026-09-25, in the order of the arguments: alone at -38 dBFS
// (dB down, gate open), loud (gate open), SI-SDR gained at 10 dB and at
// 0 dB. The expectations leave 1.5 to 2 dB and a few % of margin, and ask
// for 50 dB down where more was measured.

// Steady noise.
// 74.6 dB, 0 %, 3.6 %, +4.8, +7.8
removed!(
    fan_and_pc,
    room_tone(RATE * 6, -20.0, 5),
    50.0,
    0.02,
    0.10,
    3.3,
    5.8
);
// 76.3 dB, 0 %, 0 %, +9.6, +13.2
removed!(
    white_noise_hiss,
    white_noise(RATE * 6, 11),
    50.0,
    0.02,
    0.03,
    8.1,
    11.2
);
// 69.0 dB, 0 %, 3.6 %, +6.7, +9.8
removed!(
    pink_noise_rain,
    pink_noise(RATE * 6, 13),
    50.0,
    0.02,
    0.10,
    5.2,
    7.8
);
// 72.8 dB, 0 %, 0 %, +8.9, +11.9: what the high-pass after the model is for
removed!(
    brown_noise_rumble,
    brown_noise(RATE * 6, 17),
    50.0,
    0.02,
    0.03,
    7.4,
    9.9
);
// 90.6 dB, 0 %, 0 %, +5.7, +10.1
removed!(
    mains_hum_50_hz,
    mains_hum(RATE * 6),
    50.0,
    0.02,
    0.03,
    4.2,
    8.1
);

// Impulsive noise.
// 89.4 dB, 0 %, 0 %, +6.0, +10.4
removed!(applause, background("applause"), 50.0, 0.02, 0.03, 4.5, 8.4);
// 99 dB, 0 %, 0 %, +12.9, +20.2
removed!(
    hand_claps,
    background("hand_claps"),
    50.0,
    0.02,
    0.03,
    11.4,
    18.2
);
// 98 dB, 0 %, 0 %, +6.3, +11.7 (tests/impulsive_noise.rs has more on knocks)
removed!(
    knuckles_on_the_table,
    knuckles_on_table(),
    50.0,
    0.02,
    0.03,
    4.8,
    9.7
);
// 86.2 dB, 0 %, 0 %, +5.3, +9.4
removed!(
    mechanical_keyboard,
    background("keyboard_mechanical"),
    50.0,
    0.02,
    0.03,
    3.8,
    7.4
);
// 82.0 dB, 0 %, 0 %, +19.6, +27.4: mostly rumble through the desk
removed!(
    desktop_keyboard,
    background("keyboard_desktop"),
    50.0,
    0.02,
    0.03,
    18.1,
    25.4
);
// 77.8 dB, 0 %, 0 %, +9.7, +13.8
removed!(
    mouse_clicks,
    background("mouse_click"),
    50.0,
    0.02,
    0.03,
    8.2,
    11.8
);
// 86.6 dB, 0 %, 0 %, +5.9, +10.1
removed!(
    pen_on_paper,
    background("pen_on_paper"),
    50.0,
    0.02,
    0.03,
    4.4,
    8.1
);

// Crowds and music.
// 93.6 dB, 0 %, 0 %, +4.9, +8.8: many voices far away blur into noise
removed!(
    crowd_far_away,
    background("crowd_talking"),
    50.0,
    0.02,
    0.03,
    3.4,
    6.8
);
// 79.4 dB, 0 %, 7.5 %, +3.6, +4.5
removed!(piano, background("piano"), 50.0, 0.02, 0.15, 2.1, 2.5);
// 67.2 dB, 0 %, 0 %, +5.1, +9.1
removed!(
    electronic_beat,
    background("electronic_beat"),
    50.0,
    0.02,
    0.03,
    3.6,
    7.1
);
// 77.9 dB, 0 %, 0 %, +7.1, +11.6. The singing goes with the music: so
// would the user's, singing or playing into the call with suppression on.
removed!(
    pop_song_with_singing,
    background("pop_song"),
    50.0,
    0.02,
    0.03,
    5.6,
    9.6
);

// What the DSP cannot remove, recorded so that a change is noticed either
// way. Neither model tells the user from other people: a voice is a voice.
// The input sensitivity slider is the tool, above the other voices' level.

/// People talking at the next table, and dishes: partly removed. The
/// voices near enough to be understood open the gate now and then.
/// Measured: 20.6 dB down, the gate open 13.6 % of the time (23.3 % loud);
/// under speech +4.1 and +6.1 dB SI-SDR.
#[test]
fn restaurant_is_only_partly_removed() {
    let noise = background("restaurant");
    let m = measure("restaurant", &noise);
    assert!(m.down_db > 15.0, "{:.1} dB down", m.down_db);
    assert!(
        m.gate_quiet < 0.25,
        "the gate open {:.1}% of the time",
        m.gate_quiet * 100.0
    );
    assert!(
        m.gate_loud < 0.40,
        "loud, the gate open {:.1}% of the time",
        m.gate_loud * 100.0
    );
    assert!(
        m.snr10.1 - m.snr10.0 > 2.6,
        "SI-SDR {:.1} -> {:.1}",
        m.snr10.0,
        m.snr10.1
    );
    assert!(m.snr10.2 > -VOICE_LOSS_10_DB && m.snr10.3 > GATE_SPEECH_10);
    assert!(m.snr0.2 > -VOICE_LOSS_0_DB && m.snr0.3 > GATE_SPEECH_0);
}

/// Someone else in the room talking while the user is quiet goes through
/// untouched (measured: 0.1 dB down, the gate open 94 % of the time). Under
/// the user's speech it still comes out a little cleaner (+3.0 and +4.5 dB
/// SI-SDR). If this starts failing because it is removed, something new is
/// doing the job and the docs need updating.
#[test]
fn another_person_talking_goes_through() {
    let m = measure("another_person", &far_end_voice());
    assert!(
        m.down_db < 3.0,
        "{:.1} dB down: better than recorded",
        m.down_db
    );
    assert!(
        m.gate_quiet > 0.8,
        "the gate open {:.1}%: better than recorded",
        m.gate_quiet * 100.0
    );
    assert!(m.snr10.2 > -VOICE_LOSS_10_DB && m.snr10.3 > GATE_SPEECH_10);
}
