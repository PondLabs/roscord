from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

from tools import rollback_release
from tools.rollback_release import RollbackBlocked


def _passing() -> dict:
    return rollback_release.example_plan()


class RollbackAtomicTests(unittest.TestCase):
    def test_atomic_artifact_set_covers_complete_desktop(self) -> None:
        self.assertEqual(
            list(rollback_release.required_artifacts()),
            [
                "windows-x64",
                "debian-12",
                "ubuntu-22.04",
                "ubuntu-24.04",
                "portable",
                "flatpak",
            ],
        )

    def test_example_plan_passes_the_gate(self) -> None:
        result = rollback_release.evaluate(_passing())
        self.assertTrue(result["passed"], result["failures"])
        self.assertEqual(result["counts"]["withdrawn"], 6)
        self.assertEqual(result["counts"]["installed"], 6)
        self.assertEqual(result["counts"]["engines_absent"], 5)

    def test_partial_withdrawal_blocks_rollback(self) -> None:
        for artifact in rollback_release.required_artifacts():
            with self.subTest(artifact=artifact):
                plan = _passing()
                plan["withdrawal"][artifact]["withdrawn"] = False
                result = rollback_release.evaluate(plan)
                self.assertFalse(result["passed"])
                self.assertTrue(any(artifact in f for f in result["failures"]))

    def test_partial_stop_blocks_rollback(self) -> None:
        plan = _passing()
        plan["withdrawal"]["flatpak"]["stopped"] = False
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_partial_install_blocks_rollback(self) -> None:
        plan = _passing()
        plan["install"]["portable"]["installed"] = False
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_install_must_match_last_known_good(self) -> None:
        plan = _passing()
        plan["install"]["windows-x64"]["version"] = "v9.9.9-other"
        result = rollback_release.evaluate(plan)
        self.assertFalse(result["passed"])

    def test_legacy_engine_revival_blocks_rollback(self) -> None:
        for marker in ("webview2", "webkitgtk-wry-runner", "system-cef"):
            with self.subTest(marker=marker):
                plan = _passing()
                plan["engines"][marker] = "present"
                result = rollback_release.evaluate(plan)
                self.assertFalse(result["passed"])
                self.assertTrue(any(marker in f for f in result["failures"]))


class RollbackProfileSafetyTests(unittest.TestCase):
    def test_shared_profile_root_blocks_rollback(self) -> None:
        plan = _passing()
        plan["profiles"]["legacy_root"] = plan["profiles"]["cef_root"]
        plan["profiles"]["separate"] = False
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_downgrade_migrator_blocks_rollback(self) -> None:
        plan = _passing()
        plan["profiles"]["downgrade_migrator"] = True
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_silent_deletion_blocks_rollback(self) -> None:
        plan = _passing()
        plan["profiles"]["silent_deletion"] = True
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_legacy_import_blocks_rollback(self) -> None:
        plan = _passing()
        plan["profiles"]["legacy_imported"] = True
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_quarantine_must_be_retained(self) -> None:
        plan = _passing()
        plan["profiles"]["quarantine_retained"] = False
        self.assertFalse(rollback_release.evaluate(plan)["passed"])

    def test_qualify_returns_atomic_report(self) -> None:
        gate = rollback_release.qualify(_passing())
        self.assertTrue(gate["passed"])
        self.assertIn("complete", gate["atomic"].lower())
        self.assertIn("last known-good", gate["install"].lower())
        with self.assertRaises(RollbackBlocked):
            failing = _passing()
            failing["withdrawal"]["windows-x64"]["withdrawn"] = False
            rollback_release.qualify(failing)


class RollbackCliTests(unittest.TestCase):
    def test_cli_self_check_proves_blocking(self) -> None:
        proc = subprocess.run(
            [sys.executable, "tools/rollback_release.py", "--self-check"],
            capture_output=True,
            text=True,
            cwd=str(Path(__file__).resolve().parents[1]),
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("single failure blocks", proc.stdout + proc.stderr)

    def test_cli_plan_round_trip(self) -> None:
        import tempfile

        root = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            plan_path = Path(temporary) / "rollback.json"
            plan_path.write_text(json.dumps(_passing()), encoding="utf-8")
            ok = subprocess.run(
                [sys.executable, "tools/rollback_release.py", "--plan", str(plan_path)],
                capture_output=True,
                text=True,
                cwd=str(root),
            )
            self.assertEqual(ok.returncode, 0, ok.stderr)
            failing = _passing()
            failing["install"]["debian-12"]["installed"] = False
            plan_path.write_text(json.dumps(failing), encoding="utf-8")
            blocked = subprocess.run(
                [sys.executable, "tools/rollback_release.py", "--plan", str(plan_path)],
                capture_output=True,
                text=True,
                cwd=str(root),
            )
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("debian-12", blocked.stderr)


if __name__ == "__main__":
    unittest.main()
