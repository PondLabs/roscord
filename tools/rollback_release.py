#!/usr/bin/env python3
"""Atomic rollback package for the CEF BrowserRuntime cutover.

This module is release tooling only: the application never imports it and it
never launches CEF.  It defines the rollback contract for epic #110 / ticket
#133: a rollback withdraws/stops the complete desktop set and installs the
last known-good complete application release.  A partial (Windows-only or
Linux-only) rollback, a legacy-engine revival, a downgrade migration, or a
silent profile deletion all fail closed.

Rollback keeps two profile roots separate:

- the CEF root (account-bound ``profile-<digest>`` directories with an
  owner-only manifest, created by the CEF contract), and
- the legacy root (untouched WebView2/WebKitGTK/Wry directories, never
  written by the new runtime).

A rolled-back old build never sees CEF state, the CEF release retains it for
a later forward release, and no downgrade migrator or automatic deletion
exists.  Corrupt profiles quarantine; recovery never deletes or resets.

Plan shape::

    {
      "schema_version": 1,
      "candidate_version": "v1.2.4-bad",
      "last_known_good_version": "v1.2.3-atomic.1",
      "withdrawal": {"windows-x64": {"withdrawn": true, "stopped": true}, ...},
      "install": {"windows-x64": {"version": ..., "artifact_sha256": ..., "installed": true}, ...},
      "engines": {"webview2": "absent", ...},
      "profiles": {"cef_root": ..., "legacy_root": ..., "separate": true, ...}
    }

Use ``--example`` to emit a passing template plan and ``--self-check`` to
prove the gate blocks a mutated plan (used by CI).

The implementation uses only the Python standard library.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping, Sequence


SCHEMA_VERSION = 1

#: The complete desktop set: rollback withdraws/stops and reinstalls all of
#: these together, never one platform alone.
REQUIRED_ARTIFACTS = (
    "windows-x64",
    "debian-12",
    "ubuntu-22.04",
    "ubuntu-24.04",
    "portable",
    "flatpak",
)

#: Engines that must never revive during a rollback.
PROHIBITED_ENGINES = (
    "webview2",
    "webkitgtk-wry-runner",
    "system-cef",
    "runtime-cef-download",
    "unowned-browser",
)


def required_artifacts() -> tuple[str, ...]:
    return REQUIRED_ARTIFACTS


def _is_hex(value: Any, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(c in "0123456789abcdefABCDEF" for c in value)
        and set(value.lower()) != {"0"}
    )


class RollbackBlocked(Exception):
    """Raised when a rollback plan violates the atomic rollback contract."""

    def __init__(self, failures: Sequence[str]) -> None:
        super().__init__("; ".join(failures))
        self.failures = list(failures)


def evaluate(plan: Mapping[str, Any]) -> dict[str, Any]:
    """Evaluate one rollback plan against the atomic rollback contract."""

    failures: list[str] = []
    if not isinstance(plan, Mapping):
        return {"passed": False, "failures": ["rollback plan must be an object"], "counts": {}}

    if plan.get("schema_version") != SCHEMA_VERSION:
        failures.append(
            f"schema_version must be {SCHEMA_VERSION} (got {plan.get('schema_version')!r})"
        )

    candidate = plan.get("candidate_version")
    if not isinstance(candidate, str) or not candidate.strip():
        failures.append("candidate_version must be a non-empty string")
    good = plan.get("last_known_good_version")
    if not isinstance(good, str) or not good.strip():
        failures.append("last_known_good_version must be a non-empty string")
    if (
        isinstance(candidate, str)
        and isinstance(good, str)
        and candidate.strip()
        and candidate == good
    ):
        failures.append("candidate_version and last_known_good_version must differ")

    # --- Withdrawal/stop covers the complete desktop set. ---
    withdrawal = plan.get("withdrawal")
    if not isinstance(withdrawal, Mapping):
        failures.append("rollback plan is missing the withdrawal section")
        withdrawal = {}
    withdrawn_ok = 0
    for artifact in REQUIRED_ARTIFACTS:
        entry = withdrawal.get(artifact)
        if not isinstance(entry, Mapping):
            failures.append(f"rollback withdraws {artifact} (missing entry) or blocks")
            continue
        if entry.get("withdrawn") is not True:
            failures.append(f"rollback must withdraw the complete set ({artifact} not withdrawn)")
        elif entry.get("stopped") is not True:
            failures.append(f"rollback must stop the complete set ({artifact} not stopped)")
        else:
            withdrawn_ok += 1

    # --- Install is the last known-good complete application. ---
    install = plan.get("install")
    if not isinstance(install, Mapping):
        failures.append("rollback plan is missing the install section")
        install = {}
    installed_ok = 0
    for artifact in REQUIRED_ARTIFACTS:
        entry = install.get(artifact)
        if not isinstance(entry, Mapping):
            failures.append(f"rollback installs {artifact} (missing entry) or blocks")
            continue
        ok = True
        if entry.get("installed") is not True:
            failures.append(f"rollback must install the last known-good {artifact}")
            ok = False
        if isinstance(good, str) and good.strip() and entry.get("version") != good:
            failures.append(
                f"rollback installs {artifact} from the last known-good release "
                f"(got {entry.get('version')!r})"
            )
            ok = False
        if not _is_hex(entry.get("artifact_sha256"), 64):
            failures.append(f"rollback install {artifact} artifact_sha256 must be a real digest")
            ok = False
        if not isinstance(entry.get("artifact"), str) or not entry["artifact"]:
            failures.append(f"rollback install {artifact} must name its artifact")
            ok = False
        if ok:
            installed_ok += 1

    # --- No legacy engine revival. ---
    engines = plan.get("engines")
    if not isinstance(engines, Mapping):
        failures.append("rollback plan is missing the engines section")
        engines = {}
    engines_ok = 0
    for marker in PROHIBITED_ENGINES:
        if engines.get(marker) != "absent":
            failures.append(
                f"rollback revives {marker} (state={engines.get(marker)!r}) and blocks"
            )
        else:
            engines_ok += 1

    # --- CEF and legacy profile roots stay separately rollback-safe. ---
    profiles = plan.get("profiles")
    if not isinstance(profiles, Mapping):
        failures.append("rollback plan is missing the profiles section")
        profiles = {}
    cef_root = profiles.get("cef_root")
    legacy_root = profiles.get("legacy_root")
    if not isinstance(cef_root, str) or not cef_root.strip():
        failures.append("profiles.cef_root must be a non-empty path")
    if not isinstance(legacy_root, str) or not legacy_root.strip():
        failures.append("profiles.legacy_root must be a non-empty path")
    if (
        isinstance(cef_root, str)
        and isinstance(legacy_root, str)
        and cef_root.strip()
        and cef_root == legacy_root
    ):
        failures.append("profiles.cef_root and profiles.legacy_root must be separate roots")
    if profiles.get("separate") is not True:
        failures.append("profiles.separate must be true")
    if profiles.get("downgrade_migrator") not in (False, None, "absent"):
        failures.append("profiles must have no downgrade migrator")
    if profiles.get("silent_deletion") not in (False, None, "absent"):
        failures.append("profiles must have no silent deletion")
    if profiles.get("quarantine_retained") is not True:
        failures.append("profiles.quarantine_retained must be true")
    if profiles.get("legacy_imported") not in (False, None, "absent"):
        failures.append("profiles must never import legacy browser data")

    passed = not failures
    return {
        "passed": passed,
        "failures": failures,
        "counts": {
            "withdrawn": withdrawn_ok,
            "withdrawn_total": len(REQUIRED_ARTIFACTS),
            "installed": installed_ok,
            "installed_total": len(REQUIRED_ARTIFACTS),
            "engines_absent": engines_ok,
            "engines_total": len(PROHIBITED_ENGINES),
        },
    }


def qualify(plan: Mapping[str, Any]) -> dict[str, Any]:
    """Evaluate and raise :class:`RollbackBlocked` when the plan fails."""

    result = evaluate(plan)
    if not result["passed"]:
        raise RollbackBlocked(result["failures"])
    gate_report = {
        "schema_version": SCHEMA_VERSION,
        "passed": True,
        "counts": result["counts"],
        "atomic": "rollback withdraws/stops the complete desktop set together",
        "install": "rollback installs the last known-good complete application release",
        "engines": "no legacy engine revival during recovery",
        "profiles": "CEF and legacy roots stay separate; no downgrade migration or silent deletion",
    }
    return json.loads(json.dumps(gate_report))


def example_plan() -> dict[str, Any]:
    """Build a passing template rollback plan."""

    import hashlib

    good = "v1.2.3-atomic.1"
    bad = "v1.2.4-bad"
    artifact_names = {
        "windows-x64": "roscord-windows.zip",
        "debian-12": "roscord-debian-12-x64.deb",
        "ubuntu-22.04": "roscord-ubuntu-22.04-x64.deb",
        "ubuntu-24.04": "roscord-ubuntu-24.04-x64.deb",
        "portable": "roscord-linux-portable-x64.tar.gz",
        "flatpak": "chat.commet.commetapp.flatpak",
    }
    plan: dict[str, Any] = {
        "schema_version": SCHEMA_VERSION,
        "candidate_version": bad,
        "last_known_good_version": good,
        "withdrawal": {
            artifact: {"withdrawn": True, "stopped": True} for artifact in REQUIRED_ARTIFACTS
        },
        "install": {
            artifact: {
                "artifact": artifact_names[artifact],
                "version": good,
                "artifact_sha256": hashlib.sha256(f"{artifact}:{good}".encode()).hexdigest(),
                "installed": True,
                "evidence": "last-known-good-qualification",
            }
            for artifact in REQUIRED_ARTIFACTS
        },
        "engines": {marker: "absent" for marker in PROHIBITED_ENGINES},
        "profiles": {
            "cef_root": "app-data/cef-profiles",
            "legacy_root": "app-data/legacy-webview",
            "separate": True,
            "downgrade_migrator": False,
            "silent_deletion": False,
            "quarantine_retained": True,
            "legacy_imported": False,
        },
    }
    return json.loads(json.dumps(plan))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, help="path to a JSON rollback plan")
    parser.add_argument("--output", type=Path, help="write the JSON gate report to a file")
    parser.add_argument("--example", action="store_true", help="emit a passing template plan")
    parser.add_argument(
        "--list-artifacts", action="store_true", help="list the atomic artifact set"
    )
    parser.add_argument(
        "--self-check",
        action="store_true",
        help="prove the example passes and a single failed entry blocks",
    )
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.example:
        sys.stdout.buffer.write((json.dumps(example_plan(), indent=2) + "\n").encode("utf-8"))
        return 0
    if args.list_artifacts:
        payload = {
            "required_artifacts": list(required_artifacts()),
            "prohibited_engines": list(PROHIBITED_ENGINES),
        }
        sys.stdout.buffer.write((json.dumps(payload, indent=2) + "\n").encode("utf-8"))
        return 0
    if args.self_check:
        try:
            qualify(example_plan())
        except RollbackBlocked as exc:
            print(f"rollback-release: self-check failed: {exc}", file=sys.stderr)
            return 2
        mutated = example_plan()
        mutated["withdrawal"]["windows-x64"]["withdrawn"] = False
        try:
            qualify(mutated)
        except RollbackBlocked:
            print("rollback-release: self-check passed (single failure blocks)")
            return 0
        print("rollback-release: self-check failed: mutated plan passed", file=sys.stderr)
        return 2
    if args.plan is None:
        print(
            "rollback-release: error: --plan, --example, --list-artifacts, or --self-check is required",
            file=sys.stderr,
        )
        return 2
    try:
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        print(f"rollback-release: error: {exc}", file=sys.stderr)
        return 2
    try:
        gate_report = qualify(plan)
    except RollbackBlocked as exc:
        for failure in exc.failures[:20]:
            print(f"rollback-release: blocked: {failure}", file=sys.stderr)
        if len(exc.failures) > 20:
            print(f"rollback-release: blocked: ... ({len(exc.failures)} total)", file=sys.stderr)
        return 1
    encoded = (json.dumps(gate_report, indent=2) + "\n").encode("utf-8")
    if args.output is not None:
        try:
            args.output.write_bytes(encoded)
        except OSError as exc:
            print(f"rollback-release: error: {exc}", file=sys.stderr)
            return 2
    sys.stdout.buffer.write(encoded)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
