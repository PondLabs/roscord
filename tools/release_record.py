#!/usr/bin/env python3
"""Signed atomic release record for the CEF BrowserRuntime cutover.

This module is release tooling only: the application never imports it and it
never launches CEF.  It defines the final gate artifact for epic #110 /
ticket #133: one signed JSON record that binds the exact CEF lock, staged
manifests, sandbox/bootstrap checks, notices, SBOM, signatures, per-package
evidence, matrix reports, failure-injection traces, and negative-backend
proof into a single Windows/Linux set.

Atomic rule: the record covers one Windows x64 artifact plus every released
Linux x64 artifact (Debian 12 baseline, each released Ubuntu .deb, the
portable archive, and the GNOME 48 x86_64 Flatpak).  Any missing or failing
section blocks publication of the entire desktop set, and rollback always
covers the whole set (never one platform alone, never a legacy engine).

Record shape::

    {
      "schema_version": 1,
      "release_version": "v1.2.3",
      "cef_lock": {"cef_version": ..., "chromium_version": ..., ...},
      "manifests": {"windows-x64": {...}, "linux-x64": {...}},
      "sandbox_bootstrap": {...},
      "notices_sbom": {...},
      "signatures": {...},
      "packages": {"windows-x64": {...}, ...},
      "matrix": {<qualify_release_candidate report>},
      "failure_traces": {...},
      "negative_backend": {...}
    }

Use ``--example`` to emit a passing template record and ``--self-check`` to
prove the gate blocks a mutated record (used by CI).

The implementation uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


_REPO_ROOT = Path(__file__).resolve().parents[1]
if str(_REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(_REPO_ROOT))


SCHEMA_VERSION = 1

#: Every released desktop artifact in the atomic set: one Windows build plus
#: every released Linux build (Debian 12 baseline, Ubuntu 22.04/24.04 debs,
#: portable archive, Flatpak bundle).
REQUIRED_PACKAGES = (
    "windows-x64",
    "debian-12",
    "ubuntu-22.04",
    "ubuntu-24.04",
    "portable",
    "flatpak",
)

#: Exact CEF/Chromium tuple pinned by third_party/cef/cef.lock.json.
LOCKED_CEF_VERSION = "152.0.8+g1ce985c+chromium-152.0.7977.134"
LOCKED_CHROMIUM_VERSION = "152.0.7977.134"
LOCKED_CEF_BRANCH = "7977"

#: Locked archive filenames (standard distribution, one tuple).
LOCKED_ARCHIVES = {
    "windows-x64": "cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_windows64.tar.bz2",
    "linux-x64": "cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_linux64.tar.bz2",
}

#: Upstream SHA-1 sidecars recorded in the lock.
LOCKED_SIDEEAR_SHA1 = {
    "windows-x64": "fcefc344b5508991727bae786b2392190379bbcc",
    "linux-x64": "add0a51f7333bc660e8e3bafd998e0122568f7d8",
}

#: Sandbox/bootstrap pairs that must be present per platform.
WINDOWS_BOOTSTRAP_PAIR = ("cef_host.exe", "client.dll", "chrome_elf.dll")
LINUX_SANDBOX_PAIR = ("libcef.so", "chrome-sandbox")

#: Sandbox-bypass switches that must never appear in shipped configs.
FORBIDDEN_SANDBOX_SWITCHES = (
    "--no-sandbox",
    "--disable-web-security",
    "--allow-file-access-from-files",
    "--remote-debugging-port",
)

#: Prohibited backends/markers that must be absent (mirrors the matrix gate).
PROHIBITED_X_MARKERS = (
    "webview2",
    "webkitgtk-wry-runner",
    "system-cef",
    "runtime-cef-download",
    "unowned-browser",
)


def required_packages() -> tuple[str, ...]:
    return REQUIRED_PACKAGES


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def record_digest(record: Mapping[str, Any]) -> str:
    """Deterministic SHA-256 over the record minus its signatures section."""
    payload = {k: v for k, v in record.items() if k != "signatures"}
    return hashlib.sha256(_canonical_json(payload)).hexdigest()


def _is_hex(value: Any, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(c in "0123456789abcdefABCDEF" for c in value)
        and set(value.lower()) != {"0"}
    )


class ReleaseBlocked(Exception):
    """Raised when the release record does not satisfy the atomic gate."""

    def __init__(self, failures: Sequence[str]) -> None:
        super().__init__("; ".join(failures))
        self.failures = list(failures)


def evaluate(
    report: Mapping[str, Any], *, require_signatures: bool = False
) -> dict[str, Any]:
    """Evaluate one signed release record against the atomic gate."""

    failures: list[str] = []
    if not isinstance(report, Mapping):
        return {"passed": False, "failures": ["release record must be an object"], "counts": {}}

    if report.get("schema_version") != SCHEMA_VERSION:
        failures.append(
            f"schema_version must be {SCHEMA_VERSION} (got {report.get('schema_version')!r})"
        )

    release_version = report.get("release_version")
    if not isinstance(release_version, str) or not release_version.strip():
        failures.append("release_version must be a non-empty string")

    # --- Exact lock/hashes. ---
    lock = report.get("cef_lock")
    if not isinstance(lock, Mapping):
        failures.append("release record is missing the cef_lock section")
        lock = {}
    if lock.get("cef_version") != LOCKED_CEF_VERSION:
        failures.append(
            f"cef_lock.cef_version must be {LOCKED_CEF_VERSION} (got {lock.get('cef_version')!r})"
        )
    if lock.get("chromium_version") != LOCKED_CHROMIUM_VERSION:
        failures.append("cef_lock.chromium_version does not match the locked tuple")
    if lock.get("cef_branch") != LOCKED_CEF_BRANCH:
        failures.append("cef_lock.cef_branch does not match the locked branch")
    if lock.get("distribution") != "standard":
        failures.append("cef_lock.distribution must be the official standard distribution")
    archives = lock.get("archives")
    if not isinstance(archives, Mapping):
        failures.append("cef_lock.archives must list windows-x64 and linux-x64")
        archives = {}
    for platform in ("windows-x64", "linux-x64"):
        entry = archives.get(platform)
        if not isinstance(entry, Mapping):
            failures.append(f"cef_lock.archives is missing {platform}")
            continue
        if entry.get("filename") != LOCKED_ARCHIVES[platform]:
            failures.append(f"cef_lock.archives.{platform}.filename is not the locked input")
        if not isinstance(entry.get("url"), str) or not entry["url"].startswith(
            "https://cef-builds.spotifycdn.com/"
        ):
            failures.append(f"cef_lock.archives.{platform}.url must be the locked origin")
        if not isinstance(entry.get("size"), int) or entry["size"] <= 0:
            failures.append(f"cef_lock.archives.{platform}.size must be positive")
        if entry.get("sha1") != LOCKED_SIDEEAR_SHA1[platform]:
            failures.append(f"cef_lock.archives.{platform}.sha1 does not match the sidecar")
        if not _is_hex(entry.get("sha256"), 64):
            failures.append(f"cef_lock.archives.{platform}.sha256 must be a real SHA-256")
        if not _is_hex(entry.get("raw_manifest_sha256"), 64):
            failures.append(
                f"cef_lock.archives.{platform}.raw_manifest_sha256 must be a real digest"
            )
    policy = lock.get("policy")
    if not isinstance(policy, Mapping):
        failures.append("cef_lock.policy is missing")
        policy = {}
    if policy.get("runtime_download") is not False:
        failures.append("cef_lock.policy.runtime_download must remain false")
    if policy.get("sbom_format") != "CycloneDX-1.5":
        failures.append("cef_lock.policy.sbom_format must be CycloneDX-1.5")

    # --- Manifests (raw + staged, both platforms). ---
    manifests = report.get("manifests")
    if not isinstance(manifests, Mapping):
        failures.append("release record is missing the manifests section")
        manifests = {}
    for platform in ("windows-x64", "linux-x64"):
        entry = manifests.get(platform)
        if not isinstance(entry, Mapping):
            failures.append(f"manifests section is missing {platform}")
            continue
        for field in ("raw_manifest_sha256", "staged_manifest_sha256"):
            if not _is_hex(entry.get(field), 64):
                failures.append(f"manifests.{platform}.{field} must be a real digest")
        if not isinstance(entry.get("file_count"), int) or entry["file_count"] <= 0:
            failures.append(f"manifests.{platform}.file_count must be positive")
        # Cross-check against the lock digests when both are present.
        lock_entry = archives.get(platform)
        if (
            isinstance(lock_entry, Mapping)
            and _is_hex(entry.get("raw_manifest_sha256"), 64)
            and _is_hex(lock_entry.get("raw_manifest_sha256"), 64)
            and entry.get("raw_manifest_sha256") != lock_entry.get("raw_manifest_sha256")
        ):
            failures.append(
                f"manifests.{platform}.raw_manifest_sha256 does not match cef_lock"
            )

    # --- Sandbox/bootstrap checks. ---
    sandbox = report.get("sandbox_bootstrap")
    if not isinstance(sandbox, Mapping):
        failures.append("release record is missing the sandbox_bootstrap section")
        sandbox = {}
    for name in WINDOWS_BOOTSTRAP_PAIR:
        if sandbox.get(f"windows_{name}_present") is not True:
            failures.append(f"sandbox_bootstrap.windows_{name}_present must be true")
    for name in LINUX_SANDBOX_PAIR:
        if sandbox.get(f"linux_{name}_present") is not True:
            failures.append(f"sandbox_bootstrap.linux_{name}_present must be true")
    if sandbox.get("bypass_flags_absent") is not True:
        failures.append("sandbox_bootstrap.bypass_flags_absent must be true")
    if sandbox.get("sandbox_info_forwarded") is not True:
        failures.append("sandbox_bootstrap.sandbox_info_forwarded must be true")

    # --- Notices + SBOM. ---
    notices = report.get("notices_sbom")
    if not isinstance(notices, Mapping):
        failures.append("release record is missing the notices_sbom section")
        notices = {}
    if notices.get("notices_present") is not True:
        failures.append("notices_sbom.notices_present must be true")
    if notices.get("sbom_format") != "CycloneDX-1.5":
        failures.append("notices_sbom.sbom_format must be CycloneDX-1.5")
    if notices.get("sbom_cef_version") != LOCKED_CEF_VERSION:
        failures.append("notices_sbom.sbom_cef_version does not match the lock")
    if notices.get("provenance_bundled") is not True:
        failures.append("notices_sbom.provenance_bundled must be true")
    if notices.get("runtime_download") is not False:
        failures.append("notices_sbom must not allow a runtime download")

    # --- Signatures (detached release-key sidecars + record signature). ---
    signatures = report.get("signatures")
    if not isinstance(signatures, Mapping):
        failures.append("release record is missing the signatures section")
        signatures = {}
    for package in REQUIRED_PACKAGES:
        entry = signatures.get(package)
        if require_signatures:
            if not isinstance(entry, Mapping) or entry.get("signed") is not True:
                failures.append(
                    f"signatures.{package}.signed must be true when signatures are required"
                )
            elif not _is_hex(entry.get("sha256"), 64):
                failures.append(f"signatures.{package}.sha256 must be a real digest")
        else:
            if entry is not None and not isinstance(entry, Mapping):
                failures.append(f"signatures.{package} must be an object when present")
    record_sig = signatures.get("record") if isinstance(signatures, Mapping) else None
    if require_signatures:
        if not isinstance(record_sig, Mapping) or record_sig.get("signed") is not True:
            failures.append("signatures.record.signed must be true when signatures are required")
        else:
            expected = record_digest(report)
            if record_sig.get("record_sha256") != expected:
                failures.append("signatures.record.record_sha256 does not match the record bytes")

    # --- Package evidence (atomic set: all or nothing). ---
    packages = report.get("packages")
    if not isinstance(packages, Mapping):
        failures.append("release record is missing the packages section")
        packages = {}
    pkg_passed = 0
    for package in REQUIRED_PACKAGES:
        entry = packages.get(package)
        if not isinstance(entry, Mapping):
            failures.append(f"package {package} blocks the candidate (missing evidence)")
            continue
        ok = True
        if entry.get("status") != "pass":
            failures.append(
                f"package {package} blocks the candidate (status={entry.get('status')!r})"
            )
            ok = False
        if not _is_hex(entry.get("artifact_sha256"), 64):
            failures.append(f"package {package} artifact_sha256 must be a real digest")
            ok = False
        if not isinstance(entry.get("artifact"), str) or not entry["artifact"]:
            failures.append(f"package {package} must name its artifact")
            ok = False
        if (
            isinstance(release_version, str)
            and release_version.strip()
            and entry.get("version") != release_version
        ):
            failures.append(f"package {package} version does not match release_version")
            ok = False
        if ok:
            pkg_passed += 1

    # --- Matrix reports (delegate to the candidate gate). ---
    matrix = report.get("matrix")
    matrix_passed = False
    if not isinstance(matrix, Mapping):
        failures.append("release record is missing the matrix section")
    else:
        try:
            from tools import qualify_release_candidate

            result = qualify_release_candidate.evaluate(matrix)
        except Exception as exc:  # pragma: no cover - import should succeed
            failures.append(f"matrix evaluation failed: {exc}")
            result = {"passed": False, "failures": [str(exc)]}
        if not result.get("passed"):
            for item in list(result.get("failures", []))[:5]:
                failures.append(f"matrix blocks the candidate: {item}")
            if len(result.get("failures", [])) > 5:
                failures.append(
                    f"matrix blocks the candidate: ... ({len(result['failures'])} total)"
                )
        else:
            matrix_passed = True

    # --- Failure traces (every family on every G cell). ---
    traces = report.get("failure_traces")
    if not isinstance(traces, Mapping):
        failures.append("release record is missing the failure_traces section")
        traces = {}
    try:
        from tools import qualify_release_candidate as _gate

        required_keys = _gate.required_fault_keys()
    except Exception:  # pragma: no cover
        required_keys = ()
    trace_passed = 0
    for key in required_keys:
        entry = traces.get(key)
        if not isinstance(entry, Mapping):
            failures.append(f"failure trace {key} blocks the candidate (missing)")
            continue
        ok = True
        if entry.get("status") != "pass":
            failures.append(f"failure trace {key} blocks the candidate (status={entry.get('status')!r})")
            ok = False
        if not isinstance(entry.get("trace"), str) or not entry["trace"].strip():
            failures.append(f"failure trace {key} must carry a trace reference")
            ok = False
        if not isinstance(entry.get("artifact"), str) or not entry["artifact"]:
            failures.append(f"failure trace {key} must name its artifact and hash")
            ok = False
        if entry.get("forbidden_backends_absent") is not True:
            failures.append(f"failure trace {key} must prove forbidden backends absent")
            ok = False
        if entry.get("side_effects_replayed") is not False:
            failures.append(f"failure trace {key} must prove side effects were not replayed")
            ok = False
        if ok:
            trace_passed += 1

    # --- Negative-backend proof. ---
    negative = report.get("negative_backend")
    if not isinstance(negative, Mapping):
        failures.append("release record is missing the negative_backend section")
        negative = {}
    neg_ok = 0
    for marker in PROHIBITED_X_MARKERS:
        if negative.get(marker) != "absent":
            failures.append(
                f"prohibited backend {marker} blocks the candidate (state={negative.get(marker)!r})"
            )
        else:
            neg_ok += 1
    for flag in (
        "validation_switch_absent",
        "fault_injection_disabled",
        "runtime_download_absent",
        "sandbox_bypass_absent",
        "clean_smoke_pass",
    ):
        if negative.get(flag) is not True:
            failures.append(f"negative_backend.{flag} must be true")
    if negative.get("target_scan") != "pass":
        failures.append("negative_backend.target_scan must be pass")

    passed = not failures
    return {
        "passed": passed,
        "failures": failures,
        "counts": {
            "packages_passed": pkg_passed,
            "packages_total": len(REQUIRED_PACKAGES),
            "matrix_passed": matrix_passed,
            "fault_traces_passed": trace_passed,
            "fault_traces_total": len(required_keys),
            "negative_absent": neg_ok,
            "negative_total": len(PROHIBITED_X_MARKERS),
        },
    }


def qualify(
    report: Mapping[str, Any], *, require_signatures: bool = False
) -> dict[str, Any]:
    """Evaluate and raise :class:`ReleaseBlocked` when the gate fails."""

    result = evaluate(report, require_signatures=require_signatures)
    if not result["passed"]:
        raise ReleaseBlocked(result["failures"])
    gate_report = {
        "schema_version": SCHEMA_VERSION,
        "passed": True,
        "counts": result["counts"],
        "record_sha256": record_digest(report),
        "atomic": "one failed section blocks the complete Windows/Linux set",
        "publish": "Windows and all released Linux artifacts are published or withheld together",
        "rollback": "withdraw/stop the complete desktop set; install the last known-good complete release",
    }
    return json.loads(json.dumps(gate_report))


def example_report(*, signed: bool = True) -> dict[str, Any]:
    """Build a passing template release record."""

    from tools import qualify_release_candidate

    release_version = "v1.2.3-atomic.1"
    lock = {
        "cef_version": LOCKED_CEF_VERSION,
        "chromium_version": LOCKED_CHROMIUM_VERSION,
        "cef_branch": LOCKED_CEF_BRANCH,
        "distribution": "standard",
        "archives": {
            "windows-x64": {
                "filename": LOCKED_ARCHIVES["windows-x64"],
                "url": f"https://cef-builds.spotifycdn.com/{LOCKED_ARCHIVES['windows-x64']}",
                "size": 359844028,
                "sha1": LOCKED_SIDEEAR_SHA1["windows-x64"],
                "sha256": "390d03b92f5d30d8c68fc7934c7d3e8fda916f52c9131d796da171caae549920",
                "raw_manifest_sha256": "79279882bf41a685a549b174afb09100cd26e2928df5e239ed92ca752a8d8e75",
            },
            "linux-x64": {
                "filename": LOCKED_ARCHIVES["linux-x64"],
                "url": f"https://cef-builds.spotifycdn.com/{LOCKED_ARCHIVES['linux-x64']}",
                "size": 674894043,
                "sha1": LOCKED_SIDEEAR_SHA1["linux-x64"],
                "sha256": "4967293a608424b98f2ff4ab15f4119064de966018df6458a80f2a7073dd1dc0",
                "raw_manifest_sha256": "fd82d90e1f0d6d632b8423499264c95e65a6a2eec623069faea51bc49b96612e",
            },
        },
        "policy": {"runtime_download": False, "sbom_format": "CycloneDX-1.5"},
    }
    artifact_names = {
        "windows-x64": "roscord-windows.zip",
        "debian-12": "roscord-debian-12-x64.deb",
        "ubuntu-22.04": "roscord-ubuntu-22.04-x64.deb",
        "ubuntu-24.04": "roscord-ubuntu-24.04-x64.deb",
        "portable": "roscord-linux-portable-x64.tar.gz",
        "flatpak": "chat.commet.commetapp.flatpak",
    }
    report: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "release_version": release_version,
        "cef_lock": lock,
        "manifests": {
            "windows-x64": {
                "raw_manifest_sha256": lock["archives"]["windows-x64"]["raw_manifest_sha256"],
                "staged_manifest_sha256": "6541f031fb79e9fda2eca9f6a2adc93b45ea344419d5a006257c30a4461c384e",
                "file_count": 20,
            },
            "linux-x64": {
                "raw_manifest_sha256": lock["archives"]["linux-x64"]["raw_manifest_sha256"],
                "staged_manifest_sha256": "9b299c7471a1e3b4e6360c182d7c9df5055c4f027319623ffae151176be182ac",
                "file_count": 15,
            },
        },
        "sandbox_bootstrap": {
            "windows_cef_host.exe_present": True,
            "windows_client.dll_present": True,
            "windows_chrome_elf.dll_present": True,
            "linux_libcef.so_present": True,
            "linux_chrome-sandbox_present": True,
            "bypass_flags_absent": True,
            "sandbox_info_forwarded": True,
        },
        "notices_sbom": {
            "notices_present": True,
            "sbom_format": "CycloneDX-1.5",
            "sbom_cef_version": LOCKED_CEF_VERSION,
            "provenance_bundled": True,
            "runtime_download": False,
        },
        "signatures": {
            package: {
                "signed": True,
                "algorithm": "release-key",
                "sha256": hashlib.sha256(package.encode()).hexdigest(),
            }
            for package in REQUIRED_PACKAGES
        },
        "packages": {
            package: {
                "artifact": artifact_names[package],
                "version": release_version,
                "status": "pass",
                "artifact_sha256": hashlib.sha256(
                    f"{package}:{release_version}".encode()
                ).hexdigest(),
                "evidence": "package-qualification",
            }
            for package in REQUIRED_PACKAGES
        },
        "matrix": qualify_release_candidate.example_report(),
        "failure_traces": {},
        "negative_backend": {marker: "absent" for marker in PROHIBITED_X_MARKERS},
    }
    from tools import qualify_release_candidate as _gate

    for key in _gate.required_fault_keys():
        family, _, cell = key.partition(":")
        report["failure_traces"][key] = {
            "status": "pass",
            "trace": f"{family}-trace-{cell}",
            "artifact": f"{cell}-artifact-sha256",
            "forbidden_backends_absent": True,
            "side_effects_replayed": False,
        }
    report["negative_backend"].update(
        {
            "validation_switch_absent": True,
            "fault_injection_disabled": True,
            "runtime_download_absent": True,
            "sandbox_bypass_absent": True,
            "clean_smoke_pass": True,
            "target_scan": "pass",
        }
    )
    if signed:
        report["signatures"]["record"] = {
            "signed": True,
            "algorithm": "release-key",
            "record_sha256": record_digest(report),
        }
    else:
        report["signatures"]["record"] = {"signed": False}
    return json.loads(json.dumps(report))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report", type=Path, help="path to a JSON release record")
    parser.add_argument("--output", type=Path, help="write the JSON gate report to a file")
    parser.add_argument("--example", action="store_true", help="emit a passing template record")
    parser.add_argument(
        "--require-signatures",
        action="store_true",
        help="require detached release-key signatures for every package and the record",
    )
    parser.add_argument(
        "--list-packages", action="store_true", help="list the atomic package set"
    )
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="prove the example passes and a single failed section blocks",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.example:
        sys.stdout.buffer.write(
            (json.dumps(example_report(), indent=2) + "\n").encode("utf-8")
        )
        return 0
    if args.list_packages:
        payload = {
            "required_packages": list(required_packages()),
            "locked_cef_version": LOCKED_CEF_VERSION,
            "locked_chromium_version": LOCKED_CHROMIUM_VERSION,
            "prohibited_markers": list(PROHIBITED_X_MARKERS),
        }
        sys.stdout.buffer.write((json.dumps(payload, indent=2) + "\n").encode("utf-8"))
        return 0
    if args.self_check:
        try:
            qualify(example_report(), require_signatures=True)
        except ReleaseBlocked as exc:
            print(f"release-record: self-check failed: {exc}", file=sys.stderr)
            return 2
        mutated = example_report()
        mutated["packages"]["flatpak"]["status"] = "fail"
        try:
            qualify(mutated, require_signatures=True)
        except ReleaseBlocked:
            print("release-record: self-check passed (single failure blocks)")
            return 0
        print("release-record: self-check failed: mutated record passed", file=sys.stderr)
        return 2
    if args.report is None:
        print(
            "release-record: error: --report, --example, --list-packages, or --self-check is required",
            file=sys.stderr,
        )
        return 2
    try:
        record = json.loads(args.report.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"release-record: error: {exc}", file=sys.stderr)
        return 2
    try:
        gate_report = qualify(record, require_signatures=args.require_signatures)
    except ReleaseBlocked as exc:
        for failure in exc.failures[:20]:
            print(f"release-record: blocked: {failure}", file=sys.stderr)
        if len(exc.failures) > 20:
            print(
                f"release-record: blocked: ... ({len(exc.failures)} total)", file=sys.stderr
            )
        return 1
    encoded = (json.dumps(gate_report, indent=2) + "\n").encode("utf-8")
    if args.output is not None:
        try:
            args.output.write_bytes(encoded)
        except OSError as exc:
            print(f"release-record: error: {exc}", file=sys.stderr)
            return 2
    sys.stdout.buffer.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
