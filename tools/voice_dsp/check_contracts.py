#!/usr/bin/env python3
"""The seams noise suppression depends on, checked without building anything.

Noise suppression runs through several languages that name each other by
string: Dart looks C symbols up in librust_lib_commet by name, calls method
channels the vendored LiveKit and flutter-webrtc plugins answer by name, the
browser loads files by URL and calls wasm exports by name, and three
languages mirror the same ABI version and struct sizes by hand. Nothing
fails to compile when one side is renamed or a merge drops the other, and
the app then runs without the DSP. This script is what fails instead.

    python3 tools/voice_dsp/check_contracts.py [--web-build commet/build/web]

--web-build also checks that a finished web build carries the DSP's files.
Exits non-zero and lists every broken contract. See
docs/voice-audio-processing.md, "What the tests guard".
"""
import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
LK = "third_party/livekit-client-sdk-flutter"
FW = "third_party/flutter-webrtc"

# `// COMMET` markers must never go down: a merge that loses one loses a
# change. Raise these when you add markers.
MARKER_FLOOR = {LK: 60, FW: 23}

# Local changes noise suppression depends on, each as (file, pattern, why).
MUST_CONTAIN = [
    (f"{LK}/shared_cpp/commet_external_audio_processing.h",
     r"SetCapturePostProcessing\(capture_\.get\(\)\)",
     "the DSP is installed on the APM's capture post-processing slot"),
    (f"{LK}/shared_cpp/commet_external_audio_processing.h",
     r"void Release\(\) override \{\}",
     "libwebrtc must never free the long-lived proxy (null Initialize crash, e316d80a)"),
    (f"{LK}/linux/livekit_plugin.cpp", r'#include "commet_external_audio_processing\.h"',
     "the Linux plugin hosts the DSP"),
    (f"{LK}/windows/livekit_plugin.cpp", r'#include "commet_external_audio_processing\.h"',
     "the Windows plugin hosts the DSP"),
    (f"{LK}/linux/livekit_plugin.cpp", r"make_unique<CommetExternalAudioProcessingHost>",
     "the Linux plugin creates the host on WebRTC's APM"),
    (f"{LK}/windows/livekit_plugin.cpp", r"make_unique<CommetExternalAudioProcessingHost>",
     "the Windows plugin creates the host on WebRTC's APM"),
    (f"{LK}/linux/livekit_plugin.cpp", r'ptr\("captureProcess"\)',
     "the Linux plugin reads the capture callback"),
    (f"{LK}/windows/livekit_plugin.cpp", r'ptr\("captureProcess"\)',
     "the Windows plugin reads the capture callback"),
    (f"{LK}/linux/CMakeLists.txt", r"shared_cpp", "the Linux plugin sees the shared headers"),
    (f"{LK}/windows/CMakeLists.txt", r"shared_cpp", "the Windows plugin sees the shared headers"),
    (f"{LK}/lib/livekit_client.dart", r"export 'src/support/native\.dart' show Native",
     "Native.setExternalAudioProcessing is reachable from the app"),
    (f"{LK}/lib/src/track/track.dart", r"void restoreOriginalTrack\(\)",
     "a stopped processor gives the sender the raw capture back"),
    (f"{LK}/lib/src/track/local/local.dart", r"sender!\.replaceTrack\(processor\.processedTrack!\)",
     "a processor set on a published track swaps the sender to its output"),
    (f"{LK}/lib/src/track/options.dart", r"processor: processor \?\? this\.processor",
     "AudioCaptureOptions.copyWith keeps the web DSP (24f5669f)"),
    (f"{LK}/lib/src/track/options.dart", r"stopAudioCaptureOnMute \?\? this\.stopAudioCaptureOnMute",
     "AudioCaptureOptions.copyWith keeps the microphone open through mute (24f5669f)"),
    (f"{FW}/common/cpp/include/loopback_capturer.h", r"void SetRawTap\(RawTap tap\)",
     "the system mix reaches the speaker bleed filter"),
    (f"{FW}/common/cpp/include/flutter_webrtc.h", r"CommetSystemAudioReference commet_reference_;",
     "flutter-webrtc owns the system audio reference"),
    ("rust/rust/src/lib.rs", r"^pub use audio_dsp;",
     "the commet_dsp_* symbols ship inside librust_lib_commet"),
    ("rust/rust/Cargo.toml", r'^audio_dsp = \{ path = "\.\./audio_dsp" \}',
     "librust_lib_commet links the DSP crate"),
    ("commet/web/index.html", r'<script src="audio_dsp\.js"></script>',
     "the web app loads the DSP glue"),
    ("commet/scripts/prepare-web.sh", r"^\./scripts/build-audio-dsp-wasm\.sh$",
     "prepare-web.sh builds audio_dsp.wasm"),
    ("commet/scripts/build-audio-dsp-wasm.sh", r"cargo build -p audio_dsp --release --target wasm32-unknown-unknown",
     "build-audio-dsp-wasm.sh builds audio_dsp.wasm"),
    ("commet/scripts/build-audio-dsp-wasm.sh", r"audio_dsp\.wasm \./web/audio_dsp\.wasm",
     "build-audio-dsp-wasm.sh puts audio_dsp.wasm where the web build picks it up"),
]


def read(rel):
    path = REPO / rel
    if not path.is_file():
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def check_markers(problems):
    for package, floor in MARKER_FLOOR.items():
        count = 0
        for path in (REPO / package).rglob("*"):
            if path.is_file() and path.suffix in {".dart", ".cc", ".cpp", ".h", ".txt", ".podspec", ".kt", ".java", ".m", ".mm", ".yaml"}:
                count += path.read_text(encoding="utf-8", errors="replace").count("COMMET")
        if count < floor:
            problems.append(
                f"{package}: {count} COMMET markers, at least {floor} expected. A merge "
                "dropped a local change; see third_party/README.md")


def check_must_contain(problems):
    for rel, pattern, why in MUST_CONTAIN:
        text = read(rel)
        if text is None:
            problems.append(f"{rel} is missing ({why})")
        elif not re.search(pattern, text, re.MULTILINE):
            problems.append(f"{rel} no longer has /{pattern}/: {why}")


def check_restart_keeps_processor(problems):
    text = read(f"{LK}/lib/src/track/local/local.dart") or ""
    body = text[text.find("Future<void> restartTrack("):]
    take = body.find("final processor = _processor;")
    stop = body.find("await stop();")
    if take < 0 or stop < 0 or take > stop:
        problems.append(
            f"{LK}/lib/src/track/local/local.dart: restartTrack must take the processor "
            "before stop(), which drops it (3bb94af6): every restart would send the raw "
            "microphone on the web")


def rust_exports():
    text = read("rust/audio_dsp/src/ffi.rs") or ""
    return set(re.findall(r'#\[no_mangle\]\s*pub extern "C" fn (commet_dsp_\w+)', text))


def check_symbols(problems):
    exports = rust_exports()
    users = {
        "commet/lib/client/components/voip/audio_processing/audio_processing_manager_native.dart": r"'(commet_dsp_\w+)'",
        "commet/web/audio_dsp.worklet.js": r"\.(commet_dsp_\w+)\(",
        "commet/web/audio_dsp.js": r'"(commet_dsp_\w+)"',
    }
    for rel, pattern in users.items():
        names = set(re.findall(pattern, read(rel) or ""))
        if not names:
            problems.append(f"{rel}: found no commet_dsp_* symbols to check")
        for name in sorted(names - exports):
            problems.append(f"{rel} uses {name}, which rust/audio_dsp/src/ffi.rs does not export")
    # The glue's probe has to vouch for every export the worklet calls.
    worklet = set(re.findall(r"\.(commet_dsp_\w+)\(", read("commet/web/audio_dsp.worklet.js") or ""))
    probed = set(re.findall(r'"(commet_dsp_\w+)"', read("commet/web/audio_dsp.js") or ""))
    for name in sorted(worklet - probed):
        problems.append(f"commet/web/audio_dsp.js: probe() does not check {name}, which the worklet calls")


def check_abi(problems):
    rust_abi = re.search(r"pub const ABI_VERSION: u32 = (\d+);", read("rust/audio_dsp/src/ffi.rs") or "")
    rust_sizes = re.search(r"commet_dsp_params_size\(\), (\d+)\);\s*assert_eq!\(commet_dsp_report_size\(\), (\d+)\);",
                           read("rust/audio_dsp/src/ffi.rs") or "")
    if not rust_abi or not rust_sizes:
        problems.append("rust/audio_dsp/src/ffi.rs: cannot find ABI_VERSION or the struct size test")
        return
    abi, params, report = rust_abi.group(1), rust_sizes.group(1), rust_sizes.group(2)
    expected = {
        "commet/lib/client/components/voip/audio_processing/audio_processing_manager_native.dart": [
            (r"static const expectedAbi = (\d+);", abi, "ABI"),
        ],
        "commet/web/audio_dsp.js": [
            (r"const ABI_VERSION = (\d+);", abi, "ABI"),
            (r"const PARAMS_SIZE = (\d+);", params, "Params size"),
            (r"const REPORT_SIZE = (\d+);", report, "Report size"),
        ],
        "commet/web/audio_dsp.worklet.js": [
            (r"const ABI_VERSION = (\d+);", abi, "ABI"),
            (r"const PARAMS_SIZE = (\d+);", params, "Params size"),
            (r"const REPORT_SIZE = (\d+);", report, "Report size"),
        ],
    }
    for rel, checks in expected.items():
        text = read(rel) or ""
        for pattern, want, what in checks:
            m = re.search(pattern, text)
            if not m:
                problems.append(f"{rel}: cannot find its {what}")
            elif m.group(1) != want:
                problems.append(f"{rel}: {what} {m.group(1)}, rust/audio_dsp says {want}")


def check_channels(problems):
    """Every commet* method channel call has a native handler."""
    native = "".join(read(rel) or "" for rel in [
        f"{LK}/linux/livekit_plugin.cpp",
        f"{LK}/windows/livekit_plugin.cpp",
        f"{FW}/common/cpp/src/flutter_webrtc.cc",
    ])
    handled = set(re.findall(r'"(commet[A-Z]\w+)"', native))
    for root in ["commet/lib", f"{LK}/lib"]:
        for path in (REPO / root).rglob("*.dart"):
            if "generated" in path.parts:
                continue
            for name in re.findall(r"'(commet[A-Z]\w+)'", path.read_text(encoding="utf-8", errors="replace")):
                if name == "commetAudioDsp":
                    continue
                if name not in handled:
                    problems.append(f"{path.relative_to(REPO)} calls {name}, which no plugin handles "
                                    "(livekit_plugin.cpp on Linux and Windows, flutter_webrtc.cc)")
    for name in ["commetSetExternalAudioProcessing", "commetClearExternalAudioProcessing"]:
        for rel in [f"{LK}/linux/livekit_plugin.cpp", f"{LK}/windows/livekit_plugin.cpp"]:
            if f'"{name}"' not in (read(rel) or ""):
                problems.append(f"{rel} does not handle {name}")
    if "window.commetAudioDsp = " not in (read("commet/web/audio_dsp.js") or ""):
        problems.append("commet/web/audio_dsp.js no longer defines window.commetAudioDsp, which the web app binds to")


def check_overrides(problems):
    pubspec = read("commet/pubspec.yaml") or ""
    overrides = pubspec[pubspec.find("dependency_overrides:"):]
    for package, path in [("livekit_client", "../third_party/livekit-client-sdk-flutter"),
                          ("flutter_webrtc", "../third_party/flutter-webrtc")]:
        if not re.search(rf"^  {package}:\s*\n\s+path: {re.escape(path)}\s*$", overrides, re.MULTILINE):
            problems.append(f"commet/pubspec.yaml: dependency_overrides no longer points {package} at "
                            f"{path}, so the vendored changes are not in the app")


def check_web_build(problems, build):
    for name in ["audio_dsp.js", "audio_dsp.worklet.js", "audio_dsp.wasm", "index.html"]:
        path = build / name
        if not path.is_file() or path.stat().st_size == 0:
            problems.append(f"{path}: missing from the web build (audio_dsp.wasm comes from "
                            "commet/scripts/prepare-web.sh)")
    wasm = build / "audio_dsp.wasm"
    if wasm.is_file() and wasm.read_bytes()[:4] != b"\0asm":
        problems.append(f"{wasm} is not WebAssembly")
    index = build / "index.html"
    if index.is_file() and 'src="audio_dsp.js"' not in index.read_text(encoding="utf-8", errors="replace"):
        problems.append(f"{index} does not load audio_dsp.js")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--web-build", type=Path, help="also check a finished web build")
    args = parser.parse_args()

    problems = []
    check_markers(problems)
    check_must_contain(problems)
    check_restart_keeps_processor(problems)
    check_symbols(problems)
    check_abi(problems)
    check_channels(problems)
    check_overrides(problems)
    if args.web_build:
        check_web_build(problems, args.web_build.resolve())

    for p in problems:
        print(f"FAIL {p}")
    if problems:
        print(f"{len(problems)} voice DSP contract(s) broken")
        return 1
    print("voice DSP contracts hold")
    return 0


if __name__ == "__main__":
    sys.exit(main())
