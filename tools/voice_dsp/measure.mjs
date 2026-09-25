// Lining a recording up with the noisy speech fixture and measuring what
// happened to its noise and its speech. Shared by the voice DSP loops in
// this directory.
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/// What the loops ask of noise suppression.
export const MIN_NOISE_DROP_DB = 20;
export const MAX_SPEECH_LOSS_DB = 4;
/// With everything off the noise has to come through (the control).
export const OFF_MAX_NOISE_DROP_DB = 3;
export const BLOCK = 480;
export const RATE = 48000;

/// The fixture from `cargo run -p audio_dsp --example noisy_speech`, built
/// into [fixtureDir] when missing.
export function loadFixture(repo, fixtureDir) {
  const wav = join(fixtureDir, "noisy_speech_48k.wav");
  if (!existsSync(wav)) {
    const r = spawnSync("cargo", ["run", "-q", "-p", "audio_dsp", "--release", "--example", "noisy_speech", "--", fixtureDir], {
      cwd: repo,
      stdio: "inherit",
    });
    if (r.status !== 0) throw new Error("could not build the fixture");
  }
  return { wav, labels: readFileSync(join(fixtureDir, "noisy_speech_48k.labels"), "utf8").trim(), blocks: wavBlocks(wav) };
}

/// Mean square per 10 ms block of a mono PCM16 WAV at 48 kHz, unit scale. A
/// data chunk whose length was never filled in (a recorder that was
/// stopped) runs to the end of the file.
export function wavBlocks(path) {
  const b = readFileSync(path);
  let pos = 12;
  while (pos + 8 <= b.length) {
    const id = b.toString("ascii", pos, pos + 4);
    let len = b.readUInt32LE(pos + 4);
    if (id === "data") {
      if (len === 0 || pos + 8 + len > b.length) len = b.length - pos - 8;
      const n = Math.floor(len / 2);
      const out = [];
      for (let k = 0; (k + 1) * BLOCK <= n; k++) {
        let acc = 0;
        for (let i = 0; i < BLOCK; i++) {
          const s = b.readInt16LE(pos + 8 + 2 * (k * BLOCK + i)) / 32768;
          acc += s * s;
        }
        out.push(acc / BLOCK);
      }
      return out;
    }
    pos += 8 + len + (len & 1);
  }
  throw new Error(`${path}: no data chunk`);
}

export const db = (x) => 10 * Math.log10(Math.max(x, 1e-12));

/// The offset (in blocks, [minLag, maxLag]) that best lines `b` up with
/// `a`, b[k] ~ a[k + lag], by correlating their levels in dB.
export function bestLag(a, b, minLag, maxLag, weight = () => true) {
  let best = { lag: 0, score: -Infinity };
  for (let lag = minLag; lag <= maxLag; lag++) {
    let sa = 0, sb = 0, sab = 0, saa = 0, sbb = 0, n = 0;
    for (let k = Math.max(0, -lag); k < b.length && k + lag < a.length; k++) {
      if (!weight(k + lag)) continue;
      const x = db(a[k + lag]), y = db(b[k]);
      sa += x; sb += y; sab += x * y; saa += x * x; sbb += y * y; n++;
    }
    if (n < 50) continue;
    const cov = sab / n - (sa / n) * (sb / n);
    const score = cov / Math.sqrt((saa / n - (sa / n) ** 2) * (sbb / n - (sb / n) ** 2) || 1);
    if (score > best.score) best = { lag, score };
  }
  return best;
}

/// Noise and speech of [processed] against [raw], both recorded on one
/// clock, over the fixture's labels: where in the fixture the recording
/// starts, then how far behind the processed side runs.
export function measure(fixture, raw, processed, { maxLatencyBlocks = 30 } = {}) {
  const start = bestLag(fixture.blocks, raw, -300, 300);
  const latency = bestLag(raw, processed, 0, maxLatencyBlocks, (k) => fixture.labels[k + start.lag] === "s");
  let rawN = 0, procN = 0, nN = 0, rawS = 0, procS = 0, nS = 0;
  for (let k = 0; k + latency.lag < processed.length && k < raw.length; k++) {
    const label = fixture.labels[k + start.lag];
    const p = processed[k + latency.lag];
    // The first half second: RNNoise and the gate settle.
    if (label === "n" && k + start.lag > 50) {
      rawN += raw[k]; procN += p; nN++;
    } else if (label === "s") {
      rawS += raw[k]; procS += p; nS++;
    }
  }
  return {
    startBlock: start.lag,
    alignment: +start.score.toFixed(3),
    latencyMs: latency.lag * 10,
    noiseBlocks: nN,
    speechBlocks: nS,
    noiseDropDb: +(db(rawN / nN) - db(procN / nN)).toFixed(1),
    speechChangeDb: +(db(procS / nS) - db(rawS / nS)).toFixed(1),
    rawNoiseDbfs: +db(rawN / nN).toFixed(1),
  };
}

/// Problems with a measurement of suppression that should be on.
export function suppressionProblems(m, label = "") {
  const p = [];
  const at = label ? `${label}: ` : "";
  if (!(m.noiseBlocks > 100 && m.speechBlocks > 100)) p.push(`${at}only ${m.noiseBlocks} noise and ${m.speechBlocks} speech blocks recorded`);
  if (m.alignment < 0.6) p.push(`${at}could not line the recording up with the fixture (${m.alignment})`);
  if (!(m.noiseDropDb >= MIN_NOISE_DROP_DB)) p.push(`${at}noise only ${m.noiseDropDb} dB down (want >= ${MIN_NOISE_DROP_DB})`);
  if (!(m.speechChangeDb >= -MAX_SPEECH_LOSS_DB)) p.push(`${at}speech ${m.speechChangeDb} dB (want >= -${MAX_SPEECH_LOSS_DB})`);
  return p;
}

