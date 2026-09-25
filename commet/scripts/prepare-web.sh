#!/bin/sh -ve

# # Setup vodozemac
git clone https://github.com/famedly/dart-vodozemac.git .vodozemac
cd .vodozemac
git checkout 0.5.0
cargo install flutter_rust_bridge_codegen
flutter_rust_bridge_codegen build-web --dart-root dart --rust-root $(readlink -f rust) --release
cd ..
rm -f ./assets/vodozemac/vodozemac_bindings_dart*
mv .vodozemac/dart/web/pkg/vodozemac_bindings_dart* ./assets/vodozemac/
rm -rf .vodozemac

# Setup livekit web worker from the vendored copy (third_party/README.md)
(cd ../third_party/livekit-client-sdk-flutter && dart pub get && \
  dart compile js web/e2ee.worker.dart -o ../../commet/web/e2ee.worker.dart.js -m)

# Build the voice DSP (rust/audio_dsp) to WebAssembly for the AudioWorklet.
./scripts/build-audio-dsp-wasm.sh
