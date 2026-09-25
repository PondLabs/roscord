from __future__ import annotations

import hashlib
import json
import shutil
import unittest
from pathlib import Path, PurePosixPath
from tempfile import TemporaryDirectory

from tools import cef_runtime
from tools import qualify_flatpak_artifact
from tools.qualify_flatpak_artifact import QualificationError
from tools.test_cef_runtime import _fixture_lock


def _payload_name(archive_name: str) -> str:
    return qualify_flatpak_artifact._lock_to_payload_name(archive_name)


def _write_manifest(directory: Path) -> Path:
    source = qualify_flatpak_artifact.DEFAULT_MANIFEST
    target = directory / "chat.commet.commetapp.yaml"
    shutil.copyfile(source, target)
    return target


def _build_qualified_fixture(directory: Path):
    """Stage, bundle, and metadata-generate a clean Flatpak fixture."""

    lock, archives = _fixture_lock(directory)
    staged = directory / "staged"
    result = cef_runtime.stage_runtime(
        "linux-x64",
        archives["linux-x64"],
        staged,
        lock,
    )
    metadata = directory / "metadata"
    cef_runtime.generate_metadata("linux-x64", staged, metadata, lock)
    bundle = directory / "bundle"
    payload = bundle / "cef"
    payload.mkdir(parents=True)
    for relative in result["files"]:
        if relative in ("LICENSE.txt", "CREDITS.html"):
            # Archive-root notice inputs ship as generated notices, mirroring
            # the Flatpak /app install layout.
            continue
        source = staged.joinpath(
            *PurePosixPath(cef_runtime.staged_path("linux-x64", relative)).parts
        )
        target = payload.joinpath(*PurePosixPath(_payload_name(relative)).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
    (payload / "fixtures").mkdir(exist_ok=True)
    (payload / "fixtures" / "fixture.html").write_bytes(b"<html>fixture</html>")
    (payload / "fixtures" / "README.md").write_bytes(b"fixture readme")
    app_bundle = bundle / "commet" / "bundle"
    app_bundle.mkdir(parents=True)
    (app_bundle / "commet").write_bytes(b"app")
    manifest = _write_manifest(directory)
    (directory / "cef.lock.json").write_text(json.dumps(lock), encoding="utf-8")
    return lock, bundle, metadata, manifest


def _write_signatures(bundle: Path, metadata: Path) -> None:
    payload = qualify_flatpak_artifact.find_cef_payload(bundle)
    entries = {}
    for name, path in sorted(
        qualify_flatpak_artifact._payload_native_binaries(payload).items()
    ):
        entries[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    (metadata / "signatures.json").write_text(
        json.dumps({"version": 1, "algorithm": "release-key", "files": entries}),
        encoding="utf-8",
    )


class QualifyFlatpakArtifactTests(unittest.TestCase):
    def test_qualifies_clean_flatpak_files_root(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            report = qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)
            self.assertEqual(report["platform"], "linux-x64")
            self.assertEqual(report["cef_version"], lock["cef_version"])
            self.assertTrue(report["checks"]["staged"])
            self.assertTrue(report["checks"]["hashes"])
            self.assertTrue(report["checks"]["metadata"])
            self.assertTrue(report["checks"]["manifest"])
            self.assertTrue(report["checks"]["sandbox_helpers"])
            self.assertTrue(report["checks"]["no_foreign_backends"])
            self.assertTrue(report["checks"]["cpu_fallback"])
            self.assertGreater(report["file_count"], 8)

    def test_missing_helper_fails_staged(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "libcef.so").unlink()
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_missing_sandbox_helper_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "chrome-sandbox").unlink()
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_missing_locale_fails_staged(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "locales" / "en-US.pak").unlink()
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_tampered_payload_fails_hashes(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            target = bundle / "cef" / "libcef.so"
            target.write_bytes(target.read_bytes() + b"tamper")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_unexpected_payload_file_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "unknown.so").write_bytes(b"unexpected")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_windows_binary_is_forbidden(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "libcef.dll").write_bytes(b"foreign")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_symbols_are_forbidden(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "libcef.pdb").write_bytes(b"symbols")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_signatures_are_optional_unless_required(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            report = qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)
            self.assertFalse(report["checks"]["signatures"]["signed"])
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(
                    bundle, metadata, lock, manifest, require_signatures=True
                )
            _write_signatures(bundle, metadata)
            report = qualify_flatpak_artifact.qualify(
                bundle, metadata, lock, manifest, require_signatures=True
            )
            self.assertTrue(report["checks"]["signatures"]["signed"])
            target = bundle / "cef" / "libcef.so"
            target.write_bytes(target.read_bytes() + b"tamper")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(
                    bundle, metadata, lock, manifest, require_signatures=True
                )

    def test_incomplete_signatures_fail(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            _write_signatures(bundle, metadata)
            signatures = json.loads((metadata / "signatures.json").read_text(encoding="utf-8"))
            signatures["files"].pop("libcef.so")
            (metadata / "signatures.json").write_text(json.dumps(signatures), encoding="utf-8")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(
                    bundle, metadata, lock, manifest, require_signatures=True
                )

    def test_foreign_backend_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "libwebkitgtk.so").write_bytes(b"foreign")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_shipped_cef_archive_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            filename = lock["platforms"]["linux-x64"]["archive"]["filename"]
            (bundle / filename).write_bytes(b"archive must not ship")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_missing_cpu_fallback_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "libvk_swiftshader.so").unlink()
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_sandbox_bypass_config_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "flags.json").write_text(
                '{"args": "--no-sandbox"}', encoding="utf-8"
            )
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_broadened_manifest_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            text = manifest.read_text(encoding="utf-8")
            manifest.write_text(text + '\n- "--device=all"\n', encoding="utf-8")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_missing_finish_arg_fails(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            text = manifest.read_text(encoding="utf-8")
            manifest.write_text(
                text.replace("--device=dri", "--device=shm"), encoding="utf-8"
            )
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_tampered_sbom_fails_metadata(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            sbom_path = metadata / "cef.sbom.cdx.json"
            sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
            sbom["specVersion"] = "1.4"
            sbom_path.write_text(json.dumps(sbom), encoding="utf-8")
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_missing_notices_fail_metadata(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (metadata / "THIRD_PARTY_NOTICES.txt").unlink()
            with self.assertRaises(QualificationError):
                qualify_flatpak_artifact.qualify(bundle, metadata, lock, manifest)

    def test_cli_reports_json(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            _, bundle, metadata, manifest = _build_qualified_fixture(directory)
            output = directory / "report.json"
            code = qualify_flatpak_artifact.main(
                [
                    "--lock",
                    str(directory / "cef.lock.json"),
                    "--bundle",
                    str(bundle),
                    "--metadata",
                    str(metadata),
                    "--manifest",
                    str(manifest),
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
            _, bundle, metadata, manifest = _build_qualified_fixture(directory)
            (bundle / "cef" / "libcef.so").write_bytes(b"bad")
            code = qualify_flatpak_artifact.main(
                [
                    "--lock",
                    str(directory / "cef.lock.json"),
                    "--bundle",
                    str(bundle),
                    "--metadata",
                    str(metadata),
                    "--manifest",
                    str(manifest),
                ]
            )
            self.assertEqual(code, 2)


if __name__ == "__main__":
    unittest.main()
