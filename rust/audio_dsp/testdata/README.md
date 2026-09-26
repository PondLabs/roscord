# audio_dsp test fixtures

| File | What it stands for | Used by |
|------|--------------------|---------|
| `speech_48k.wav` | synthesised speech, 48 kHz | `src/lib.rs` unit tests |
| `local_speech_16k.wav` | the user talking into their microphone | `tests/speaker_bleed.rs` |
| `media_dialogue_16k.wav` | dialogue from a video the user is watching | `tests/speaker_bleed.rs` |
| `far_end_voice_16k.wav` | another participant's voice on playout | `tests/speaker_bleed.rs` |
| `knuckles_on_table_16k.wav` | the user knocking on the table with their knuckles | `tests/impulsive_noise.rs`, `tests/background_noise.rs` |
| `background_*_16k.wav` | noise in the user's room: claps, keyboards, a crowd, music (below) | `tests/background_noise.rs` |

The three 16 kHz speech files are cuts of the **CMU_ARCTIC** databases: `bdl` (US
male), `slt` and `clb` (US female). Three different voices so that leakage in
a test is attributable to one source. They are stored at the rate they were
recorded at — the recordings hold nothing above 8 kHz, and storing them at
48 kHz would only triple the size of the repository. The tests upsample with
the crate's own resampler, which is what the app does with a 16 kHz WebRTC
pipeline anyway.

Modifications: leading and trailing silence cut, three utterances
concatenated with a fixed gap, normalised to -20 dBFS RMS. Nothing else; the
loudspeaker and room simulation lives in `tests/common/mod.rs` so the tests
can pick the bleed level.

`knuckles_on_table_16k.wav` is six seconds (22 s to 28 s) of "Bulerías con
nudillos" by Santiago Sánchez Cifuentes, knuckles knocking a flamenco
rhythm on a table, from Wikimedia Commons
(<https://commons.wikimedia.org/wiki/File:Buler%C3%ADas_con_nudillos.ogg>),
dedicated to the public domain (CC0). Modifications: mixed to mono,
resampled to 16 kHz by ffmpeg, cut, and scaled so its loudest sample is
1 dB under full scale.

The background noises are three-second cuts (0.76 s for the mouse click)
of recordings on Wikimedia Commons, mixed to mono, resampled to 16 kHz by
ffmpeg and normalised to -20 dBFS RMS with the loudest sample 1 dB under
full scale (quieter where that cap binds):

| File | Recording | Author | Licence |
|------|-----------|--------|---------|
| `background_applause_16k.wav` | "277021 sandermotions applause-2.wav", 0.2–3.2 s | Sandermotions (freesound.org) | CC0 |
| `background_hand_claps_16k.wav` | "Palmas sevillanas (flamenco clapping), 160 BPM.ogg", 10–13 s | Santiago Sánchez Cifuentes | CC0 |
| `background_keyboard_mechanical_16k.wav` | "Typing - Model M 1986.ogg", 1–4 s | Raymangold22 | CC0 |
| `background_keyboard_desktop_16k.wav` | "Keyboard noise.ogg", 2–5 s | Yuyudevil | public domain |
| `background_mouse_click_16k.wav` | "Computer mouse single click.ogg" | Darklanlan | CC0 |
| `background_pen_on_paper_16k.wav` | "292934-152 Writing-pen-paper-various marks and lines.wav", 2–5 s | Soundsnap | CC0 |
| `background_crowd_talking_16k.wav` | "442697-SBssa-Crowd Talking 003.wav", 30–33 s | Soundsnap | CC0 |
| `background_restaurant_16k.wav` | "Restaurant ambience.ogg", 20–23 s | stephan (pdsounds.org) | public domain |
| `background_piano_16k.wav` | "Beethowen-sonata32-musopen-maintheme.ogg", 0–3 s | Beethoven, played by Daniel Veesey (Musopen) | public domain |
| `background_electronic_beat_16k.wav` | "Witch house sample.ogg", 0–3 s | Zanahary | CC0 |
| `background_pop_song_16k.wav` | "Eternity Arcade - Lost in a Dream (vocal retro pop music made with AI).opus", 40–43 s | Eternity Arcade | CC BY 4.0 |

Music, white, pink and brown noise, mains hum and synthetic knocks in the
tests are made in `tests/common/mod.rs`, not fixtures.

## Rebuilding

```sh
sh testdata/fetch_sources.sh                        # into testdata/sources/, gitignored
cargo run -p audio_dsp --example make_fixtures
```

## Licences

The CMU ARCTIC cuts:

> Carnegie Mellon University, Copyright (c) 2003, All Rights Reserved.
>
> This voice is free for use for any purpose (commercial or otherwise)
> subject to the pretty light restrictions detailed below. Permission to use,
> copy, modify, and licence this software and its documentation for any
> purpose, is hereby granted without fee, subject to the following
> conditions: 1. The code must retain the above copyright notice, this list
> of conditions and the following disclaimer. 2. Any modifications must be
> clearly marked as such. 3. Original authors' names are not deleted.
>
> THE AUTHORS OF THIS WORK DISCLAIM ALL WARRANTIES WITH REGARD TO THIS
> SOFTWARE, INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS,
> IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY SPECIAL, INDIRECT OR
> CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE,
> DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
> TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
> PERFORMANCE OF THIS SOFTWARE.

See <http://festvox.org/cmu_arctic/> for the full databases.

`background_pop_song_16k.wav` is "Lost in a Dream" by Eternity Arcade,
licensed under CC BY 4.0 (<https://creativecommons.org/licenses/by/4.0/>),
from <https://commons.wikimedia.org/wiki/File:Eternity_Arcade_-_Lost_in_a_Dream_(vocal_retro_pop_music_made_with_AI).opus>;
cut, mixed to mono, resampled and normalised as above. The other background
recordings are CC0 or in the public domain (table above), and so is
`knuckles_on_table_16k.wav`.
