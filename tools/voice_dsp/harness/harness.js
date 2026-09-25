// Drives window.commetAudioDsp (commet/web/audio_dsp.js) the way the app
// does, with Chrome's fake microphone playing the fixture, and records what
// the published track carries. The result lands in window.__result for
// tools/voice_dsp/web_noise_loop.mjs.
//
// Query parameters:
//   scenario  dsp     the app's defaults (AudioDspSettings.toMap())
//             off     suppression, gate and ducking off: the control
//             toggle  created with "off", then setParams(the defaults), as
//                     the app does when the preference flips
//   seconds   how long to record
(async function () {
  const q = new URLSearchParams(location.search);
  const scenario = q.get("scenario") || "dsp";
  const seconds = Number(q.get("seconds") || "10");

  // AudioDspSettings.toMap() with the preferences at their defaults.
  const appDefaults = {
    noiseSuppression: true,
    gateMode: 2,
    farEndDucking: true,
    speakerBleed: true,
    gateThresholdDb: -50,
    gateFloorDb: -40,
    duckDepthDb: -20,
    duckFarThresholdDb: -45,
  };
  const off = { ...appDefaults, noiseSuppression: false, gateMode: 0, farEndDucking: false, speakerBleed: false };

  const result = { scenario, reports: [], errors: [] };
  window.__result = null;
  try {
    // The constraints MatrixLivekitBackend.join asks for while our
    // suppressor is on: the browser's off.
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: false, autoGainControl: true },
    });
    const track = stream.getAudioTracks()[0];

    // What the app asks before a call decides who suppresses noise.
    result.probe = await window.commetAudioDsp.probe();

    let graph;
    try {
      graph = await window.commetAudioDsp.create(track, scenario === "dsp" ? appDefaults : off);
    } catch (e) {
      result.createError = String(e);
      window.__result = result;
      return;
    }
    graph.onReport = (r) => result.reports.push(r);
    graph.onError = (m) => result.errors.push(String(m));
    result.ready = await Promise.race([graph.ready, new Promise((r) => setTimeout(() => r("timeout"), 5000))]);
    if (scenario === "toggle") graph.setParams(appDefaults);
    result.contextState = graph.state;

    const levels = await window.__voiceLoopRecord(track, graph.processedTrack, seconds);
    result.raw = levels.raw;
    result.processed = levels.processed;
    await graph.destroy();
  } catch (e) {
    result.errors.push(String(e && e.stack ? e.stack : e));
  }
  window.__result = result;
})();
