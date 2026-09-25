// Per-10 ms mean square of each input, for tools/voice_dsp/web_noise_loop.mjs.
// Input 0 is the microphone as the browser hands it over, input 1 what the
// voice DSP graph publishes.
const BLOCK = 480;

class LevelRecorder extends AudioWorkletProcessor {
  constructor() {
    super();
    this.acc = [0, 0];
    this.n = 0;
    this.blocks = [[], []];
    this.port.onmessage = (e) => {
      if (e.data === "flush") this.port.postMessage({ raw: this.blocks[0], processed: this.blocks[1] });
    };
  }

  process(inputs) {
    const len = (inputs[0][0] || inputs[1][0] || []).length;
    for (let i = 0; i < len; i++) {
      for (let c = 0; c < 2; c++) {
        const ch = inputs[c] && inputs[c][0];
        const s = ch ? ch[i] : 0;
        this.acc[c] += s * s;
      }
      if (++this.n === BLOCK) {
        for (let c = 0; c < 2; c++) {
          this.blocks[c].push(this.acc[c] / BLOCK);
          this.acc[c] = 0;
        }
        this.n = 0;
      }
    }
    return true;
  }
}

registerProcessor("level-recorder", LevelRecorder);
