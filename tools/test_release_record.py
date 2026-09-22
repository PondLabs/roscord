from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

from tools import release_record
from tools.release_record import ReleaseBlocked


def _passing(*, signed: bool = True) -> dict:
    return release_record.example_report(signed=signed)


class ReleaseRecordLockTests(unittest.TestCase):
    def test_atomic_package_set_covers_windows_and_all_linux(self) -> None:
        self.assertEqual(
            list(release_record.required_packages()),
            [
                "windows-x64",
                "debian-12",
                "ubuntu-22.04",
                "ubuntu-24.04",
                "portable",
                "flatpak",
            ],
        )

    def test_example_record_passes_the_gate(self) -> None:
        result = release_record.evaluate(_passing(), require_signatures=True)
        self.assertTrue(result["passed"], result["failures"])
        self.assertEqual(result["counts"]["packages_passed"], 6)
        self.assertTrue(result["counts"]["matrix_passed"])
        self.assertEqual(
            result["counts"]["fault_traces_passed"], result["counts"]["fault_traces_total"]
        )
        self.assertGreater(result["counts"]["fault_traces_total"], 0)

    def test_lock_mismatch_blocks_the_candidate(self) -> None:
        report = _passing()
        report["cef_lock"]["cef_version"] = "999.0.0+bad"
        result = release_record.evaluate(report)
        self.assertFalse(result["passed"])
        self.assertTrue(any("cef_version" in f for f in result["failures"]))

    def test_manifest_digest_mismatch_blocks_the_candidate(self) -> None:
        report = _passing()
        report["manifests"]["windows-x64"]["raw_manifest_sha256"] = "a" * 64
        result = release_record.evaluate(report)
        self.assertFalse(result["passed"])

    def test_sandbox_bootstrap_gap_blocks_the_candidate(self) -> None:
        report = _passing()
        report["sandbox_bootstrap"]["windows_cef_host.exe_present"] = False
        self.assertFalse(release_record.evaluate(report)["passed"])

    def test_notices_sbom_gap_blocks_the_candidate(self) -> None:
        report = _passing()
        report["notices_sbom"]["sbom_format"] = "SPDX"
        self.assertFalse(release_record.evaluate(report)["passed"])


class ReleaseRecordAtomicTests(unittest.TestCase):
    def test_single_failed_package_blocks_the_candidate(self) -> None:
        for package in release_record.required_packages():
            with self.subTest(package=package):
                report = _passing()
                report["packages"][package]["status"] = "fail"
                result = release_record.evaluate(report)
                self.assertFalse(result["passed"])
                self.assertTrue(any(package in f for f in result["failures"]))

    def test_package_version_mismatch_blocks_the_candidate(self) -> None:
        report = _passing()
        report["packages"]["flatpak"]["version"] = "v9.9.9-other"
        self.assertFalse(release_record.evaluate(report)["passed"])

    def test_matrix_failure_blocks_the_candidate(self) -> None:
        report = _passing()
        report["matrix"]["cells"]["windows-x64/matrix/embedded"]["status"] = "fail"
        result = release_record.evaluate(report)
        self.assertFalse(result["passed"])
        self.assertTrue(any("matrix" in f for f in result["failures"]))

    def test_failure_trace_gap_blocks_the_candidate(self) -> None:
        from tools import qualify_release_candidate

        report = _passing()
        key = qualify_release_candidate.required_fault_keys()[0]
        del report["failure_traces"][key]
        self.assertFalse(release_record.evaluate(report)["passed"])

    def test_failure_trace_replay_blocks_the_candidate(self) -> None:
        from tools import qualify_release_candidate

        report = _passing()
        key = qualify_release_candidate.required_fault_keys()[0]
        report["failure_traces"][key]["side_effects_replayed"] = True
        result = release_record.evaluate(report)
        self.assertFalse(result["passed"])

    def test_prohibited_backend_blocks_the_candidate(self) -> None:
        report = _passing()
        report["negative_backend"]["webview2"] = "present"
        result = release_record.evaluate(report)
        self.assertFalse(result["passed"])
        self.assertTrue(any("webview2" in f for f in result["failures"]))

    def test_validation_switch_blocks_the_candidate(self) -> None:
        report = _passing()
        report["negative_backend"]["validation_switch_absent"] = False
        self.assertFalse(release_record.evaluate(report)["passed"])

    def test_missing_signatures_block_when_required(self) -> None:
        report = _passing(signed=False)
        result = release_record.evaluate(report, require_signatures=True)
        self.assertFalse(result["passed"])
        # Without the requirement, signatures are advisory.
        advisory = release_record.evaluate(report, require_signatures=False)
        self.assertTrue(advisory["passed"], advisory["failures"])

    def test_qualify_returns_signed_gate_report(self) -> None:
        gate = release_record.qualify(_passing(), require_signatures=True)
        self.assertTrue(gate["passed"])
        self.assertIn("together", gate["publish"].lower())
        self.assertIn("complete", gate["rollback"].lower())
        self.assertEqual(gate["record_sha256"], release_record.record_digest(_passing()))
        with self.assertRaises(ReleaseBlocked):
            failing = _passing()
            failing["packages"]["windows-x64"]["status"] = "fail"
            release_record.qualify(failing)


class ReleaseRecordCliTests(unittest.TestCase):
    def test_cli_self_check_proves_blocking(self) -> None:
        proc = subprocess.run(
            [sys.executable, "tools/release_record.py", "--self-check"],
            capture_output=True,
            text=True,
            cwd=str(Path(__file__).resolve().parents[1]),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("single failure blocks", proc.stdout + proc.stderr)

    def test_cli_report_round_trip(self) -> None:
        import tempfile

        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            record = Path(temporary) / "release.json"
            record.write_text(json.dumps(_passing()), encoding="utf-8")
            ok = subprocess.run(
                [sys.executable, "tools/release_record.py", "--report", str(record)],
                capture_output=True,
                text=True,
                cwd=str(root),
            )
            self.assertEqual(ok.returncode, 0, ok.stderr)
            failing = _passing()
            failing["packages"]["portable"]["status"] = "fail"
            record.write_text(json.dumps(failing), encoding="utf-8")
            blocked = subprocess.run(
                [sys.executable, "tools/release_record.py", "--report", str(record)],
                capture_output=True,
                text=True,
                cwd=str(root),
            )
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("blocks the candidate", blocked.stderr)


if __name__ == "__main__":
    unittest.main()
