from __future__ import annotations

import copy
import hashlib
import http.server
import io
import json
import socketserver
import tarfile
import threading
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

from tools import cef_runtime


WINDOWS_FILES = {
    "Release/bootstrap.exe": b"bootstrap",
    "Release/bootstrapc.exe": b"debug helper",
    "Release/chrome_elf.dll": b"chrome elf",
    "Release/d3dcompiler_47.dll": b"d3d",
    "Release/dxcompiler.dll": b"dx",
    "Release/dxil.dll": b"dxil",
    "Release/libEGL.dll": b"egl",
    "Release/libGLESv2.dll": b"gles",
    "Release/libcef.dll": b"cef",
    "Release/v8_context_snapshot.bin": b"snapshot",
    "Release/vk_swiftshader.dll": b"swiftshader",
    "Release/vk_swiftshader_icd.json": b"{}",
    "Release/vulkan-1.dll": b"vulkan",
    "Resources/chrome_100_percent.pak": b"100",
    "Resources/chrome_200_percent.pak": b"200",
    "Resources/icudtl.dat": b"icu",
    "Resources/resources.pak": b"resources",
    "Resources/locales/en-US.pak": b"locale",
    "LICENSE.txt": b"BSD license\n",
    "CREDITS.html": b"<html>credits</html>\n",
    "include/not-staged.h": b"not staged",
}

LINUX_FILES = {
    "Release/chrome-sandbox": b"sandbox",
    "Release/libEGL.so": b"egl",
    "Release/libGLESv2.so": b"gles",
    "Release/libcef.so": b"cef",
    "Release/libvk_swiftshader.so": b"swiftshader",
    "Release/libvulkan.so.1": b"vulkan",
    "Release/v8_context_snapshot.bin": b"snapshot",
    "Release/vk_swiftshader_icd.json": b"{}",
    "Resources/chrome_100_percent.pak": b"100",
    "Resources/chrome_200_percent.pak": b"200",
    "Resources/icudtl.dat": b"icu",
    "Resources/resources.pak": b"resources",
    "Resources/locales/en-US.pak": b"locale",
    "LICENSE.txt": b"BSD license\n",
    "CREDITS.html": b"<html>credits</html>\n",
    "include/not-staged.h": b"not staged",
}


def _write_tar(path: Path, platform: str) -> None:
    root = f"cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_{platform}"
    files = WINDOWS_FILES if platform == "windows64" else LINUX_FILES
    with tarfile.open(path, "w:bz2") as archive:
        directory_names = {root}
        for relative in files:
            parent = Path(relative).parent.as_posix()
            while parent not in ("", "."):
                directory_names.add(f"{root}/{parent}")
                parent = Path(parent).parent.as_posix()
        for name in sorted(directory_names):
            info = tarfile.TarInfo(name)
            info.type = tarfile.DIRTYPE
            info.mode = 0o755
            archive.addfile(info)
        for relative, content in sorted(files.items()):
            info = tarfile.TarInfo(f"{root}/{relative}")
            info.size = len(content)
            info.mode = 0o755 if relative.endswith("chrome-sandbox") else 0o644
            archive.addfile(info, io.BytesIO(content))


def _fixture_lock(directory: Path) -> tuple[dict, dict[str, Path]]:
    lock = copy.deepcopy(cef_runtime.load_lock())
    archives: dict[str, Path] = {}
    for platform, suffix in (("windows-x64", "windows64"), ("linux-x64", "linux64")):
        archive = directory / lock["platforms"][platform]["archive"]["filename"]
        _write_tar(archive, suffix)
        manifest, manifest_sha256 = cef_runtime.archive_manifest(archive)
        sha1 = hashlib.sha1(archive.read_bytes()).hexdigest()
        sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()
        record = lock["platforms"][platform]
        record["archive"]["size"] = archive.stat().st_size
        record["archive"]["sha1"] = sha1
        record["archive"]["upstream_sha1"] = sha1
        record["archive"]["sidecar_sha1"] = sha1
        record["archive"]["sha256"] = sha256
        record["archive"]["project_sha256"] = sha256
        record["raw_manifest_sha256"] = manifest_sha256
        archives[platform] = archive
    cef_runtime.validate_lock(lock)
    return lock, archives


class CEFRuntimeToolTests(unittest.TestCase):
    def test_canonical_lock_has_one_real_pair(self) -> None:
        lock = cef_runtime.load_lock()
        self.assertEqual(lock["cef_version"], "152.0.8+g1ce985c+chromium-152.0.7977.134")
        self.assertEqual(lock["chromium_version"], "152.0.7977.134")
        self.assertEqual(
            lock["platforms"]["windows-x64"]["archive"]["sha1"],
            "fcefc344b5508991727bae786b2392190379bbcc",
        )
        self.assertEqual(
            lock["platforms"]["windows-x64"]["archive"]["sha256"],
            "390d03b92f5d30d8c68fc7934c7d3e8fda916f52c9131d796da171caae549920",
        )
        self.assertEqual(
            lock["platforms"]["windows-x64"]["raw_manifest_sha256"],
            "79279882bf41a685a549b174afb09100cd26e2928df5e239ed92ca752a8d8e75",
        )
        self.assertEqual(
            lock["platforms"]["linux-x64"]["archive"]["sha1"],
            "add0a51f7333bc660e8e3bafd998e0122568f7d8",
        )
        self.assertEqual(
            lock["platforms"]["linux-x64"]["archive"]["sha256"],
            "4967293a608424b98f2ff4ab15f4119064de966018df6458a80f2a7073dd1dc0",
        )
        self.assertEqual(
            lock["platforms"]["linux-x64"]["raw_manifest_sha256"],
            "fd82d90e1f0d6d632b8423499264c95e65a6a2eec623069faea51bc49b96612e",
        )
        self.assertFalse(lock["codec"]["proprietary_codecs"])

    def test_lock_cannot_drop_required_runtime_inputs(self) -> None:
        lock = copy.deepcopy(cef_runtime.load_lock())
        lock["platforms"]["linux-x64"]["runtime"]["required"].remove("Release/libcef.so")
        with self.assertRaises(cef_runtime.LockError):
            cef_runtime.validate_lock(lock)

    def test_safe_extract_rejects_traversal_and_links(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            traversal = directory / "traversal.tar.bz2"
            with tarfile.open(traversal, "w:bz2") as archive:
                info = tarfile.TarInfo("../outside")
                info.size = 1
                archive.addfile(info, io.BytesIO(b"x"))
            with self.assertRaises(cef_runtime.LockError):
                cef_runtime.safe_extract(traversal, directory / "out")

            link = directory / "link.tar.bz2"
            with tarfile.open(link, "w:bz2") as archive:
                info = tarfile.TarInfo("root/link")
                info.type = tarfile.SYMTYPE
                info.linkname = "../../outside"
                archive.addfile(info)
            with self.assertRaises(cef_runtime.LockError):
                cef_runtime.safe_extract(link, directory / "link-out")

    def test_stage_selects_allowlisted_runtime_and_generates_metadata(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, archives = _fixture_lock(directory)
            staged = directory / "staged"
            project_root = directory / "project"
            project_root.mkdir()
            (project_root / "client.dll").write_bytes(b"client")
            result = cef_runtime.stage_runtime(
                "windows-x64",
                archives["windows-x64"],
                staged,
                lock,
                project_root=project_root,
            )
            self.assertIn("Release/libcef.dll", result["files"])
            self.assertFalse((staged / "Release/bootstrapc.exe").exists())
            self.assertFalse((staged / "include/not-staged.h").exists())
            self.assertTrue((staged / "Resources/locales/en-US.pak").exists())
            self.assertEqual(result["bootstrap_project"][0]["path"], "client.dll")

            metadata = directory / "metadata"
            unexpected = staged / "Release/unknown.dll"
            unexpected.write_bytes(b"unexpected")
            with self.assertRaises(cef_runtime.LockError):
                cef_runtime.generate_metadata("windows-x64", staged, metadata, lock)
            unexpected.unlink()
            generated = cef_runtime.generate_metadata("windows-x64", staged, metadata, lock)
            self.assertEqual(generated["manifest_sha256"], result["manifest_sha256"])
            notices = (metadata / "THIRD_PARTY_NOTICES.txt").read_text(encoding="utf-8")
            self.assertIn("BSD license", notices)
            sbom = json.loads((metadata / "cef.sbom.cdx.json").read_text(encoding="utf-8"))
            self.assertEqual(sbom["bomFormat"], "CycloneDX")
            self.assertEqual(sbom["specVersion"], "1.5")
            self.assertTrue(any(component["name"] == "Chromium" for component in sbom["components"]))

    def test_archive_hash_and_raw_manifest_are_verified_independently(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, archives = _fixture_lock(directory)
            verified = cef_runtime.verify_archive("linux-x64", archives["linux-x64"], lock)
            self.assertEqual(verified["file_count"], len(LINUX_FILES))
            archives["linux-x64"].write_bytes(archives["linux-x64"].read_bytes() + b"tamper")
            with self.assertRaises(cef_runtime.LockError):
                cef_runtime.verify_archive("linux-x64", archives["linux-x64"], lock)

    def test_stage_rejects_unexpected_runtime_file(self) -> None:
        with TemporaryDirectory() as temporary:
            directory = Path(temporary)
            lock, archives = _fixture_lock(directory)
            archive = archives["linux-x64"]
            with tarfile.open(archive, "w:bz2") as output:
                for relative, content in sorted(LINUX_FILES.items()):
                    info = tarfile.TarInfo(
                        "cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_linux64/"
                        + relative
                    )
                    info.size = len(content)
                    output.addfile(info, io.BytesIO(content))
                info = tarfile.TarInfo(
                    "cef_binary_152.0.8+g1ce985c+chromium-152.0.7977.134_linux64/"
                    "Release/unexpected.so"
                )
                info.size = 1
                output.addfile(info, io.BytesIO(b"x"))
            _, digest = cef_runtime.archive_manifest(archive)
            record = lock["platforms"]["linux-x64"]
            record["archive"]["size"] = archive.stat().st_size
            record["archive"]["sha1"] = hashlib.sha1(archive.read_bytes()).hexdigest()
            record["archive"]["upstream_sha1"] = record["archive"]["sha1"]
            record["archive"]["sidecar_sha1"] = record["archive"]["sha1"]
            record["archive"]["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
            record["archive"]["project_sha256"] = record["archive"]["sha256"]
            record["raw_manifest_sha256"] = digest
            with self.assertRaises(cef_runtime.LockError):
                cef_runtime.stage_runtime("linux-x64", archive, directory / "staged", lock)

    def test_locked_fetch_rejects_redirects(self) -> None:
        class RedirectHandler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - stdlib handler API
                self.send_response(302)
                self.send_header("Location", "/archive")
                self.end_headers()

            def log_message(self, *_args: object) -> None:
                return

        with socketserver.TCPServer(("127.0.0.1", 0), RedirectHandler) as server:
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            url = f"http://127.0.0.1:{server.server_address[1]}/archive"
            with self.assertRaises(cef_runtime.LockError):
                cef_runtime._open_locked_url(url)
            server.shutdown()
            thread.join(timeout=2)


if __name__ == "__main__":
    unittest.main()
