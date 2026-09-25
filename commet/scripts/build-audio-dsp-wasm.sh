#!/bin/sh -e
# Builds the voice DSP (rust/audio_dsp) to WebAssembly for the AudioWorklet
# and puts it in web/, where `flutter build web` picks it up. Run from
# commet/. Called by prepare-web.sh and by CI.
#
# Needs `rustup target add wasm32-unknown-unknown`. If cargo is not on PATH
# but docker is, the build runs in the official rust image.
if command -v cargo >/dev/null 2>&1; then
  (cd .. && cargo build -p audio_dsp --release --target wasm32-unknown-unknown)
else
  docker run --rm -v "$(readlink -f ..)":/w -w /w rust:1 \
    sh -c 'rustup target add wasm32-unknown-unknown >/dev/null && cargo build -p audio_dsp --release --target wasm32-unknown-unknown && chown -R '"$(id -u):$(id -g)"' /w/target'
fi
cp ../target/wasm32-unknown-unknown/release/audio_dsp.wasm ./web/audio_dsp.wasm
