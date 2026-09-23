from __future__ import annotations

import json
import subprocess
import sys
import unittest
from pathlib import Path

from tools import qualify_release_candidate
from tools.qualify_release_candidate import CandidateBlocked


def _passing() -> dict:
    return qualify_release_candidate.example_report()


class ReleaseMatrixTests(unittest.TestCase):
    def test_mandatory_g_cells_cover_all_platforms_and_presentations(self) -> None:
        cells = qualify_release_candidate.mandatory_g_cells()
        self.assertEqual(len(cells), 23)
        for expected in (
            "windows-x64/matrix/embedded",
            "windows-x64/matrix/standalone",
            "windows-x64/official-video/embedded",
        ):
            self.assertIn(expected, cells)
        native = qualify_release_candidate.native_g_cells()
        self.assertEqual(len(native), 16)
        for package in qualify_release_candidate.NATIVE_PACKAGES:
            for compositor in qualify_release_candidate.COMPOSITORS:
                for presentation in qualify_release_candidate.PRESENTATIONS:
                    self.assertIn(f"native-{package}/{compositor}/matrix/{presentation}", native)
        flatpak = qualify_release_candidate.flatpak_g_cells()
        self.assertEqual(len(flatpak), 4)
        for compositor in qualify_release_candidate.COMPOSITORS:
            for presentation in qualify_release_candidate.PRESENTATIONS:
                self.assertIn(f"flatpak/{compositor}/matrix/{presentation}", flatpak)

    def test_preserved_p_flows_cover_linux_video_and_external(self) -> None:
        cells = qualify_release_candidate.preserved_p_cells()
        self.assertEqual(len(cells), 11)
        for package in qualify_release_candidate.NATIVE_PACKAGES:
            for compositor in qualify_release_candidate.COMPOSITORS:
                self.assertIn(f"native-{package}/{compositor}/official-video/preserved", cells)
        for expected in qualify_release_candidate.EXTERNAL_P_CELLS:
            self.assertIn(expected, cells)

    def test_na_boundaries_cover_official_video_standalone(self) -> None:
        cells = qualify_release_candidate.na_cells()
        self.assertEqual(len(cells), 5)
        for column in qualify_release_candidate.NA_COLUMNS:
            self.assertIn(f"{column}/official-video/standalone", cells)

    def test_prohibited_x_backends_are_all_listed(self) -> None:
        markers = qualify_release_candidate.prohibited_x_markers()
        for expected in ("webview2", "webkitgtk-wry-runner", "system-cef", "runtime-cef-download", "unowned-browser"):
            self.assertIn(expected, markers)

    def test_example_matrix_passes_the_gate(self) -> None:
        result = qualify_release_candidate.evaluate(_passing())
        self.assertTrue(result["passed"], result["failures"])
        self.assertEqual(result["counts"]["mandatory_cells_passed"], 23)
        self.assertEqual(result["counts"]["preserved_flows_passed"], 11)
        self.assertEqual(result["counts"]["na_boundaries_ok"], 5)
        self.assertEqual(result["counts"]["prohibited_absent"], 5)


class ReleaseFaultCoverageTests(unittest.TestCase):
    def test_all_ten_fault_families_are_required(self) -> None:
        self.assertEqual(
            list(qualify_release_candidate.FAULT_FAMILIES),
            ["host", "renderer", "gpu", "utility", "heartbeat", "bundle", "protocol", "sandbox", "profile-lock", "retry-budget"],
        )

    def test_fault_keys_cover_every_family_on_every_g_cell(self) -> None:
        keys = qualify_release_candidate.required_fault_keys()
        self.assertEqual(len(keys), 10 * 23)
        for family in qualify_release_candidate.FAULT_FAMILIES:
            for cell in qualify_release_candidate.mandatory_g_cells():
                self.assertIn(f"{family}:{cell}", keys)

    def test_example_fault_evidence_passes(self) -> None:
        result = qualify_release_candidate.evaluate(_passing())
        self.assertEqual(result["counts"]["faults_passed"], 230)

    def test_single_fault_failure_blocks_the_candidate(self) -> None:
        for key in (
            "host:windows-x64/matrix/embedded",
            "renderer:native-debian-12/x11/matrix/embedded",
            "gpu:flatpak/wayland/matrix/standalone",
            "heartbeat:windows-x64/matrix/standalone",
            "bundle:native-portable/wayland/matrix/standalone",
            "protocol:flatpak/x11/matrix/embedded",
            "sandbox:windows-x64/official-video/embedded",
            "profile-lock:native-ubuntu-22.04/wayland/matrix/embedded",
            "retry-budget:flatpak/wayland/matrix/embedded",
            "utility:native-ubuntu-24.04/x11/matrix/standalone",
        ):
            with self.subTest(key=key):
                report = _passing()
                report["faults"][key]["status"] = "fail"
                result = qualify_release_candidate.evaluate(report)
                self.assertFalse(result["passed"])
                self.assertTrue(any(key.split(":")[0] in f for f in result["failures"]))

    def test_missing_fault_evidence_blocks_the_candidate(self) -> None:
        report = _passing()
        del report["faults"]["sandbox:windows-x64/matrix/embedded"]
        result = qualify_release_candidate.evaluate(report)
        self.assertFalse(result["passed"])


class ReleasePerformanceTests(unittest.TestCase):
    def test_thresholds_match_the_behavior_contract(self) -> None:
        thresholds = qualify_release_candidate.performance_thresholds()
        self.assertEqual(thresholds["host_ready_s_cold_max"], 5.0)
        self.assertEqual(thresholds["first_paint_s_after_open_max"], 3.0)
        self.assertEqual(thresholds["surface_close_s_max"], 2.0)
        self.assertEqual(thresholds["cpu_osr_fps_min"], 30.0)
        self.assertEqual(thresholds["cpu_osr_soak_s"], 60.0)
        self.assertEqual(thresholds["input_to_present_p95_ms_max"], 100.0)
        self.assertEqual(thresholds["soak_minutes"], 30.0)
        self.assertEqual(thresholds["soak_rss_growth_pct_max"], 15.0)
        self.assertEqual(thresholds["orphan_processes_max"], 0.0)

    def test_example_perf_passes(self) -> None:
        result = qualify_release_candidate.evaluate(_passing())
        self.assertEqual(result["counts"]["perf_violations"], 0)

    def test_each_perf_violation_blocks_the_candidate(self) -> None:
        mutations = {
            "host_ready_s_cold": 5.1,
            "first_paint_s_after_open": 3.5,
            "surface_close_s": 2.5,
            "cpu_osr_fps": 29.0,
            "cpu_osr_soak_s": 59.0,
            "input_to_present_p95_ms": 101.0,
            "soak_rss_growth_pct": 16.0,
            "orphan_processes": 1,
        }
        for metric, bad in mutations.items():
            with self.subTest(metric=metric):
                report = _passing()
                report["perf"][metric] = bad
                result = qualify_release_candidate.evaluate(report)
                self.assertFalse(result["passed"])
                self.assertTrue(any(metric in f for f in result["failures"]))

    def test_wrong_soak_duration_blocks_the_candidate(self) -> None:
        report = _passing()
        report["perf"]["soak_minutes"] = 10.0
        self.assertFalse(qualify_release_candidate.evaluate(report)["passed"])


class ReleaseManualEvidenceTests(unittest.TestCase):
    def test_all_seven_manual_topics_are_required(self) -> None:
        self.assertEqual(
            list(qualify_release_candidate.manual_topics()),
            ["permissions", "ime", "accessibility", "cpu-fallback", "official-video", "recovery", "rollback"],
        )

    def test_example_manual_evidence_passes(self) -> None:
        result = qualify_release_candidate.evaluate(_passing())
        self.assertEqual(result["counts"]["manual_covered"], 7)

    def test_each_missing_manual_topic_blocks_the_candidate(self) -> None:
        for topic in qualify_release_candidate.manual_topics():
            with self.subTest(topic=topic):
                report = _passing()
                report["manual"][topic]["covered"] = False
                result = qualify_release_candidate.evaluate(report)
                self.assertFalse(result["passed"])
                self.assertTrue(any(topic in f for f in result["failures"]))

    def test_empty_manual_evidence_blocks_the_candidate(self) -> None:
        report = _passing()
        report["manual"]["ime"]["evidence"] = "  "
        self.assertFalse(qualify_release_candidate.evaluate(report)["passed"])


class ReleaseAtomicGateTests(unittest.TestCase):
    def test_single_failed_mandatory_cell_blocks_the_candidate(self) -> None:
        for cell in (
            "windows-x64/matrix/embedded",
            "native-debian-12/x11/matrix/embedded",
            "native-portable/wayland/matrix/standalone",
            "flatpak/x11/matrix/embedded",
            "flatpak/wayland/matrix/standalone",
            "windows-x64/official-video/embedded",
        ):
            with self.subTest(cell=cell):
                report = _passing()
                report["cells"][cell]["status"] = "fail"
                result = qualify_release_candidate.evaluate(report)
                self.assertFalse(result["passed"])
                self.assertTrue(any(cell in f for f in result["failures"]))

    def test_preserved_flow_failure_blocks_the_candidate(self) -> None:
        report = _passing()
        cell = "native-debian-12/x11/official-video/preserved"
        report["cells"][cell]["status"] = "fail"
        self.assertFalse(qualify_release_candidate.evaluate(report)["passed"])

    def test_na_boundary_violation_blocks_the_candidate(self) -> None:
        report = _passing()
        cell = "windows-x64/official-video/standalone"
        report["cells"][cell] = {"kind": "G", "status": "pass", "backend": "cef-osr-cpu"}
        self.assertFalse(qualify_release_candidate.evaluate(report)["passed"])

    def test_present_prohibited_backend_blocks_the_candidate(self) -> None:
        report = _passing()
        report["forbidden"]["webview2"] = "present"
        result = qualify_release_candidate.evaluate(report)
        self.assertFalse(result["passed"])
        self.assertTrue(any("webview2" in f for f in result["failures"]))

    def test_qualify_raises_and_returns_atomic_report(self) -> None:
        gate = qualify_release_candidate.qualify(_passing())
        self.assertTrue(gate["passed"])
        self.assertIn("one failed mandatory cell", gate["atomic"].lower())
        self.assertIn("complete", gate["rollback"].lower())
        with self.assertRaises(CandidateBlocked):
            failing = _passing()
            failing["cells"]["flatpak/wayland/matrix/embedded"]["status"] = "fail"
            qualify_release_candidate.qualify(failing)


class ReleaseCliTests(unittest.TestCase):
    def test_cli_self_check_proves_blocking(self) -> None:
        proc = subprocess.run(
            [sys.executable, "tools/qualify_release_candidate.py", "--self-check"],
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
            record = Path(temporary) / "candidate.json"
            record.write_text(json.dumps(_passing()), encoding="utf-8")
            ok = subprocess.run(
                [sys.executable, "tools/qualify_release_candidate.py", "--report", str(record)],
                capture_output=True,
                text=True,
                cwd=str(root),
            )
            self.assertEqual(ok.returncode, 0, ok.stderr)
            failing = _passing()
            failing["cells"]["windows-x64/matrix/embedded"]["status"] = "fail"
            record.write_text(json.dumps(failing), encoding="utf-8")
            blocked = subprocess.run(
                [sys.executable, "tools/qualify_release_candidate.py", "--report", str(record)],
                capture_output=True,
                text=True,
                cwd=str(root),
            )
            self.assertNotEqual(blocked.returncode, 0)
            self.assertIn("blocks the candidate", blocked.stderr)


if __name__ == "__main__":
    unittest.main()
