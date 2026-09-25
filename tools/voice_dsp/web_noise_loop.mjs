#!/usr/bin/env node
// Does the browser voice DSP take background noise out of what the app
// publishes, and leave the voice in?
//
// Chrome plays a fixture (speech over room noise, from
// `cargo run -p audio_dsp --example noisy_speech`) as its fake microphone.
// A test page runs the web root's own audio_dsp.js, audio_dsp.worklet.js and
// audio_dsp.wasm through `commetAudioDsp.create()`, the way the app's
// CommetWebTrackProcessor does, and records the level of the raw microphone
// and of the processed track (what LiveKit publishes) every 10 ms. The
// levels are lined up against the fixture's labels and compared.
//
//   node tools/voice_dsp/web_noise_loop.mjs [--web-root commet/web]
//        [--fixture-dir target/voice-fixtures] [--chrome google-chrome-stable]
//        [--scenario dsp,off,toggle,nowasm,badwasm,noworklet]
//
// --web-root is where audio_dsp.js, audio_dsp.worklet.js and audio_dsp.wasm
// are served from: commet/web after scripts/prepare-web.sh, or
// commet/build/web to check what a web build ships. Exits non-zero when a
// scenario does not come out as expected, and says why.
//
// Scenarios:
//   dsp     the app's defaults: noise at least MIN_NOISE_DROP_DB down,
//           speech no more than MAX_SPEECH_LOSS_DB down
//   off     suppression, gate and ducking off: noise must pass (proves the
//           loop can tell)
//   toggle  created with everything off, then setParams(defaults), as when
//           the preference flips mid-call: must suppress like dsp
//   nowasm  audio_dsp.wasm answers 404: probe() must say so (the app then
//           keeps the browser's suppressor on) and create() must fail, not
//           hand back a graph that passes audio through
//   badwasm audio_dsp.wasm is not WebAssembly: the same
//   noworklet audio_dsp.worklet.js answers 404: the same
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { dirname, extname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const MIN_NOISE_DROP_DB = 20;
const MAX_SPEECH_LOSS_DB = 4;
const OFF_MAX_NOISE_DROP_DB = 3;
const BLOCK = 480;
const RATE = 48000;

const here = dirname(fileURLToPath(import.meta.url));
const repo = resolve(here, "../..");

function arg(name, fallback) {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && i + 1 < process.argv.length ? process.argv[i + 1] : fallback;
}

const webRoot = resolve(repo, arg("web-root", "commet/web"));
const fixtureDir = resolve(repo, arg("fixture-dir", "target/voice-fixtures"));
const chrome = arg("chrome", process.env.CHROME || "google-chrome-stable");
const scenarios = arg("scenario", "dsp,off,toggle,nowasm,badwasm,noworklet").split(",");

function ensureFixture() {
  const wav = join(fixtureDir, "noisy_speech_48k.wav");
  if (!existsSync(wav)) {
    const r = spawnSync("cargo", ["run", "-q", "-p", "audio_dsp", "--release", "--example", "noisy_speech", "--", fixtureDir], {
      cwd: repo,
      stdio: "inherit",
    });
    if (r.status !== 0) throw new Error("could not build the fixture");
  }
  return { wav, labels: readFileSync(join(fixtureDir, "noisy_speech_48k.labels"), "utf8").trim(), blocks: fixtureBlocks(wav) };
}

// Mean square per 10 ms block of a mono PCM16 WAV, unit scale.
function fixtureBlocks(path) {
  const b = readFileSync(path);
  let pos = 12;
  while (pos + 8 <= b.length) {
    const id = b.toString("ascii", pos, pos + 4);
    const len = b.readUInt32LE(pos + 4);
    if (id === "data") {
      const n = len / 2;
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

const MIME = { ".js": "text/javascript", ".html": "text/html", ".wasm": "application/wasm" };

function serve({ broken }) {
  const server = createServer((req, res) => {
    const url = new URL(req.url, "http://x");
    let file;
    if (url.pathname === "/" || url.pathname === "/index.html") file = join(here, "harness/index.html");
    else if (url.pathname.startsWith("/__harness/")) file = join(here, "harness", url.pathname.slice("/__harness/".length));
    else if (["/audio_dsp.js", "/audio_dsp.worklet.js", "/audio_dsp.wasm"].includes(url.pathname)) {
      if (url.pathname === "/audio_dsp.wasm" && broken === "nowasm") file = null;
      else if (url.pathname === "/audio_dsp.worklet.js" && broken === "noworklet") file = null;
      else if (url.pathname === "/audio_dsp.wasm" && broken === "badwasm") {
        res.writeHead(200, { "content-type": "application/wasm" });
        res.end(Buffer.from("this is not WebAssembly"));
        return;
      } else file = join(webRoot, url.pathname.slice(1));
    }
    if (!file || !existsSync(file)) {
      res.writeHead(404);
      res.end();
      return;
    }
    res.writeHead(200, { "content-type": MIME[extname(file)] || "application/octet-stream" });
    res.end(readFileSync(file));
  });
  return new Promise((r) => server.listen(0, "127.0.0.1", () => r(server)));
}

async function runInChrome(url, wav, seconds) {
  const profile = mkdtempSync(join(tmpdir(), "voice-loop-chrome-"));
  const proc = spawn(
    chrome,
    [
      "--headless=new",
      "--no-sandbox",
      "--no-first-run",
      "--no-default-browser-check",
      `--user-data-dir=${profile}`,
      "--remote-debugging-port=0",
      "--use-fake-ui-for-media-stream",
      "--use-fake-device-for-media-stream",
      `--use-file-for-fake-audio-capture=${wav}%noloop`,
      "--autoplay-policy=no-user-gesture-required",
      "about:blank",
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );
  let stderr = "";
  proc.stderr.on("data", (d) => (stderr += d));
  try {
    const port = await new Promise((res, rej) => {
      const t = setTimeout(() => rej(new Error(`chrome did not start: ${stderr}`)), 15000);
      proc.stderr.on("data", () => {
        const m = stderr.match(/DevTools listening on ws:\/\/[^:]+:(\d+)\//);
        if (m) {
          clearTimeout(t);
          res(Number(m[1]));
        }
      });
    });
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const page = targets.find((t) => t.type === "page");
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((r, j) => {
      ws.onopen = r;
      ws.onerror = j;
    });
    let id = 0;
    const pending = new Map();
    const logs = [];
    ws.onmessage = (e) => {
      const msg = JSON.parse(e.data);
      if (msg.id && pending.has(msg.id)) {
        pending.get(msg.id)(msg);
        pending.delete(msg.id);
      } else if (msg.method === "Runtime.consoleAPICalled") {
        logs.push(`${msg.params.type}: ${msg.params.args.map((a) => a.value ?? a.description).join(" ")}`);
      } else if (msg.method === "Runtime.exceptionThrown") {
        logs.push(`exception: ${msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text}`);
      }
    };
    const send = (method, params = {}) =>
      new Promise((r) => {
        const mid = ++id;
        pending.set(mid, r);
        ws.send(JSON.stringify({ id: mid, method, params }));
      });
    await send("Runtime.enable");
    await send("Page.navigate", { url });
    const deadline = Date.now() + (seconds + 20) * 1000;
    for (;;) {
      await new Promise((r) => setTimeout(r, 250));
      const r = await send("Runtime.evaluate", { expression: "JSON.stringify(window.__result)", returnByValue: true });
      const v = r.result?.result?.value;
      if (v && v !== "null") {
        ws.close();
        return { ...JSON.parse(v), logs };
      }
      if (Date.now() > deadline) throw new Error(`no result from the page in time; console:\n${logs.join("\n")}`);
    }
  } finally {
    proc.kill("SIGKILL");
    rmSync(profile, { recursive: true, force: true });
  }
}

const db = (x) => 10 * Math.log10(Math.max(x, 1e-12));

// Offset (in blocks) that best lines `b` up with `a`: b[k] ~ a[k + lag].
function bestLag(a, b, maxLag, weight = () => true) {
  let best = { lag: 0, score: -Infinity };
  for (let lag = 0; lag <= maxLag; lag++) {
    let sa = 0, sb = 0, sab = 0, saa = 0, sbb = 0, n = 0;
    for (let k = 0; k < b.length && k + lag < a.length; k++) {
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

function measure(fixture, raw, processed) {
  // Where in the fixture the recording starts (it starts a little after
  // getUserMedia), then how far behind the processed track runs.
  const start = bestLag(fixture.blocks, raw, 300);
  const latency = bestLag(raw, processed, 30, (k) => fixture.labels[k + start.lag] === "s");
  let rawN = 0, procN = 0, nN = 0, rawS = 0, procS = 0, nS = 0;
  for (let k = 0; k + latency.lag < processed.length && k < raw.length; k++) {
    const label = fixture.labels[k + start.lag];
    const p = processed[k + latency.lag];
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

async function scenario(name, fixture) {
  const seconds = (fixture.blocks.length * BLOCK) / RATE + 1;
  const broken = ["nowasm", "badwasm", "noworklet"].includes(name);
  const server = await serve({ broken: broken ? name : null });
  try {
    const url = `http://127.0.0.1:${server.address().port}/?scenario=${broken ? "dsp" : name}&seconds=${seconds}`;
    const r = await runInChrome(url, fixture.wav, seconds);
    const problems = [];
    let summary = {};
    if (broken) {
      if (r.probe?.ok !== false || !r.probe?.reason) problems.push(`probe() said ${JSON.stringify(r.probe)}: the app would turn the browser's suppressor off for a DSP that cannot run`);
      if (!r.createError) problems.push("create() succeeded without a working audio_dsp.wasm: the graph would publish unprocessed audio");
      summary = { probe: r.probe, createError: r.createError };
    } else {
      if (r.probe?.ok !== true) problems.push(`probe() said ${JSON.stringify(r.probe)}`);
      if (r.createError) problems.push(`create() failed: ${r.createError}`);
      else {
        if (r.ready !== true) problems.push(`worklet ready = ${r.ready}`);
        if (r.errors.length) problems.push(`errors: ${r.errors.join("; ")}`);
        if (!r.raw || r.raw.length < 200) problems.push(`recorded ${r.raw?.length ?? 0} blocks`);
        else {
          summary = measure(fixture, r.raw, r.processed);
          if (summary.alignment < 0.6) problems.push(`could not line the recording up with the fixture (${summary.alignment})`);
          const lastReport = r.reports[r.reports.length - 1];
          summary.frames = lastReport?.frames;
          summary.nsActive = lastReport ? (lastReport.flags & 2) !== 0 : undefined;
          if (name === "off") {
            if (summary.noiseDropDb > OFF_MAX_NOISE_DROP_DB) problems.push(`noise dropped ${summary.noiseDropDb} dB with everything off`);
          } else {
            if (!(summary.noiseDropDb >= MIN_NOISE_DROP_DB)) problems.push(`noise only ${summary.noiseDropDb} dB down (want >= ${MIN_NOISE_DROP_DB})`);
            if (!(summary.speechChangeDb >= -MAX_SPEECH_LOSS_DB)) problems.push(`speech ${summary.speechChangeDb} dB (want >= -${MAX_SPEECH_LOSS_DB})`);
            if (!summary.nsActive) problems.push("the DSP does not report noise suppression active");
          }
        }
      }
    }
    return { name, ok: problems.length === 0, problems, summary, logs: r.logs };
  } finally {
    server.close();
  }
}

for (const f of ["audio_dsp.js", "audio_dsp.worklet.js", "audio_dsp.wasm"]) {
  if (!existsSync(join(webRoot, f))) {
    console.error(`${join(webRoot, f)} is missing${f.endsWith(".wasm") ? " (commet/scripts/prepare-web.sh builds it)" : ""}`);
    process.exit(1);
  }
}

const fixture = ensureFixture();
const results = await Promise.all(scenarios.map((s) => scenario(s, fixture)));
let failed = false;
for (const r of results) {
  console.log(`${r.ok ? "PASS" : "FAIL"} ${r.name} ${JSON.stringify(r.summary)}`);
  for (const p of r.problems) console.log(`     ${p}`);
  if (!r.ok) {
    failed = true;
    for (const l of r.logs) console.log(`     console ${l}`);
  }
}
process.exit(failed ? 1 : 0);
