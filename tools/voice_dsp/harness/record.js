// Records the level of two audio tracks every 10 ms, for
// tools/voice_dsp/web_noise_loop.mjs: the microphone as the browser hands
// it over, and what is being sent. Loaded by the test page, and injected
// into the app build in --app mode.
window.__voiceLoopRecord = async function (rawTrack, sentTrack, seconds) {
  const rec = new AudioContext({ sampleRate: 48000 });
  try {
    await rec.audioWorklet.addModule("/__harness/recorder.worklet.js");
    const node = new AudioWorkletNode(rec, "level-recorder", { numberOfInputs: 2, numberOfOutputs: 1 });
    rec.createMediaStreamSource(new MediaStream([rawTrack])).connect(node, 0, 0);
    rec.createMediaStreamSource(new MediaStream([sentTrack])).connect(node, 0, 1);
    const mute = rec.createGain();
    mute.gain.value = 0;
    node.connect(mute).connect(rec.destination);
    await rec.resume();
    await new Promise((r) => setTimeout(r, seconds * 1000));
    return await new Promise((resolve) => {
      node.port.onmessage = (e) => resolve(e.data);
      node.port.postMessage("flush");
    });
  } finally {
    await rec.close();
  }
};
