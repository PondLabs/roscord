// Main-thread glue for Commet's voice DSP in the browser.
//
// Builds the Web Audio graph around the AudioWorklet in audio_dsp.worklet.js:
//
//   mic track -> MediaStreamAudioSourceNode -+
//                                            +-> commet-dsp worklet -> MediaStreamAudioDestinationNode -> processedTrack
//   remote tracks -> MediaStreamAudioSourceNode (input 1, level only)
//
// Dart talks to window.commetAudioDsp through dart:js_interop; keeping the
// Web Audio calls here means the graph can be poked at from devtools.
(function () {
  const WORKLET_URL = "audio_dsp.worklet.js";
  const WASM_URL = "audio_dsp.wasm";
  const TARGET_RATE = 48000;
  const READY_TIMEOUT_MS = 5000;

  const supported =
    typeof AudioContext !== "undefined" &&
    typeof AudioWorkletNode !== "undefined" &&
    typeof WebAssembly !== "undefined" &&
    typeof MediaStreamAudioDestinationNode !== "undefined";

  // What the worklet (audio_dsp.worklet.js) checks and calls. Mirrors
  // rust/audio_dsp/src/ffi.rs; tools/voice_dsp/check_contracts.py keeps the
  // copies in step.
  const ABI_VERSION = 2;
  const PARAMS_SIZE = 24;
  const REPORT_SIZE = 28;
  const WORKLET_EXPORTS = [
    "commet_dsp_abi_version",
    "commet_dsp_params_size",
    "commet_dsp_report_size",
    "commet_dsp_create",
    "commet_dsp_destroy",
    "commet_dsp_set_params",
    "commet_dsp_get_report",
    "commet_dsp_process_stream",
    "commet_dsp_feed_render",
    "commet_dsp_alloc_f32",
    "commet_dsp_free_f32",
    "commet_dsp_params_alloc",
    "commet_dsp_params_free",
    "commet_dsp_report_alloc",
    "commet_dsp_report_free",
  ];

  let wasmPromise = null;
  function loadWasm() {
    if (!wasmPromise) {
      wasmPromise = fetch(WASM_URL).then((r) => {
        if (!r.ok) throw new Error("audio_dsp.wasm: HTTP " + r.status);
        return r.arrayBuffer();
      });
      wasmPromise.catch(() => {
        wasmPromise = null;
      });
    }
    return wasmPromise;
  }

  // Whether the DSP can run here: audio_dsp.wasm fetched, compiled and
  // speaking the worklet's ABI. The app asks before a call decides who
  // suppresses noise, so a missing or broken wasm is known up front, instead
  // of when the call's worklet fails with the browser's suppressor already
  // turned off. Only a success is kept: a fetch that failed is tried again.
  let probed = null;
  function probe() {
    if (probed) return probed;
    const attempt = (async () => {
      if (!supported) return { ok: false, reason: "this browser has no AudioWorklet or WebAssembly" };
      try {
        // The worklet module has to load too: a missing or broken
        // audio_dsp.worklet.js fails every call the same way.
        await new OfflineAudioContext(1, 128, TARGET_RATE).audioWorklet.addModule(WORKLET_URL);
        const bytes = await loadWasm();
        const { instance } = await WebAssembly.instantiate(bytes.slice(0), {});
        const ex = instance.exports;
        for (const name of WORKLET_EXPORTS) {
          if (typeof ex[name] !== "function") return { ok: false, reason: "audio_dsp.wasm has no " + name };
        }
        const abi = ex.commet_dsp_abi_version();
        if (abi !== ABI_VERSION) return { ok: false, reason: "audio_dsp.wasm is ABI " + abi + ", expected " + ABI_VERSION };
        if (ex.commet_dsp_params_size() !== PARAMS_SIZE || ex.commet_dsp_report_size() !== REPORT_SIZE) {
          return { ok: false, reason: "audio_dsp.wasm struct sizes do not match" };
        }
        return { ok: true, reason: "" };
      } catch (e) {
        return { ok: false, reason: String((e && e.message) || e) };
      }
    })();
    probed = attempt;
    attempt.then((r) => {
      if (!r.ok) {
        console.error("commetAudioDsp: " + r.reason);
        if (probed === attempt) probed = null;
      }
    });
    return attempt;
  }

  async function create(track, params) {
    if (!supported) throw new Error("AudioWorklet or WebAssembly not supported");
    if (!track || track.kind !== "audio") throw new Error("expected an audio MediaStreamTrack");

    // Own context: RNNoise is trained at 48 kHz and LiveKit's context runs at
    // the device rate.
    const ctx = new AudioContext({ sampleRate: TARGET_RATE, latencyHint: "interactive" });
    if (ctx.sampleRate !== TARGET_RATE) {
      console.warn("commetAudioDsp: context runs at " + ctx.sampleRate + " Hz, expected " + TARGET_RATE);
    }
    try {
      await ctx.audioWorklet.addModule(WORKLET_URL);
      const wasm = await loadWasm();

      const node = new AudioWorkletNode(ctx, "commet-dsp", {
        numberOfInputs: 2,
        numberOfOutputs: 1,
        outputChannelCount: [1],
        channelCount: 1,
        channelCountMode: "explicit",
        channelInterpretation: "speakers",
        // A copy per node: instantiate() may detach/neuter shared buffers in some engines.
        processorOptions: { wasm: wasm.slice(0), params: params || {} },
      });

      const source = ctx.createMediaStreamSource(new MediaStream([track]));
      const dest = ctx.createMediaStreamDestination();
      source.connect(node, 0, 0);
      node.connect(dest);

      const farEnd = new Map();
      // Microphone test: the processed signal can also go to the speakers.
      let monitoring = false;
      let readyResolve;
      let failure = null;
      const ready = new Promise((res) => (readyResolve = res));

      const graph = {
        context: ctx,
        node: node,
        processedTrack: dest.stream.getAudioTracks()[0],
        onReport: null,
        onError: null,
        ready: ready,
        setParams(p) {
          node.port.postMessage({ type: "params", params: p || {} });
        },
        addFarEnd(t) {
          if (!t || farEnd.has(t.id)) return;
          const s = ctx.createMediaStreamSource(new MediaStream([t]));
          s.connect(node, 0, 1);
          farEnd.set(t.id, s);
        },
        removeFarEnd(t) {
          if (!t) return;
          const s = farEnd.get(t.id);
          if (s) {
            try { s.disconnect(); } catch (e) {}
            farEnd.delete(t.id);
          }
        },
        setMonitor(enabled) {
          enabled = !!enabled;
          if (enabled === monitoring) return;
          monitoring = enabled;
          try {
            if (enabled) node.connect(ctx.destination);
            else node.disconnect(ctx.destination);
          } catch (e) {}
        },
        resume() {
          return ctx.resume();
        },
        get state() {
          return ctx.state;
        },
        async destroy() {
          monitoring = false;
          try { source.disconnect(); } catch (e) {}
          try { node.disconnect(); } catch (e) {}
          for (const s of farEnd.values()) {
            try { s.disconnect(); } catch (e) {}
          }
          farEnd.clear();
          try { node.port.postMessage({ type: "destroy" }); } catch (e) {}
          try { await ctx.close(); } catch (e) {}
        },
      };

      node.port.onmessage = (e) => {
        const msg = e.data || {};
        if (msg.type === "report" && graph.onReport) graph.onReport(msg.report);
        else if (msg.type === "ready") readyResolve(true);
        else if (msg.type === "error") {
          console.error("commetAudioDsp worklet: " + msg.message);
          failure = msg.message;
          readyResolve(false);
          if (graph.onError) graph.onError(msg.message);
        }
      };

      await ctx.resume();
      // Not before the DSP runs in the worklet: until then it passes the
      // microphone through untouched, and whoever publishes processedTrack
      // has turned the browser's suppressor off because ours is on.
      const started = await Promise.race([
        ready,
        new Promise((res) => setTimeout(() => res(false), READY_TIMEOUT_MS)),
      ]);
      if (started !== true) {
        await graph.destroy();
        throw new Error("audio_dsp worklet did not start: " + (failure || "no answer in " + READY_TIMEOUT_MS + " ms"));
      }
      return graph;
    } catch (err) {
      try { await ctx.close(); } catch (e) {}
      throw err;
    }
  }

  window.commetAudioDsp = { isSupported: supported, probe: probe, create: create };
})();
