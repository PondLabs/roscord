#!/usr/bin/env node
// Measures the native noise loop (tools/voice_dsp/native_noise_loop.sh):
// WebRTC's own energy statistics for what the microphone test encoded
// (`media-source`, after the audio processing module and our hook), sampled
// while the noisy speech fixture played as the microphone, against the same
// statistic worked out on the fixture. Exits non-zero unless the noise came
// out suppressed and the speech intact.
//
//   node tools/voice_dsp/measure_stats.mjs <results dir> [--fixture-dir target/voice-fixtures]
//
// WebRTC's statistic is a peak held for about 110 ms (webrtc/audio/
// audio_level.cc), so the comparison is over stretches of the fixture's
// timeline, kept half a second clear of where noise and speech meet.
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { db, MAX_SPEECH_LOSS_DB, MIN_NOISE_DROP_DB } from "./measure.mjs";

const repo = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const dir = process.argv[2];
const i = process.argv.indexOf("--fixture-dir");
const fixtureDir = resolve(repo, i > 0 ? process.argv[i + 1] : "target/voice-fixtures");

// Seconds after the fixture starts.
const NOISE = [[1.0, 2.6], [9.2, 10.2]];
const SPEECH = [[3.3, 8.2]];

/// Energy per 10 ms of mono PCM16 at 48 kHz the way webrtc::voe::AudioLevel
/// accumulates it: the loudest sample, held and published every 11 frames,
/// then divided by 4.
function webrtcLevelEnergy(path) {
  const b = readFileSync(path);
  let pos = 12, data = null;
  while (pos + 8 <= b.length) {
    const id = b.toString("ascii", pos, pos + 4);
    const len = b.readUInt32LE(pos + 4);
    if (id === "data") data = { at: pos + 8, n: len / 2 };
    pos += 8 + len + (len & 1);
  }
  const frames = [];
  let absMax = 0, count = 0, level = 0;
  for (let f = 0; (f + 1) * 480 <= data.n; f++) {
    let peak = 0;
    for (let s = 0; s < 480; s++) peak = Math.max(peak, Math.abs(b.readInt16LE(data.at + 2 * (f * 480 + s))));
    absMax = Math.max(absMax, peak);
    if (count++ === 10) {
      level = absMax;
      count = 0;
      absMax >>= 2;
    }
    frames.push({ t: f * 0.01, energy: (level / 32767) ** 2 * 0.01, duration: 0.01 });
  }
  return frames;
}

function statsEnergy(dir) {
  const play = Number(readFileSync(join(dir, "play_ms.txt"), "utf8"));
  const rows = readFileSync(join(dir, "stats.csv"), "utf8").trim().split("\n").slice(1).map((l) => l.split(",").map(Number));
  const out = [];
  for (let k = 1; k < rows.length; k++) {
    const [ms, e, d] = rows[k], [pms, pe, pd] = rows[k - 1];
    if (!Number.isFinite(e) || !Number.isFinite(pe) || d <= pd) continue;
    out.push({ t: ((ms + pms) / 2 - play) / 1000, energy: e - pe, duration: d - pd });
  }
  return out;
}

function levelOver(samples, windows) {
  let e = 0, d = 0;
  for (const s of samples) {
    if (windows.some(([a, b]) => s.t >= a && s.t < b)) {
      e += s.energy;
      d += s.duration;
    }
  }
  return d > 0 ? db(e / d) : NaN;
}

const fixture = webrtcLevelEnergy(join(fixtureDir, "noisy_speech_48k.wav"));
const sent = statsEnergy(dir);
const m = {
  noiseInDb: +levelOver(fixture, NOISE).toFixed(1),
  noiseOutDb: +levelOver(sent, NOISE).toFixed(1),
  speechInDb: +levelOver(fixture, SPEECH).toFixed(1),
  speechOutDb: +levelOver(sent, SPEECH).toFixed(1),
  samples: sent.length,
};
m.noiseDropDb = +(m.noiseInDb - m.noiseOutDb).toFixed(1);
m.speechChangeDb = +(m.speechOutDb - m.speechInDb).toFixed(1);

const problems = [];
if (m.samples < 60) problems.push(`only ${m.samples} statistics samples`);
if (!(m.noiseDropDb >= MIN_NOISE_DROP_DB)) problems.push(`noise only ${m.noiseDropDb} dB down (want >= ${MIN_NOISE_DROP_DB})`);
if (!(m.speechChangeDb >= -MAX_SPEECH_LOSS_DB)) problems.push(`speech ${m.speechChangeDb} dB (want >= -${MAX_SPEECH_LOSS_DB})`);
console.log(`${problems.length ? "FAIL" : "PASS"} ${JSON.stringify(m)}`);
for (const p of problems) console.log(`     ${p}`);
process.exit(problems.length ? 1 : 0);
