#!/usr/bin/env python3
"""Qualify a staged Flatpak artifact against the locked CEF runtime.

This module is release tooling only: the application never imports it and it
never downloads CEF at runtime.  It checks a Flatpak files root (the
``/app`` content produced by ``flatpak-builder`` from
``commet/linux/flatpak/chat.commet.commetapp.yaml``) plus the metadata
directory produced by ``tools/cef_runtime.py metadata`` against
``third_party/cef/cef.lock.json``.

Bundle layout
-------------

The CEF payload lives under ``<bundle>/cef/`` where ``<bundle>`` is the
Flatpak files root (``build-dir/files`` at build time, ``/app`` at runtime).
The payload is the flattened ``linux-x64`` runtime: the archive's
``Release/`` contents are installed into the payload root and ``Resources/``
is kept as a subdirectory::

    <bundle>/cef/libcef.so
    <bundle>/cef/chrome-sandbox
    <bundle>/cef/libEGL.so
    <bundle>/cef/libGLESv2.so
    <bundle>/cef/libvk_swiftshader.so
    <bundle>/cef/libvulkan.so.1
    <bundle>/cef/v8_context_snapshot.bin
    <bundle>/cef/vk_swiftshader_icd.json
    <bundle>/cef/Resources/chrome_100_percent.pak
    <bundle>/cef/Resources/chrome_200_percent.pak
    <bundle>/cef/Resources/icudtl.dat
    <bundle>/cef/Resources/resources.pak
    <bundle>/cef/Resources/locales/en-US.pak

``LICENSE.txt`` and ``CREDITS.html`` are archive-root files and are not
installed into the payload; they are covered through the generated
``THIRD_PARTY_NOTICES.txt`` in the metadata directory.  The Flutter bundle
stays at ``<bundle>/commet/bundle``; the CEF payload is never loaded from a
host path such as ``/usr/lib``, ``/opt``, ``/run/host``, or ``/host``.

Manifest and portals
--------------------

``commet/linux/flatpak/chat.commet.commetapp.yaml`` must declare GNOME
Platform 48, ``x86_64``, and the least-privilege finish-args set (``ipc``,
``fallback-x11``, ``wayland``, ``pulseaudio``, ``network``, ``dri`` plus the
scoped ``xdg-download`` destination).  ``--device=all``, host/home
filesystem access, host OS bindings, ``flatpak-spawn`` escapes, and dynamic
permission broadening all fail closed.  File selection uses the FileChooser
portal, camera/microphone use the Camera portal plus app mediation, and
screen capture uses the ScreenCast/PipeWire portal with fresh consent per
request; denial, dismissal, timeout, disconnect, and unsupported outcomes
never broaden the sandbox.

Signing
-------

Every payload file is hash-checked against ``cef.runtime.manifest.json``.
Native binaries (``*.so``, ``*.so.*``, and ``chrome-sandbox``) additionally
require detached release-key sidecars when ``--require-signatures`` is
passed: ``signatures.json`` in the metadata directory must list every native
binary with its matching SHA-256.  Production additionally signs the OSTree
repository/commit and the standalone ``.flatpak`` bundle plus manifests with
the project release key; the ``.sig``/``signatures.json`` sidecars are the
auditable record this tool verifies.  A signing or qualification failure
withholds the complete Windows/Linux release.

The implementation uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

from tools import cef_runtime


LOCK_PATH = cef_runtime.LOCK_PATH
PLATFORM = "linux-x64"

#: Default manifest path relative to the repository root.
DEFAULT_MANIFEST = (
    Path(__file__).resolve().parents[1]
    / "commet"
    / "linux"
    / "flatpak"
    / "chat.commet.commetapp.yaml"
)

#: Archive-root notice inputs are covered through generated notices, not by
#: files installed into the payload.
NOTICE_INPUTS = frozenset({"LICENSE.txt", "CREDITS.html"})

#: CMake-installed smoke-test fixtures allowed next to the runtime payload.
FIXTURE_ALLOWLIST = frozenset({"fixtures/fixture.html", "fixtures/README.md"})

#: Filenames that must never ship inside the Flatpak CEF payload.
FORBIDDEN_PAYLOAD_NAMES = frozenset(
    {
        "bootstrapc.exe",
        "WebView2Loader.dll",
        "libcef.dll",
        "chrome_elf.dll",
    }
)
FORBIDDEN_PAYLOAD_SUFFIXES = (".pdb", ".lib", ".exp", ".ilk", ".dll")
FORBIDDEN_PAYLOAD_DIRS = ("Debug", "tests", "include", "libcef_dll", "cmake")

#: Case-folded filename markers that prove a foreign browser engine would be
#: reachable from the bundle.
FORBIDDEN_BUNDLE_MARKERS = (
    "webkitgtk",
    "libwebkit",
    "wry",
    "webview2",
    "desktop_webview_window",
    "inappwebview",
)

#: CEF download artifacts must never ship inside the bundle; the application
#: has no runtime download path.
FORBIDDEN_BUNDLE_ARCHIVE_MARKERS = ("cef_binary_",)

#: Sandbox-bypass switches that must not appear in any shipped text config.
FORBIDDEN_SANDBOX_SWITCHES = (
    "--no-sandbox",
    "--disable-web-security",
    "--allow-file-access-from-files",
    "--remote-debugging-port",
)

#: Host filesystem roots that must never back a Flatpak surface.
FORBIDDEN_HOST_PATH_MARKERS = (
    "/run/host",
    "/host",
    "filesystem=host",
    "filesystem=home",
    "flatpak-spawn",
    "flatpak override",
)

#: Graphics/software-fallback inputs that keep forced CPU mode functional.
CPU_FALLBACK_FILES = frozenset(
    {
        "libEGL.so",
        "libGLESv2.so",
        "libvk_swiftshader.so",
        "libvulkan.so.1",
        "vk_swiftshader_icd.json",
    }
)

#: Least-privilege finish-args that must be present in the Flatpak manifest.
REQUIRED_FINISH_ARGS = (
    "--share=ipc",
    "--socket=fallback-x11",
    "--socket=wayland",
    "--socket=pulseaudio",
    "--share=network",
    "--device=dri",
)

#: Finish-arg fragments that broaden the sandbox beyond least privilege.
FORBIDDEN_FINISH_ARG_FRAGMENTS = (
    "--device=all",
    "filesystem=host",
    "filesystem=home",
    "/run/host",
    "host-os",
    "flatpak-spawn",
    "org.freedesktop.flatpak.spawn",
    "dynamic permission",
    "broadening",
)

TEXT_CONFIG_SUFFIXES = (".json", ".yaml", ".yml", ".toml", ".cmake", ".txt", ".ini")


class QualificationError(ValueError):
    """Raised when a Flatpak artifact violates the qualification policy."""


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise QualificationError(f"cannot read JSON file {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise QualificationError(f"JSON root must be an object: {path}")
    return value


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as exc:
        raise QualificationError(f"cannot read file {path}: {exc}") from exc
    return digest.hexdigest()


def _payload_relative(payload: Path, path: Path) -> str:
    return path.relative_to(payload).as_posix()


def _lock_to_payload_name(archive_name: str) -> str:
    """Map a lock ``Release/...``/``Resources/...`` name to payload layout."""
    if archive_name.startswith("Release/"):
        return archive_name[len("Release/") :]
    return archive_name


def _payload_to_archive_name(payload_name: str) -> str:
    if "/" not in payload_name and payload_name not in NOTICE_INPUTS:
        return f"Release/{payload_name}"
    return payload_name


def find_cef_payload(bundle: Path) -> Path:
    """Locate the CEF payload directory inside a Flatpak files root."""

    if bundle.is_symlink() or not bundle.is_dir():
        raise QualificationError(f"bundle must be a real directory: {bundle}")
    candidates = [
        bundle / "cef",
        bundle / "files" / "cef",
        bundle / "commet" / "bundle" / "cef",
        bundle,
    ]
    for candidate in candidates:
        if (
            candidate.is_dir()
            and not candidate.is_symlink()
            and (candidate / "libcef.so").is_file()
        ):
            return candidate
    # A flatpak-builder build dir keeps files under files/; accept exactly
    # one nested directory containing libcef.so.
    nested: list[Path] = []
    for entry in sorted(bundle.iterdir()):
        if entry.is_dir() and not entry.is_symlink():
            inner = entry / "cef"
            if inner.is_dir() and (inner / "libcef.so").is_file():
                nested.append(inner)
            elif (entry / "libcef.so").is_file():
                nested.append(entry)
    if len(nested) == 1:
        return nested[0]
    raise QualificationError(
        f"bundle has no cef payload (expected <bundle>/cef with libcef.so): {bundle}"
    )


def _payload_files(payload: Path) -> dict[str, Path]:
    files: dict[str, Path] = {}
    for path in sorted(payload.rglob("*")):
        if path.is_symlink():
            raise QualificationError(f"payload contains a symlink: {path}")
        if path.is_file():
            files[_payload_relative(payload, path)] = path
    return files


def _match_lock_pattern(path: str, pattern: str) -> bool:
    return fnmatch.fnmatchcase(path, pattern)


def check_staged(lock: Mapping[str, Any], payload: Path) -> dict[str, Any]:
    """Every locked runtime input must be staged in the payload."""

    record = lock["platforms"][PLATFORM]
    required: list[str] = record["runtime"]["required"]
    files = _payload_files(payload)
    missing: list[str] = []
    for pattern in required:
        if pattern in NOTICE_INPUTS:
            continue
        payload_pattern = _lock_to_payload_name(pattern)
        if not any(_match_lock_pattern(name, payload_pattern) for name in files):
            missing.append(pattern)
    if "Resources/locales/en-US.pak" not in files:
        missing.append("Resources/locales/en-US.pak(en-US locale)")
    if missing:
        raise QualificationError(
            f"required CEF payload inputs are missing: {sorted(missing)}"
        )
    for name in ("libcef.so", "chrome-sandbox", "v8_context_snapshot.bin"):
        candidate = payload / Path(*PurePosixPath(name).parts)
        if not candidate.is_file() or candidate.stat().st_size == 0:
            raise QualificationError(f"sandbox/helper input is missing: {name}")
    return {"payload": str(payload), "file_count": len(files)}


def check_no_unexpected_payload_files(payload: Path) -> dict[str, Any]:
    for relative in sorted(_payload_files(payload)):
        lowered = relative.lower()
        if PurePosixPath(relative).parts[0] in FORBIDDEN_PAYLOAD_DIRS:
            raise QualificationError(f"forbidden payload directory file: {relative}")
        if relative in FORBIDDEN_PAYLOAD_NAMES or lowered in (
            name.lower() for name in FORBIDDEN_PAYLOAD_NAMES
        ):
            raise QualificationError(f"forbidden payload file: {relative}")
        if lowered.endswith(FORBIDDEN_PAYLOAD_SUFFIXES):
            raise QualificationError(f"forbidden payload file: {relative}")
    return {"unexpected_files": 0}


def _load_manifest(metadata: Path) -> dict[str, Any]:
    manifest_path = metadata / "cef.runtime.manifest.json"
    if not manifest_path.is_file():
        raise QualificationError(f"metadata is missing cef.runtime.manifest.json: {metadata}")
    return _read_json(manifest_path)


def check_hashes(
    lock: Mapping[str, Any], payload: Path, metadata: Path
) -> dict[str, Any]:
    """Payload bytes must match the signed-byte-ready manifest."""

    manifest = _load_manifest(metadata)
    if manifest.get("platform") != PLATFORM:
        raise QualificationError("manifest platform is not linux-x64")
    if manifest.get("cef_version") != lock["cef_version"]:
        raise QualificationError("manifest CEF version does not match the lock")
    if manifest.get("raw_manifest_sha256") != lock["platforms"][PLATFORM]["raw_manifest_sha256"]:
        raise QualificationError("manifest raw digest does not match the lock")
    manifest_files = manifest.get("files")
    if not isinstance(manifest_files, list) or not manifest_files:
        raise QualificationError("manifest has no file entries")
    expected: dict[str, str] = {}
    for entry in manifest_files:
        if not isinstance(entry, dict):
            raise QualificationError("manifest file entry must be an object")
        archive_path = str(entry.get("path", ""))
        digest = str(entry.get("sha256", ""))
        if not archive_path or not digest:
            raise QualificationError("manifest file entry is missing path/sha256")
        if archive_path in NOTICE_INPUTS:
            continue
        expected[_lock_to_payload_name(archive_path)] = digest
    files = _payload_files(payload)
    for name, digest in sorted(expected.items()):
        candidate = files.get(name)
        if candidate is None:
            raise QualificationError(f"payload file is missing: {name}")
        actual = _sha256_file(candidate)
        if actual != digest:
            raise QualificationError(f"payload hash mismatch: {name}")
    allowlist: list[str] = lock["platforms"][PLATFORM]["runtime"]["allowlist"]
    unexpected = sorted(
        name
        for name in files
        if name not in expected
        and name not in FIXTURE_ALLOWLIST
        and not any(
            _match_lock_pattern(_payload_to_archive_name(name), pattern)
            for pattern in allowlist
        )
    )
    if unexpected:
        raise QualificationError(f"unexpected payload files: {unexpected}")
    return {"checked_files": len(expected)}


def check_metadata(lock: Mapping[str, Any], metadata: Path) -> dict[str, Any]:
    """Notices, SBOM, and provenance must be complete and lock-consistent."""

    record = lock["platforms"][PLATFORM]
    manifest = _load_manifest(metadata)
    notices_path = metadata / "THIRD_PARTY_NOTICES.txt"
    sbom_path = metadata / "cef.sbom.cdx.json"
    provenance_path = metadata / "cef.provenance.json"
    for path in (notices_path, sbom_path, provenance_path):
        if not path.is_file() or path.stat().st_size == 0:
            raise QualificationError(f"metadata file is missing: {path.name}")
    try:
        notices = notices_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise QualificationError(f"cannot read notices: {exc}") from exc
    for marker in (
        lock["cef_version"],
        lock["chromium_version"],
        "CEF LICENSE.txt",
        "CEF CREDITS.html",
    ):
        if marker not in notices:
            raise QualificationError(f"notices are missing marker: {marker}")
    sbom = _read_json(sbom_path)
    if sbom.get("bomFormat") != "CycloneDX" or sbom.get("specVersion") != "1.5":
        raise QualificationError("SBOM must be CycloneDX 1.5")
    components = sbom.get("components")
    if not isinstance(components, list):
        raise QualificationError("SBOM has no components")
    by_name = {
        component.get("name"): component
        for component in components
        if isinstance(component, dict)
    }
    cef_component = by_name.get("Chromium Embedded Framework")
    chromium_component = by_name.get("Chromium")
    if cef_component is None or chromium_component is None:
        raise QualificationError("SBOM is missing the CEF/Chromium components")
    if cef_component.get("version") != lock["cef_version"]:
        raise QualificationError("SBOM CEF version does not match the lock")
    if chromium_component.get("version") != lock["chromium_version"]:
        raise QualificationError("SBOM Chromium version does not match the lock")
    references = cef_component.get("externalReferences", [])
    urls = [
        reference.get("url")
        for reference in references
        if isinstance(reference, dict)
    ]
    if record["archive"]["url"] not in urls:
        raise QualificationError("SBOM CEF source URL does not match the lock")
    provenance = _read_json(provenance_path)
    if provenance.get("platform") != PLATFORM:
        raise QualificationError("provenance platform is not linux-x64")
    if provenance.get("cef_version") != lock["cef_version"]:
        raise QualificationError("provenance CEF version does not match the lock")
    if provenance.get("runtime_download") is not False:
        raise QualificationError("provenance must not allow a runtime download")
    if provenance.get("runtime_source") != "bundled-release-payload":
        raise QualificationError("provenance must name the bundled release payload")
    source = provenance.get("source", {})
    for field in ("url", "filename", "upstream_sha1", "project_sha256"):
        if source.get(field) != record["archive"][field]:
            raise QualificationError(f"provenance source.{field} does not match the lock")
    if provenance.get("raw_manifest_sha256") != record["raw_manifest_sha256"]:
        raise QualificationError("provenance raw digest does not match the lock")
    if provenance.get("staged_manifest_sha256") != manifest.get("staged_manifest_sha256"):
        raise QualificationError("provenance staged digest does not match the manifest")
    return {"sbom_components": len(components)}


def _payload_native_binaries(payload: Path) -> dict[str, Path]:
    binaries: dict[str, Path] = {}
    for name, path in sorted(_payload_files(payload).items()):
        lowered = name.lower()
        if (
            lowered.endswith(".so")
            or ".so." in lowered
            or Path(name).name == "chrome-sandbox"
        ):
            binaries[name] = path
    return binaries


def check_signatures(
    payload: Path, metadata: Path, *, require_signatures: bool
) -> dict[str, Any]:
    """Hash-check native binaries; verify detached signatures when required."""

    binaries = _payload_native_binaries(payload)
    if not binaries:
        raise QualificationError("payload has no native binaries")
    for name, path in binaries.items():
        if path.stat().st_size == 0:
            raise QualificationError(f"native binary is empty: {name}")
    sidecar = metadata / "signatures.json"
    if not require_signatures:
        return {"native_binaries": len(binaries), "signatures_required": False, "signed": False}
    if not sidecar.is_file():
        raise QualificationError(
            "signatures are required but metadata/signatures.json is missing"
        )
    signatures = _read_json(sidecar)
    entries = signatures.get("files")
    if signatures.get("version") != 1 or not isinstance(entries, dict):
        raise QualificationError("signatures.json must list version 1 file entries")
    missing = sorted(name for name in binaries if name not in entries)
    if missing:
        raise QualificationError(f"native binaries lack detached signatures: {missing}")
    for name, path in sorted(binaries.items()):
        expected = entries[name]
        if not isinstance(expected, str) or len(expected) != 64:
            raise QualificationError(f"detached signature is not a SHA-256: {name}")
        if _sha256_file(path) != expected.lower():
            raise QualificationError(f"detached signature mismatch: {name}")
    return {
        "native_binaries": len(binaries),
        "signatures_required": True,
        "signed": True,
        "algorithm": str(signatures.get("algorithm", "release-key")),
    }


def check_manifest(manifest_path: Path) -> dict[str, Any]:
    """The Flatpak manifest must pin GNOME 48, x86_64, and least privilege."""

    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise QualificationError(f"manifest must be a real file: {manifest_path}")
    try:
        text = manifest_path.read_text(encoding="utf-8")
    except OSError as exc:
        raise QualificationError(f"cannot read manifest {manifest_path}: {exc}") from exc
    for token in (
        "org.gnome.Platform",
        "48",
        "x86_64",
        "chat.commet.commetapp",
        "/app",
    ):
        if token not in text:
            raise QualificationError(f"manifest is missing required token: {token}")
    for need in REQUIRED_FINISH_ARGS:
        if need not in text:
            raise QualificationError(f"manifest misses a least-privilege permission: {need}")
    lowered = text.lower()
    for fragment in FORBIDDEN_FINISH_ARG_FRAGMENTS:
        if fragment.lower() in lowered:
            raise QualificationError(
                f"manifest broadens the sandbox beyond least privilege: {fragment}"
            )
    if "--device=all" in text:
        raise QualificationError("manifest must not grant --device=all")
    return {"manifest": str(manifest_path)}


def check_sandbox_helpers(payload: Path) -> dict[str, Any]:
    """The sandbox/helper pair must be present with no bypass config."""

    for name in ("libcef.so", "chrome-sandbox"):
        candidate = payload / name
        if not candidate.is_file() or candidate.stat().st_size == 0:
            raise QualificationError(f"sandbox/helper input is missing: {name}")
    for name, path in sorted(_payload_files(payload).items()):
        if not name.lower().endswith(TEXT_CONFIG_SUFFIXES):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        for switch in FORBIDDEN_SANDBOX_SWITCHES:
            if switch in text:
                raise QualificationError(
                    f"shipped config weakens the sandbox: {name} contains {switch}"
                )
        lowered = text.lower()
        for marker in FORBIDDEN_HOST_PATH_MARKERS:
            if marker.lower() in lowered and "qualify_flatpak_artifact" not in lowered:
                raise QualificationError(
                    f"shipped config references a host escape: {name} contains {marker}"
                )
    return {"sandbox_pair": ["libcef.so", "chrome-sandbox"]}


def check_no_foreign_backends(bundle: Path, payload: Path) -> dict[str, Any]:
    """No foreign engine, host CEF/WebKitGTK, or runtime download may ship."""

    offenders: list[str] = []
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        lowered = path.name.lower()
        if any(marker in lowered for marker in FORBIDDEN_BUNDLE_MARKERS):
            offenders.append(path.relative_to(bundle).as_posix())
        elif any(marker in lowered for marker in FORBIDDEN_BUNDLE_ARCHIVE_MARKERS):
            offenders.append(path.relative_to(bundle).as_posix())
    if offenders:
        raise QualificationError(f"bundle ships a foreign backend: {sorted(offenders)}")
    for name, path in sorted(_payload_files(payload).items()):
        if not name.lower().endswith(TEXT_CONFIG_SUFFIXES):
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeError):
            continue
        if cef_runtime.SOURCE_HOST in text and "cef_runtime" not in text:
            raise QualificationError(f"payload config references a CEF download: {name}")
    return {"scanned_payload": str(payload)}


def check_cpu_fallback(payload: Path) -> dict[str, Any]:
    """SwiftShader/ANGLE inputs keep forced CPU mode functional."""

    files = _payload_files(payload)
    missing = sorted(name for name in CPU_FALLBACK_FILES if name not in files)
    if missing:
        raise QualificationError(f"CPU fallback inputs are missing: {missing}")
    for name in sorted(CPU_FALLBACK_FILES):
        if files[name].stat().st_size == 0:
            raise QualificationError(f"CPU fallback input is empty: {name}")
    return {"fallback_files": len(CPU_FALLBACK_FILES)}


def qualify(
    bundle: Path | str,
    metadata: Path | str,
    lock: Mapping[str, Any] | None = None,
    manifest: Path | str | None = None,
    *,
    require_signatures: bool = False,
) -> dict[str, Any]:
    """Qualify one Flatpak files root plus its generated metadata directory."""

    lock = cef_runtime.validate_lock(lock if lock is not None else cef_runtime.load_lock())
    bundle = Path(bundle)
    metadata = Path(metadata)
    if metadata.is_symlink() or not metadata.is_dir():
        raise QualificationError(f"metadata must be a real directory: {metadata}")
    manifest_path = Path(manifest) if manifest is not None else DEFAULT_MANIFEST
    payload = find_cef_payload(bundle)
    staged = check_staged(lock, payload)
    check_no_unexpected_payload_files(payload)
    hashes = check_hashes(lock, payload, metadata)
    metadata_result = check_metadata(lock, metadata)
    signatures = check_signatures(payload, metadata, require_signatures=require_signatures)
    manifest_result = check_manifest(manifest_path)
    sandbox = check_sandbox_helpers(payload)
    foreign = check_no_foreign_backends(bundle, payload)
    cpu = check_cpu_fallback(payload)
    manifest_doc = _load_manifest(metadata)
    report = {
        "schema_version": 1,
        "platform": PLATFORM,
        "cef_version": lock["cef_version"],
        "chromium_version": lock["chromium_version"],
        "bundle": str(bundle),
        "payload": str(payload),
        "manifest": manifest_result["manifest"],
        "file_count": staged["file_count"],
        "checked_files": hashes["checked_files"],
        "manifest_sha256": manifest_doc.get("staged_manifest_sha256"),
        "checks": {
            "staged": True,
            "hashes": True,
            "metadata": True,
            "signatures": signatures,
            "manifest": True,
            "sandbox_helpers": True,
            "no_foreign_backends": True,
            "cpu_fallback": True,
        },
        "metadata_components": metadata_result["sbom_components"],
        "sandbox_pair": sandbox["sandbox_pair"],
        "cpu_fallback_files": cpu["fallback_files"],
        "foreign_scan": foreign["scanned_payload"],
    }
    return json.loads(json.dumps(report))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK_PATH, help="path to cef.lock.json")
    parser.add_argument("--bundle", type=Path, required=True, help="Flatpak files root (/app content)")
    parser.add_argument(
        "--metadata",
        type=Path,
        required=True,
        help="metadata directory from tools/cef_runtime.py metadata",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=DEFAULT_MANIFEST,
        help="path to chat.commet.commetapp.yaml",
    )
    parser.add_argument(
        "--require-signatures",
        action="store_true",
        help="require detached release-key signatures for every native binary",
    )
    parser.add_argument("--output", type=Path, help="write the JSON report to a file")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        lock = cef_runtime.load_lock(args.lock)
        report = qualify(
            args.bundle,
            args.metadata,
            lock,
            manifest=args.manifest,
            require_signatures=args.require_signatures,
        )
    except (cef_runtime.LockError, QualificationError) as exc:
        print(f"qualify-flatpak-artifact: error: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2).encode("utf-8") + b"\n"
    if args.output is not None:
        try:
            args.output.write_bytes(encoded)
        except OSError as exc:
            print(f"qualify-flatpak-artifact: error: {exc}", file=sys.stderr)
            return 2
    sys.stdout.buffer.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
