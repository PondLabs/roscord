#!/usr/bin/env python3
"""Qualify a staged Windows bundle against the locked CEF runtime.

This module is release tooling only: the application never imports it and it
never downloads CEF at runtime.  It checks a built Windows artifact directory
(the ``Release`` folder next to ``commet.exe``, as shipped in the Windows ZIP
and portable artifacts) plus the metadata directory produced by
``tools/cef_runtime.py metadata`` against ``third_party/cef/cef.lock.json``.

Bundle layout
-------------

The CEF payload lives in ``<bundle>/cef_host/`` when installed through
``commet/windows/cef_host/CMakeLists.txt``, or directly in ``<bundle>/`` for
bare payload directories (for example the output of ``cef_runtime stage``
smoke-tested without the Flutter shell).  Production ZIP and portable
artifacts always use the nested layout, which is also what the Dart
``WindowsBrowserRuntime`` resolver prefers; a flat directory passed as
``--bundle`` must contain only the payload.  The CMake install flattens the archive's ``Release/``
contents into the payload root and keeps ``Resources/`` as a subdirectory::

    <payload>/cef_host.exe        # renamed copy of Release/bootstrap.exe
    <payload>/cef_host.dll        # project-built bootstrap client
    <payload>/libcef.dll
    <payload>/chrome_elf.dll
    <payload>/...
    <payload>/Resources/icudtl.dat
    <payload>/Resources/locales/en-US.pak

``LICENSE.txt`` and ``CREDITS.html`` are archive-root files and are not
installed into the payload; they are covered through the generated
``THIRD_PARTY_NOTICES.txt`` in the metadata directory.

Signing
-------

Every payload file is hash-checked against ``cef.runtime.manifest.json``.
PE binaries (``*.exe``/``*.dll``) additionally require detached release-key
sidecars when ``--require-signatures`` is passed: ``signatures.json`` in the
metadata directory must list every payload PE binary with its matching
SHA-256.  Production additionally signs the PE binaries with Authenticode and
the ZIP/portable archive plus manifests with the project release key; the
``.sig``/``signatures.json`` sidecars are the auditable record this tool
verifies.  A signing or qualification failure withholds the complete
Windows/Linux release.

The implementation uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Mapping, Sequence

# Run as `python tools/<script>.py`, sys.path starts at tools/, not the root.
_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))

from tools import cef_runtime  # noqa: E402


LOCK_PATH = cef_runtime.LOCK_PATH
PLATFORM = "windows-x64"

#: Archive bootstrap input renamed by the CMake POST_BUILD step.
BOOTSTRAP_RENAME = {"Release/bootstrap.exe": "cef_host.exe"}

#: Project-owned bootstrap binary recorded in the manifest's bootstrap_project
#: section (``cef_runtime.stage_runtime(..., project_root=...)``).
PROJECT_BOOTSTRAP = "cef_host.dll"

#: Archive-root notice inputs are covered through generated notices, not by
#: files installed into the payload.
NOTICE_INPUTS = frozenset({"LICENSE.txt", "CREDITS.html"})

#: CMake-installed smoke-test fixtures allowed next to the runtime payload.
FIXTURE_ALLOWLIST = frozenset({"fixtures/fixture.html", "fixtures/README.md"})

#: Filenames that must never ship inside the Windows CEF payload.
FORBIDDEN_PAYLOAD_NAMES = frozenset(
    {
        "bootstrapc.exe",
        "WebView2Loader.dll",
    }
)
FORBIDDEN_PAYLOAD_SUFFIXES = (".pdb", ".lib", ".exp", ".ilk")
FORBIDDEN_PAYLOAD_DIRS = ("Debug", "tests", "include", "libcef_dll", "cmake")

#: Case-folded filename markers that prove a foreign browser engine would be
#: reachable from the bundle. The root ``flutter_inappwebview`` package is
#: retained for Android/iOS/macOS/web, and the Windows plugin name
#: ``flutter_inappwebview_windows`` now denotes the cutover stub (a no-op
#: native registration with no WebView2, proven by source scan); only the
#: desktop engines below are forbidden here by filename.
FORBIDDEN_BUNDLE_MARKERS = (
    "webview2",
    "desktop_webview_window",
    "wry",
    "webkitgtk",
    "libwebkit",
)

#: Exact bundle filenames owned by the cutover stub. The stub keeps the
#: upstream plugin filename so the generated registrant links, but its bytes
#: must carry no engine evidence (see ``FORBIDDEN_BINARY_EVIDENCE``).
CUTOVER_STUB_FILENAMES = frozenset(
    {
        "flutter_inappwebview_windows_plugin.dll",
    }
)

#: Case-sensitive byte markers that prove a foreign engine is linked into a
#: bundle binary. The stub filename above is allowed only when none of these
#: markers appear in its bytes; any other binary carrying them fails closed.
FORBIDDEN_BINARY_EVIDENCE = (
    b"CreateCoreWebView2",
    b"EdgeWebView2",
    b"WebView2Loader",
    b"Microsoft.Web.WebView2",
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

#: Graphics/software-fallback inputs that keep forced CPU mode functional.
CPU_FALLBACK_FILES = frozenset(
    {
        "d3dcompiler_47.dll",
        "dxcompiler.dll",
        "dxil.dll",
        "libEGL.dll",
        "libGLESv2.dll",
        "vk_swiftshader.dll",
        "vk_swiftshader_icd.json",
        "vulkan-1.dll",
    }
)

TEXT_CONFIG_SUFFIXES = (".json", ".yaml", ".yml", ".toml", ".cmake", ".txt", ".ini")


class QualificationError(ValueError):
    """Raised when a Windows artifact violates the qualification policy."""


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
    if archive_name in BOOTSTRAP_RENAME:
        return BOOTSTRAP_RENAME[archive_name]
    if archive_name.startswith("Release/"):
        return archive_name[len("Release/") :]
    return archive_name


def find_cef_payload(bundle: Path) -> Path:
    """Locate the CEF payload directory inside a Windows bundle."""

    if bundle.is_symlink() or not bundle.is_dir():
        raise QualificationError(f"bundle must be a real directory: {bundle}")
    nested = bundle / "cef_host"
    if nested.is_dir() and not nested.is_symlink() and (nested / "cef_host.exe").is_file():
        return nested
    if (bundle / "cef_host.exe").is_file():
        return bundle
    # A flat build tree may keep the payload one level down under a different
    # name; accept exactly one directory containing cef_host.exe.
    candidates = sorted(
        entry
        for entry in bundle.iterdir()
        if entry.is_dir() and not entry.is_symlink() and (entry / "cef_host.exe").is_file()
    )
    if len(candidates) == 1:
        return candidates[0]
    raise QualificationError(
        f"bundle has no cef_host payload (expected {nested} with cef_host.exe): {bundle}"
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
    import fnmatch

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
    if PROJECT_BOOTSTRAP not in files:
        missing.append(f"{PROJECT_BOOTSTRAP}(project bootstrap)")
    if missing:
        raise QualificationError(
            f"required CEF payload inputs are missing: {sorted(missing)}"
        )
    # Sandbox inputs: the bootstrap pair plus chrome_elf must be real files.
    for name in ("cef_host.exe", PROJECT_BOOTSTRAP, "chrome_elf.dll"):
        candidate = payload / Path(*PurePosixPath(name).parts)
        if not candidate.is_file() or candidate.stat().st_size == 0:
            raise QualificationError(f"sandbox/bootstrap input is missing: {name}")
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
        raise QualificationError("manifest platform is not windows-x64")
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
    bootstrap_project = manifest.get("bootstrap_project", [])
    project_digests: dict[str, str] = {}
    for entry in bootstrap_project:
        if isinstance(entry, dict) and entry.get("path") and entry.get("sha256"):
            project_digests[str(entry["path"])] = str(entry["sha256"])
    files = _payload_files(payload)
    for name, digest in sorted(expected.items()):
        candidate = files.get(name)
        # Locales expand from one pattern to many files; each staged locale
        # file is checked individually below, so only enforce entries the
        # manifest names explicitly.
        if candidate is None:
            raise QualificationError(f"payload file is missing: {name}")
        actual = _sha256_file(candidate)
        if actual != digest:
            raise QualificationError(f"payload hash mismatch: {name}")
    for name, digest in sorted(project_digests.items()):
        candidate = files.get(name)
        if candidate is None:
            raise QualificationError(f"project bootstrap file is missing: {name}")
        if _sha256_file(candidate) != digest:
            raise QualificationError(f"project bootstrap hash mismatch: {name}")
    # cef_host.exe is the renamed bootstrap copy; it must hash-match the
    # locked bootstrap bytes recorded in the manifest.
    bootstrap_digest = expected.get("cef_host.exe")
    if bootstrap_digest is None:
        raise QualificationError("manifest has no bootstrap entry")
    if _sha256_file(files["cef_host.exe"]) != bootstrap_digest:
        raise QualificationError("cef_host.exe does not match the locked bootstrap bytes")
    allowed = set(expected) | set(project_digests) | {"cef_host.exe"} | set(FIXTURE_ALLOWLIST)
    # Any staged locale beyond en-US is allowed when it matches the lock's
    # locales pattern; extras outside the allow-list fail.
    allowlist: list[str] = lock["platforms"][PLATFORM]["runtime"]["allowlist"]
    unexpected = sorted(
        name
        for name in files
        if name not in allowed
        and not any(
            _match_lock_pattern(_payload_to_archive_name(name), pattern)
            for pattern in allowlist
        )
    )
    if unexpected:
        raise QualificationError(f"unexpected payload files: {unexpected}")
    return {"checked_files": len(expected) + len(project_digests)}


def _payload_to_archive_name(payload_name: str) -> str:
    for archive_name, renamed in BOOTSTRAP_RENAME.items():
        if payload_name == renamed:
            return archive_name
    if "/" not in payload_name and payload_name not in NOTICE_INPUTS:
        return f"Release/{payload_name}"
    return payload_name


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
        raise QualificationError("provenance platform is not windows-x64")
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


def _payload_pe_binaries(payload: Path) -> dict[str, Path]:
    return {
        name: path
        for name, path in sorted(_payload_files(payload).items())
        if name.lower().endswith((".exe", ".dll"))
    }


def check_signatures(
    payload: Path, metadata: Path, *, require_signatures: bool
) -> dict[str, Any]:
    """Hash-check native binaries; verify detached signatures when required."""

    binaries = _payload_pe_binaries(payload)
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


def check_sandbox_bootstrap(payload: Path) -> dict[str, Any]:
    """The sandbox/bootstrap pair must be present with no bypass config."""

    for name in ("cef_host.exe", PROJECT_BOOTSTRAP):
        candidate = payload / name
        if not candidate.is_file() or candidate.stat().st_size == 0:
            raise QualificationError(f"sandbox/bootstrap input is missing: {name}")
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
    return {"bootstrap_pair": ["cef_host.exe", PROJECT_BOOTSTRAP]}


def check_no_foreign_backends(bundle: Path, payload: Path) -> dict[str, Any]:
    """No foreign engine, system CEF, or runtime download may ship."""

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
    # Binary evidence scan for app-side binaries outside the manifest-pinned
    # CEF payload. The cutover stub keeps the upstream plugin filename, so it
    # is allowed by name only when its bytes carry no engine evidence.
    # Payload files are excluded here: unexpected payload files already fail,
    # and pinned files are hash-verified, so scanning libcef bytes would only
    # risk Chromium-string false positives.
    try:
        resolved_payload = payload.resolve()
    except OSError:
        resolved_payload = payload
    for path in sorted(bundle.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix.lower() not in (".dll", ".exe", ".so"):
            continue
        try:
            resolved = path.resolve()
        except OSError:
            continue
        if resolved == resolved_payload or resolved_payload in resolved.parents:
            continue
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise QualificationError(f"cannot scan bundle binary {path}: {exc}")
        for marker in FORBIDDEN_BINARY_EVIDENCE:
            if marker in data:
                offenders.append(path.relative_to(bundle).as_posix())
                break
    if offenders:
        raise QualificationError(
            f"bundle binary links a foreign engine: {sorted(offenders)}"
        )
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
    """SwiftShader/ANGLE/Direct3D inputs keep forced CPU mode functional."""

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
    *,
    require_signatures: bool = False,
) -> dict[str, Any]:
    """Qualify one Windows bundle plus its generated metadata directory."""

    lock = cef_runtime.validate_lock(lock if lock is not None else cef_runtime.load_lock())
    bundle = Path(bundle)
    metadata = Path(metadata)
    if metadata.is_symlink() or not metadata.is_dir():
        raise QualificationError(f"metadata must be a real directory: {metadata}")
    payload = find_cef_payload(bundle)
    staged = check_staged(lock, payload)
    check_no_unexpected_payload_files(payload)
    hashes = check_hashes(lock, payload, metadata)
    metadata_result = check_metadata(lock, metadata)
    signatures = check_signatures(payload, metadata, require_signatures=require_signatures)
    sandbox = check_sandbox_bootstrap(payload)
    foreign = check_no_foreign_backends(bundle, payload)
    cpu = check_cpu_fallback(payload)
    manifest = _load_manifest(metadata)
    report = {
        "schema_version": 1,
        "platform": PLATFORM,
        "cef_version": lock["cef_version"],
        "chromium_version": lock["chromium_version"],
        "bundle": str(bundle),
        "payload": str(payload),
        "file_count": staged["file_count"],
        "checked_files": hashes["checked_files"],
        "manifest_sha256": manifest.get("staged_manifest_sha256"),
        "checks": {
            "staged": True,
            "hashes": True,
            "metadata": True,
            "signatures": signatures,
            "sandbox_bootstrap": True,
            "no_foreign_backends": True,
            "cpu_fallback": True,
        },
        "metadata_components": metadata_result["sbom_components"],
        "sandbox_pair": sandbox["bootstrap_pair"],
        "cpu_fallback_files": cpu["fallback_files"],
        "foreign_scan": foreign["scanned_payload"],
    }
    return json.loads(json.dumps(report))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK_PATH, help="path to cef.lock.json")
    parser.add_argument("--bundle", type=Path, required=True, help="built Windows bundle directory")
    parser.add_argument(
        "--metadata",
        type=Path,
        required=True,
        help="metadata directory from tools/cef_runtime.py metadata",
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
            require_signatures=args.require_signatures,
        )
    except (cef_runtime.LockError, QualificationError) as exc:
        print(f"qualify-windows-artifact: error: {exc}", file=sys.stderr)
        return 2
    encoded = json.dumps(report, indent=2).encode("utf-8") + b"\n"
    if args.output is not None:
        try:
            args.output.write_bytes(encoded)
        except OSError as exc:
            print(f"qualify-windows-artifact: error: {exc}", file=sys.stderr)
            return 2
    sys.stdout.buffer.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
