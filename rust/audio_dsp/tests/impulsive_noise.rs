//! Knocking on the table: "toc toc toc" on wood, the noise from the report
//! that noise suppression did nothing about.
//!
//! Impulsive noise is the case RNNoise is weak at. It takes steady noise out
//! (a fan, a PC) but a knock comes out about 6 dB down, and while the user
//! talks the gate is open, so a knock reaches the room at almost full level.
//! DeepFilterNet (`audio_dsp::dfn`) is the suppressor for that.
//!
//! Two kinds of knocking: a recording of knuckles on a table
//! (`testdata/knuckles_on_table_16k.wav`) and synthetic knocks
//! (`common::knocking`) whose timing is known, so they can be laid under
//! speech and measured there.
//!
//! Every test prints DeepFilterNet's numbers and RNNoise's side by side
//! (`-- --nocapture`); only the shipping configuration is asserted.

mod common;

use audio_dsp::{Dsp, ModelLoad, Params, FRAME_SIZE, REPORT_FLAG_DEEP_FILTER};
use common::*;

/// A quiet room under the knocking: the microphone's own noise and a PC.
fn room(n: usize) -> Vec<f32> {
    room_tone(n, -50.0, 7)
}

fn engine_name(load: ModelLoad) -> &'static str {
    match load {
        ModelLoad::Never => "RNNoise",
        _ => "DeepFilterNet",
    }
}

/// Blocks by which the output trails the input: RNNoise's window overlap,
/// plus DeepFilterNet's lookahead when it runs.
fn latency_blocks(dsp: &Dsp) -> usize {
    if dsp.has_deep_filter() {
        audio_dsp::dfn::LATENCY / FRAME_SIZE
    } else {
        1
    }
}

fn process(params: Params, load: ModelLoad, capture: &[f32]) -> (Run, usize) {
    let mut dsp = Dsp::with_model(params, load);
    let r = run(&mut dsp, capture, Feeds::default());
    if load == ModelLoad::Now {
        let filtered = r.frames.iter().filter(|f| f.deep_filter).count();
        assert_eq!(
            filtered,
            r.frames.len(),
            "DeepFilterNet ran on {filtered} of {} blocks",
            r.frames.len()
        );
    }
    (r, latency_blocks(&dsp))
}

/// How much quieter the whole run comes out than it went in. The knocks are
/// most of the input's energy, so this is what happened to them.
fn attenuation(params: Params, load: ModelLoad, name: &str, capture: &[f32]) -> (f32, f32) {
    let (r, _) = process(params, load, capture);
    let atten = rms_dbfs(&capture[..r.out.len()]) - rms_dbfs(&r.out);
    let open = r.gate_open_fraction();
    println!(
        "{name:<40} {:<14} {atten:5.1} dB down, gate open {:3.0}%",
        engine_name(load),
        open * 100.0
    );
    (atten, open)
}

fn knock_sources() -> Vec<(&'static str, Vec<f32>)> {
    let knuckles = scale_to(&knuckles_on_table(), -30.0);
    let synthetic = knocking(RATE * 10);
    vec![
        ("knuckles on a table", knuckles),
        ("synthetic knocks", synthetic),
    ]
}

#[test]
fn knocks_while_nobody_talks_never_open_the_gate() {
    for (name, knocks) in knock_sources() {
        let capture = mix(&knocks, &room(knocks.len()));
        attenuation(Params::default(), ModelLoad::Never, name, &capture);
        let (atten, open) = attenuation(Params::default(), ModelLoad::Now, name, &capture);
        assert!(atten > 40.0, "{name}: only {atten:.1} dB down");
        assert!(
            open < 0.02,
            "{name}: the gate opened {:.0}% of the time",
            open * 100.0
        );
    }
}

/// While the user talks the gate is open and the suppressor is all there is
/// between a knock and the room, so it is measured without the gate.
#[test]
fn the_suppressor_itself_takes_knocks_out() {
    let params = Params {
        gate_mode: 0,
        far_end_ducking: 0,
        ..Params::default()
    };
    for (name, knocks) in knock_sources() {
        let capture = mix(&knocks, &room(knocks.len()));
        let (rnnoise, _) = attenuation(params, ModelLoad::Never, name, &capture);
        let (atten, _) = attenuation(params, ModelLoad::Now, name, &capture);
        assert!(
            atten > 20.0,
            "{name}: only {atten:.1} dB down without the gate (RNNoise: {rnnoise:.1})"
        );
    }
}

/// Knocks under speech: how much louder the blocks with a knock in them come
/// out than the same blocks with the speech alone, and how much of the
/// knocks' energy that adds up to.
///
/// Neither suppressor removes all of it. While the user talks the model
/// keeps the speech's bands open, and a knock 15 to 20 dB louder than a
/// quiet syllable still gets its first 10 ms through, about 5 dB down. The
/// assertions hold DeepFilterNet to what it measured (mean +1.4 dB, 90 %
/// under +3.6, the knocks' energy 5.6 dB down; RNNoise +2.7, +8.2 and
/// 2.4 dB) with some margin. The single worst block is printed, not
/// asserted: next to a block the high-pass left nearly empty, any knock is
/// "+26 dB".
#[test]
fn knocks_while_talking_do_not_come_through() {
    let speech = scale_to(&local_speech(), -22.0);
    let n = speech.len();
    let knocks = knocking(n);
    let room = room(n);
    let talking = mix(&speech, &room);
    let knocking_too = mix(&talking, &knocks);
    let both: Vec<usize> = (0..n / FRAME_SIZE)
        .filter(|&b| {
            let at = b * FRAME_SIZE..(b + 1) * FRAME_SIZE;
            rms_dbfs(&speech[at.clone()]) > -45.0 && rms_dbfs(&knocks[at]) > -45.0
        })
        .collect();
    assert!(
        both.len() > 20,
        "only {} blocks of knocks under speech",
        both.len()
    );

    for load in [ModelLoad::Never, ModelLoad::Now] {
        let (alone, lag) = process(Params::default(), load, &talking);
        let (with_knocks, _) = process(Params::default(), load, &knocking_too);
        let blocks: Vec<usize> = both
            .iter()
            .copied()
            .filter(|&b| (b + lag + 1) * FRAME_SIZE <= alone.out.len())
            .collect();
        let energy = |x: &[f32]| x.iter().map(|s| (*s as f64) * (*s as f64)).sum::<f64>();
        let (mut added, mut knocked) = (0.0f64, 0.0f64);
        let mut excess: Vec<f32> = blocks
            .iter()
            .map(|&b| {
                let at = (b + lag) * FRAME_SIZE..(b + lag + 1) * FRAME_SIZE;
                added += (energy(&with_knocks.out[at.clone()]) - energy(&alone.out[at.clone()])).max(0.0);
                knocked += energy(&knocks[b * FRAME_SIZE..(b + 1) * FRAME_SIZE]);
                rms_dbfs(&with_knocks.out[at.clone()]) - rms_dbfs(&alone.out[at])
            })
            .collect();
        let knocks_down = 10.0 * (knocked / added.max(1e-9)).log10() as f32;
        excess.sort_by(f32::total_cmp);
        let mean = excess.iter().sum::<f32>() / excess.len() as f32;
        let p90 = excess[excess.len() * 9 / 10];
        let max = excess[excess.len() - 1];
        println!(
            "knocks under speech ({} blocks)          {:<14} +{mean:.1} dB on average, 90% under +{p90:.1}, +{max:.1} at worst; their energy {knocks_down:.1} dB down",
            excess.len(),
            engine_name(load)
        );
        if load == ModelLoad::Now {
            assert!(
                mean < 2.0,
                "knocks add {mean:.1} dB on average to the blocks they are in"
            );
            assert!(
                p90 < 6.0,
                "knocks add more than {p90:.1} dB to 10% of the blocks they are in"
            );
            assert!(
                knocks_down > 4.0,
                "the knocks' energy under speech only {knocks_down:.1} dB down"
            );
        }
    }
}

/// The voice itself: DeepFilterNet must not cost the user what RNNoise did
/// not.
#[test]
fn the_voice_is_kept() {
    let speech = scale_to(&local_speech(), -22.0);
    let capture = mix(&speech, &room(speech.len()));
    for load in [ModelLoad::Never, ModelLoad::Now] {
        let (r, _) = process(Params::default(), load, &capture);
        let lost = rms_dbfs(&capture[..r.out.len()]) - rms_dbfs(&r.out);
        println!(
            "the user talking                         {:<14} {lost:5.1} dB lost",
            engine_name(load)
        );
        if load == ModelLoad::Now {
            assert!(lost < 1.0, "the voice lost {lost:.1} dB");
        }
    }
}

#[test]
fn the_report_says_which_suppressor_ran() {
    let capture = room(RATE);
    let mut dsp = Dsp::with_model(Params::default(), ModelLoad::Now);
    run(&mut dsp, &capture, Feeds::default());
    assert_ne!(dsp.report().flags & REPORT_FLAG_DEEP_FILTER, 0);

    let mut dsp = Dsp::with_model(Params::default(), ModelLoad::Never);
    run(&mut dsp, &capture, Feeds::default());
    assert_eq!(dsp.report().flags & REPORT_FLAG_DEEP_FILTER, 0);
}

