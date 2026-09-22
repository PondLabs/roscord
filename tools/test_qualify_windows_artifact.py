from __future__ import annotations

import hashlib
import io
import json
import shutil
import unittest
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory

from tools import cef_runtime
from tools import qualify_windows_artifact
from tools.qualify_windows_artifact import QualificationError
from tools.test_cef_runtime import _fixture_lock


def _payload_name(archive_name: str) -> str:
    return qualify_windows_artifact._lock_to_payload_name(archive_name)


def _build_qualified_fixture(directory: Path):
    """Stage, bundle, and metadata-generate a clean Windows fixture."""

    lock, archives = _fixture_lock(directory)
    staged = directory / "staged"
    project = directory / "project"
    project.mkdir()
    (project / "client.dll").write_bytes(b"client-dll-bytes")
    result = cef_runtime.stage_runtime(
        "windows-x64",
        archives["windows-x64"],
        staged,
        lock,
        project_root=project,
    )
    metadata = directory / "metadata"
    cef_runtime.generate_metadata(
        "windows-x64", staged, metadata, lock, project_root=project
    )
    bundle = directory / "bundle"
    payload = bundle / "cef_host"
    payload.mkdir(parents=True)
    for relative in result["files"]:
        if relative in ("LICENSE.txt", "CREDITS.html"):
            # Archive-root notice inputs ship as generated notices, mirroring
            # the CMake install layout.
            continue
        source = staged.joinpath(*PurePosixPath(relative).parts)
        target = payload.joinpath(*PurePosixPath(_payload_name(relative)).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    shutil.copyfile(project / "client.dll", payload / "client.dll")
    (payload / "fixtures").mkdir(exist_ok=True)
    (payload / "fixtures" / "fixture.html").write_bytes(b"<html>fixture</html>")
    (payload / "fixtures" / "README.md").write_bytes(b"fixture readme")
    (bundle / "commet.exe").write_bytes(b"app")
    (directory / "cef.lock.json").write_text(json.dumps(lock), encoding="utf-8")
    return lock, bundle, metadata


def _write_signatures(bundle: Path, metadata: Path) -> None:
    payload = qualify_windows_artifact.find_cef_payload(bundle)
    entries = {}
    for name, path in sorted(qualify_windows_artifact._payload_files(payload).items()):
        if name.lower().endswith((".exe", ".dll")):
            entries[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (metadata / "signatures.json").write_text(
        json.dumps({"version": 1, "algorithm": "release-key", "files": entries}),
        encoding="utf-8",
    )


class QualifyWindowsArtifactTests(unittest.TestCase):
    def test_qualifies_clean_nested_bundle(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            report = qualify_windows_artifact.qualify(bundle, metadata, lock)
            self.assertEqual(report["platform"], "windows-x64")
            self.assertEqual(report["cef_version"], lock["cef_version"])
            self.assertTrue(report["checks"]["staged"])
            self.assertTrue(report["checks"]["hashes"])
            self.assertTrue(report["checks"]["metadata"])
            self.assertTrue(report["checks"]["sandbox_bootstrap"])
            self.assertTrue(report["checks"]["no_foreign_backends"])
            self.assertTrue(report["checks"]["cpu_fallback"])
            self.assertGreater(report["file_count"], 10)

    def test_qualifies_flat_bundle_layout(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            # A bare payload directory (for example the output of
            # cef_runtime stage, smoke-tested directly) qualifies as flat.
            flat = directory / "flat"
            flat.mkdir()
            for entry in (bundle / "cef_host").iterdir():
                if entry.is_dir():
                    shutil.copytree(entry, flat / entry.name)
                else:
                    shutil.copyfile(entry, flat / entry.name)
            report = qualify_windows_artifact.qualify(flat, metadata, lock)
            self.assertTrue(report["checks"]["staged"])

    def test_missing_graphics_dependency_fails_staged(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "dxcompiler.dll").unlink()
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_missing_locale_fails_staged(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "Resources" / "locales" / "en-US.pak").unlink()
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_missing_project_bootstrap_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "client.dll").unlink()
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_tampered_payload_fails_hashes(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            target = bundle / "cef_host" / "libcef.dll"
            target.write_bytes(target.read_bytes() + b"tamper")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_unexpected_payload_file_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "unknown.dll").write_bytes(b"unexpected")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_debug_helper_is_forbidden(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "bootstrapc.exe").write_bytes(b"debug helper")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_symbols_are_forbidden(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "client.pdb").write_bytes(b"symbols")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_signatures_are_optional_unless_required(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            report = qualify_windows_artifact.qualify(bundle, metadata, lock)
            self.assertFalse(report["checks"]["signatures"]["signed"])
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(
                    bundle, metadata, lock, require_signatures=True
                )
            _write_signatures(bundle, metadata)
            report = qualify_windows_artifact.qualify(
                bundle, metadata, lock, require_signatures=True
            )
            self.assertTrue(report["checks"]["signatures"]["signed"])
            target = bundle / "cef_host" / "libcef.dll"
            target.write_bytes(target.read_bytes() + b"tamper")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(
                    bundle, metadata, lock, require_signatures=True
                )

    def test_incomplete_signatures_fail(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            _write_signatures(bundle, metadata)
            signatures = json.loads((metadata / "signatures.json").read_text(encoding="utf-8"))
            signatures["files"].pop("libcef.dll")
            (metadata / "signatures.json").write_text(json.dumps(signatures), encoding="utf-8")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(
                    bundle, metadata, lock, require_signatures=True
                )

    def test_foreign_backend_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "WebView2Loader.dll").write_bytes(b"foreign")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_shipped_cef_archive_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            filename = lock["platforms"]["windows-x64"]["archive"]["filename"]
            (bundle / filename).write_bytes(b"archive must not ship")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_missing_cpu_fallback_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "vk_swiftshader.dll").unlink()
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_sandbox_bypass_config_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "flags.json").write_text(
                '{"args": "--no-sandbox"}', encoding="utf-8"
            )
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_tampered_sbom_fails_metadata(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            sbom_path = metadata / "cef.sbom.cdx.json"
            sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
            sbom["specVersion"] = "1.4"
            sbom_path.write_text(json.dumps(sbom), encoding="utf-8")
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_missing_notices_fail_metadata(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata = _build_qualified_fixture(directory)
            (metadata / "THIRD_PARTY_NOTICES.txt").unlink()
            with self.assertRaises(QualificationError):
                qualify_windows_artifact.qualify(bundle, metadata, lock)

    def test_cli_reports_json(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, bundle, metadata = _build_qualified_fixture(directory)
            output = directory / "report.json"
            code = qualify_windows_artifact.main(
                [
                    "--lock",
                    str(directory / "cef.lock.json"),
                    "--bundle",
                    str(bundle),
                    "--metadata",
                    str(metadata),
                    "--output",
                    str(output),
                ]
            )
            self.assertEqual(code, 0)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertTrue(report["checks"]["cpu_fallback"])

    def test_cli_fails_closed_on_tampered_bundle(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, bundle, metadata = _build_qualified_fixture(directory)
            (bundle / "cef_host" / "libcef.dll").write_bytes(b"bad")
            code = qualify_windows_artifact.main(
                [
                    "--lock",
                    str(directory / "cef.lock.json"),
                    "--bundle",
                    str(bundle),
                    "--metadata",
                    str(metadata),
                ]
            )
            self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
