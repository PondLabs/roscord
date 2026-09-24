#!/usr/bin/env python3
"""Acquire, verify, and stage roscord's locked CEF runtime.

This module is deliberately independent from the application.  It is release
tooling only: the application never imports it and never downloads CEF at
runtime.  The lock file is the source of truth for both desktop archives.

The implementation uses only the Python standard library so it can run on the
Windows and Linux release images before Flutter or the native host is built.
"""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path, PurePosixPath
from typing import Any, BinaryIO, Iterable, Mapping, Sequence


LOCK_PATH = Path(__file__).resolve().parents[1] / "third_party" / "cef" / "cef.lock.json"
LOCK_SCHEMA_VERSION = 1
SOURCE_HOST = "cef-builds.spotifycdn.com"
HEX_RE = re.compile(r"^[0-9a-f]+$", re.IGNORECASE)
ARCHIVE_RE = re.compile(
    r"^cef_binary_(?P<version>[^_]+)_(?P<platform>windows64|linux64)\.tar\.bz2$"
)
MAX_MEMBER_COUNT = 100_000
MAX_MEMBER_BYTES = 8 * 1024 * 1024 * 1024
MAX_EXTRACTED_BYTES = 16 * 1024 * 1024 * 1024
REQUIRED_RUNTIME_PATTERNS = {
    "windows-x64": frozenset(
        {
            "Release/bootstrap.exe",
            "Release/chrome_elf.dll",
            "Release/d3dcompiler_47.dll",
            "Release/dxcompiler.dll",
            "Release/dxil.dll",
            "Release/libEGL.dll",
            "Release/libGLESv2.dll",
            "Release/libcef.dll",
            "Release/v8_context_snapshot.bin",
            "Release/vk_swiftshader.dll",
            "Release/vk_swiftshader_icd.json",
            "Release/vulkan-1.dll",
            "Resources/chrome_100_percent.pak",
            "Resources/chrome_200_percent.pak",
            "Resources/icudtl.dat",
            "Resources/resources.pak",
            "Resources/locales/*.pak",
            "LICENSE.txt",
            "CREDITS.html",
        }
    ),
    "linux-x64": frozenset(
        {
            "Release/chrome-sandbox",
            "Release/libEGL.so",
            "Release/libGLESv2.so",
            "Release/libcef.so",
            "Release/libvk_swiftshader.so",
            "Release/libvulkan.so.1",
            "Release/v8_context_snapshot.bin",
            "Release/vk_swiftshader_icd.json",
            "Resources/chrome_100_percent.pak",
            "Resources/chrome_200_percent.pak",
            "Resources/icudtl.dat",
            "Resources/resources.pak",
            "Resources/locales/*.pak",
            "LICENSE.txt",
            "CREDITS.html",
        }
    ),
}
BOOTSTRAP_PATTERNS = {
    "windows-x64": {"archive": ["Release/bootstrap.exe"], "project": ["cef_host.dll"]},
    "linux-x64": {"archive": [], "project": []},
}
# Where archive paths land in a staged runtime.  On Linux CEF loads ICU data,
# the .pak resources and locales/ from the directory that holds libcef.so,
# whatever CefSettings says, so the staged Linux runtime moves the archive's
# Resources/ into Release/.  Windows keeps the archive layout.
STAGED_PREFIXES: dict[str, tuple[tuple[str, str], ...]] = {
    "linux-x64": (("Resources/", "Release/"),),
}


def staged_path(platform: str, relative: str) -> str:
    """The staged-runtime path (or pattern) for an archive path (or pattern)."""

    for source, target in STAGED_PREFIXES.get(platform, ()):
        if relative.startswith(source):
            return target + relative[len(source) :]
    return relative


class LockError(ValueError):
    """Raised when a lock, archive, or staged runtime violates the policy."""


def _canonical_json(value: Any) -> bytes:
    return json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise LockError(f"cannot read JSON file {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise LockError(f"JSON root must be an object: {path}")
    return value


def _require_string(value: Any, name: str) -> str:
    if not isinstance(value, str) or not value:
        raise LockError(f"{name} must be a non-empty string")
    return value


def _require_hex(value: Any, name: str, length: int) -> str:
    value = _require_string(value, name).lower()
    if len(value) != length or not HEX_RE.fullmatch(value):
        raise LockError(f"{name} must be {length} hexadecimal characters")
    if set(value) == {"0"}:
        raise LockError(f"{name} cannot be a placeholder")
    return value


def _platform_record(lock: Mapping[str, Any], platform: str) -> dict[str, Any]:
    platforms = lock.get("platforms")
    if not isinstance(platforms, dict):
        raise LockError("lock.platforms must be an object")
    record = platforms.get(platform)
    if not isinstance(record, dict):
        raise LockError(f"lock has no {platform} platform record")
    return record


def _archive_hash(record: Mapping[str, Any], key: str, alias: str) -> str:
    archive = record.get("archive")
    if not isinstance(archive, dict):
        raise LockError("platform archive must be an object")
    value_key = key if key in archive else alias
    value = _require_hex(
        archive.get(value_key),
        f"archive.{value_key}",
        40 if key.endswith("sha1") else 64,
    )
    if alias in archive:
        other = _require_hex(
            archive.get(alias),
            f"archive.{alias}",
            40 if alias.endswith("sha1") else 64,
        )
        if other != value:
            raise LockError(f"archive.{key} and archive.{alias} disagree")
    return value


def _validate_url(url: Any, filename: str) -> str:
    url = _require_string(url, "archive.url")
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.hostname != SOURCE_HOST
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise LockError(
            f"archive.url must be an exact HTTPS URL on {SOURCE_HOST} without credentials/query"
        )
    if Path(urllib.parse.unquote(parsed.path)).name != filename:
        raise LockError("archive.url filename does not match archive.filename")
    return url


def _validate_patterns(value: Any, name: str) -> list[str]:
    if not isinstance(value, list) or not value or not all(
        isinstance(item, str)
        and item
        and "\\" not in item
        and not item.startswith("/")
        and not re.match(r"^[A-Za-z]:", item)
        and posixpath.normpath(item) == item
        and item not in (".", "..")
        for item in value
    ):
        raise LockError(f"{name} must be a non-empty list of relative POSIX patterns")
    return value


def _validate_optional_patterns(value: Any, name: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(
        isinstance(item, str)
        and item
        and "\\" not in item
        and not item.startswith("/")
        and not re.match(r"^[A-Za-z]:", item)
        and posixpath.normpath(item) == item
        and item not in (".", "..")
        for item in value
    ):
        raise LockError(f"{name} must be a list of relative POSIX patterns")
    return value


def validate_lock(lock: Mapping[str, Any]) -> dict[str, Any]:
    """Validate and return a copy of a CEF lock.

    Validation is intentionally strict.  In particular, a lock cannot opt in
    to a moving URL, a different host, a placeholder digest, or a mixed CEF /
    Chromium tuple.
    """

    schema = lock.get("schema_version", lock.get("schema"))
    if "schema_version" in lock and "schema" in lock and lock["schema_version"] != lock["schema"]:
        raise LockError("schema_version and schema disagree")
    if schema != LOCK_SCHEMA_VERSION:
        raise LockError(f"unsupported lock schema: {schema!r}")

    cef_version = _require_string(lock.get("cef_version"), "cef_version")
    cef_branch = _require_string(lock.get("cef_branch"), "cef_branch")
    chromium_version = _require_string(lock.get("chromium_version"), "chromium_version")
    distribution = _require_string(lock.get("distribution"), "distribution")
    if distribution != "standard":
        raise LockError("only the official standard CEF distribution is supported")
    if chromium_version not in cef_version:
        raise LockError("cef_version must contain the pinned Chromium tuple")
    if not re.fullmatch(r"\d+", cef_branch):
        raise LockError("cef_branch must be numeric")

    codec = lock.get("codec")
    if not isinstance(codec, dict):
        raise LockError("codec must be an object")
    if codec.get("proprietary_codecs") is not False:
        raise LockError("proprietary_codecs must remain false")
    if codec.get("ffmpeg_branding") not in ("Chromium", "chromium"):
        raise LockError("ffmpeg_branding must be Chromium")

    source = lock.get("source")
    if not isinstance(source, dict):
        raise LockError("source must be an object")
    if source.get("host") != SOURCE_HOST:
        raise LockError(f"source.host must be {SOURCE_HOST}")
    index_url = source.get("index_url")
    if index_url != f"https://{SOURCE_HOST}/index.json":
        raise LockError("source.index_url must point to the official builder index")
    if source.get("archive_base_url") != f"https://{SOURCE_HOST}/":
        raise LockError("source.archive_base_url must point to the official builder origin")

    platforms = lock.get("platforms")
    if not isinstance(platforms, dict) or set(platforms) != {"windows-x64", "linux-x64"}:
        raise LockError("lock.platforms must contain exactly windows-x64 and linux-x64")

    expected_suffix = {"windows-x64": "windows64", "linux-x64": "linux64"}
    for platform, suffix in expected_suffix.items():
        record = _platform_record(lock, platform)
        archive = record.get("archive")
        if not isinstance(archive, dict):
            raise LockError(f"{platform}.archive must be an object")
        filename = _require_string(archive.get("filename"), f"{platform}.archive.filename")
        match = ARCHIVE_RE.fullmatch(filename)
        if not match or match.group("version") != cef_version or match.group("platform") != suffix:
            raise LockError(f"{platform}.archive.filename is not the locked standard archive")
        _validate_url(archive.get("url"), filename)
        size = archive.get("size")
        if not isinstance(size, int) or size <= 0:
            raise LockError(f"{platform}.archive.size must be a positive integer")
        sha1 = _archive_hash(record, "sha1", "upstream_sha1")
        sha256 = _archive_hash(record, "sha256", "project_sha256")
        # Keep every recorded digest in sync.  The explicit sidecar and
        # project digests make provenance auditable without another lookup.
        sidecar_sha1 = _require_hex(
            archive.get("sidecar_sha1"), f"{platform}.archive.sidecar_sha1", 40
        )
        if sidecar_sha1 != sha1:
            raise LockError(f"{platform}.archive.sidecar_sha1 disagrees with sha1")
        if _require_hex(archive.get("upstream_sha1"), f"{platform}.archive.upstream_sha1", 40) != sha1:
            raise LockError(f"{platform}.archive.upstream_sha1 disagrees with sha1")
        if _require_hex(archive.get("project_sha256"), f"{platform}.archive.project_sha256", 64) != sha256:
            raise LockError(f"{platform}.archive.project_sha256 disagrees with sha256")
        _require_hex(record.get("raw_manifest_sha256"), f"{platform}.raw_manifest_sha256", 64)

        runtime = record.get("runtime")
        if not isinstance(runtime, dict):
            raise LockError(f"{platform}.runtime must be an object")
        required = _validate_patterns(runtime.get("required"), f"{platform}.runtime.required")
        allowlist = _validate_patterns(runtime.get("allowlist"), f"{platform}.runtime.allowlist")
        missing_required = REQUIRED_RUNTIME_PATTERNS[platform].difference(required)
        if missing_required:
            raise LockError(
                f"{platform}.runtime.required is missing locked inputs: {sorted(missing_required)}"
            )
        for required_pattern in required:
            if not any(_pattern_covers(pattern, required_pattern) for pattern in allowlist):
                raise LockError(
                    f"{platform}.runtime.required pattern is not allow-listed: {required_pattern}"
                )
        _validate_optional_patterns(runtime.get("forbidden"), f"{platform}.runtime.forbidden")
        # Both hosts compile against the locked SDK: the Windows client DLL and
        # the Linux CEF engine.
        build_sdk = record.get("build_sdk")
        if not isinstance(build_sdk, dict):
            raise LockError(f"{platform}.build_sdk must be an object")
        build_required = _validate_patterns(
            build_sdk.get("required"), f"{platform}.build_sdk.required"
        )
        build_allowlist = _validate_patterns(
            build_sdk.get("allowlist"), f"{platform}.build_sdk.allowlist"
        )
        missing_build = [
            pattern
            for pattern in build_required
            if not any(_pattern_covers(allowed, pattern) for allowed in build_allowlist)
        ]
        if missing_build:
            raise LockError(
                f"{platform}.build_sdk.required is not allow-listed: {missing_build}"
            )
        _validate_optional_patterns(
            build_sdk.get("forbidden"), f"{platform}.build_sdk.forbidden"
        )
        bootstrap = record.get("bootstrap", {})
        if not isinstance(bootstrap, dict):
            raise LockError(f"{platform}.bootstrap must be an object")
        for field in ("archive", "project"):
            values = _validate_optional_patterns(bootstrap.get(field), f"{platform}.bootstrap.{field}")
            if values != BOOTSTRAP_PATTERNS[platform][field]:
                raise LockError(f"{platform}.bootstrap.{field} does not match the locked input list")
            if field == "archive":
                for bootstrap_pattern in values:
                    if not any(_pattern_covers(pattern, bootstrap_pattern) for pattern in allowlist):
                        raise LockError(
                            f"{platform}.bootstrap.archive input is not runtime allow-listed: {bootstrap_pattern}"
                        )

    policy = lock.get("policy")
    if not isinstance(policy, dict):
        raise LockError("lock.policy must be an object")
    if policy.get("reject_redirects") is not True or policy.get("reject_links") is not True:
        raise LockError("lock.policy must reject redirects and archive links")
    if policy.get("runtime_download") is not False:
        raise LockError("lock.policy.runtime_download must remain false")
    if policy.get("sbom_format") != "CycloneDX-1.5":
        raise LockError("lock.policy.sbom_format must be CycloneDX-1.5")
    required_notices = policy.get("required_notice_files")
    if required_notices != ["LICENSE.txt", "CREDITS.html"]:
        raise LockError("lock.policy.required_notice_files must include the CEF notices")
    for field in (
        "refresh_max_days",
        "high_severity_refresh_hours",
        "high_severity_release_hours",
        "lower_severity_release_days",
    ):
        value = policy.get(field)
        if not isinstance(value, int) or value <= 0:
            raise LockError(f"lock.policy.{field} must be a positive integer")

    # Both archives must represent one atomic release tuple.
    versions = {
        _platform_record(lock, platform)["archive"]["filename"]
        for platform in platforms
    }
    if len({ARCHIVE_RE.fullmatch(name).group("version") for name in versions}) != 1:
        raise LockError("platform archives do not share one CEF/Chromium tuple")
    return json.loads(json.dumps(lock))


def load_lock(path: Path | str = LOCK_PATH) -> dict[str, Any]:
    return validate_lock(_read_json(Path(path)))


def _normalise_member_name(name: str) -> str:
    """Return a safe POSIX archive name or raise LockError."""

    if not name or "\x00" in name or "\\" in name:
        raise LockError(f"unsafe archive member name: {name!r}")
    name = name.replace("//", "/")
    if name.startswith("/") or re.match(r"^[A-Za-z]:", name):
        raise LockError(f"absolute archive member name: {name!r}")
    normal = posixpath.normpath(name)
    if normal in ("", ".") or normal == ".." or normal.startswith("../"):
        raise LockError(f"archive traversal member: {name!r}")
    return normal


def _sha256_stream(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def _archive_hashes(path: Path) -> tuple[str, str]:
    sha1 = hashlib.sha1()
    sha256 = hashlib.sha256()
    try:
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                sha1.update(chunk)
                sha256.update(chunk)
    except OSError as exc:
        raise LockError(f"cannot read archive {path}: {exc}") from exc
    return sha1.hexdigest(), sha256.hexdigest()


def archive_manifest(archive: Path | str) -> tuple[dict[str, Any], str]:
    """Build the deterministic manifest for regular files in a CEF archive."""

    archive = Path(archive)
    entries: list[dict[str, Any]] = []
    try:
        # Stream mode reads the bz2 archive once.  Random access would
        # decompress it again to reach each member.
        tar = tarfile.open(archive, mode="r|bz2")
    except (OSError, tarfile.TarError) as exc:
        raise LockError(f"cannot open CEF archive {archive}: {exc}") from exc
    with tar:
        seen: set[str] = set()
        for member in tar:
            if len(seen) >= MAX_MEMBER_COUNT:
                raise LockError("archive has too many members")
            normal = _normalise_member_name(member.name)
            folded = normal.casefold()
            if folded in seen:
                raise LockError(f"archive contains duplicate/case-colliding member: {normal}")
            seen.add(folded)
            if member.issym() or member.islnk() or not (member.isdir() or member.isfile()):
                raise LockError(f"archive member is not a regular file or directory: {normal}")
            if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                raise LockError(f"archive member is too large: {normal}")
            if member.isfile():
                stream = tar.extractfile(member)
                if stream is None:
                    raise LockError(f"cannot read archive member: {normal}")
                with stream:
                    entries.append(
                        {
                            "path": normal,
                            "size": member.size,
                            "mode": member.mode & 0o7777,
                            "uid": member.uid,
                            "gid": member.gid,
                            "sha256": _sha256_stream(stream),
                        }
                    )
    entries.sort(key=lambda entry: entry["path"])
    manifest = {"schema": 1, "files": entries}
    return manifest, hashlib.sha256(_canonical_json(manifest)).hexdigest()


def _safe_destination(root: Path, relative: str) -> Path:
    destination = root.joinpath(*PurePosixPath(relative).parts)
    root_resolved = root.resolve()
    destination_resolved = destination.resolve()
    try:
        destination_resolved.relative_to(root_resolved)
    except ValueError as exc:
        raise LockError(f"archive member escapes extraction root: {relative}") from exc
    return destination


def _ensure_no_symlink_ancestors(path: Path) -> None:
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise LockError(f"path contains a symlink: {candidate}")


def safe_extract(archive: Path | str, destination: Path | str) -> Path:
    """Extract a CEF archive without following links or allowing traversal."""

    archive = Path(archive)
    destination = Path(destination)
    _ensure_no_symlink_ancestors(destination)
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise LockError(f"extraction destination must be a real directory: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    extracted_bytes = 0
    try:
        # Stream mode reads the bz2 archive once (see archive_manifest).
        tar = tarfile.open(archive, mode="r|bz2")
    except (OSError, tarfile.TarError) as exc:
        raise LockError(f"cannot open CEF archive {archive}: {exc}") from exc
    with tar:
        seen: set[str] = set()
        for member in tar:
            if len(seen) >= MAX_MEMBER_COUNT:
                raise LockError("archive has too many members")
            member.name = _normalise_member_name(member.name)
            folded = member.name.casefold()
            if folded in seen:
                raise LockError(f"archive contains duplicate/case-colliding member: {member.name}")
            seen.add(folded)
            if member.issym() or member.islnk() or member.ischr() or member.isblk() or member.isfifo() or not (
                member.isdir() or member.isfile()
            ):
                raise LockError(f"archive member is not a regular file or directory: {member.name}")
            if member.size < 0 or member.size > MAX_MEMBER_BYTES:
                raise LockError(f"archive member is too large: {member.name}")
            target = _safe_destination(destination, member.name)
            if member.isdir():
                if target.exists() and not target.is_dir():
                    raise LockError(f"archive directory collides with a file: {member.name}")
                target.mkdir(parents=True, exist_ok=True)
                continue
            if target.exists() and target.is_dir():
                raise LockError(f"archive file collides with a directory: {member.name}")
            target.parent.mkdir(parents=True, exist_ok=True)
            # Check every existing parent for a symlink/reparse point.
            parent = target.parent
            while parent != destination:
                if parent.is_symlink():
                    raise LockError(f"extraction destination contains a symlink: {parent}")
                parent = parent.parent
            try:
                stream = tar.extractfile(member)
                if stream is None:
                    raise LockError(f"cannot read archive member: {member.name}")
                with stream, target.open("xb") as output:
                    remaining = member.size
                    while remaining:
                        chunk = stream.read(min(1024 * 1024, remaining))
                        if not chunk:
                            raise LockError(f"archive member ended early: {member.name}")
                        output.write(chunk)
                        remaining -= len(chunk)
                        extracted_bytes += len(chunk)
                        if extracted_bytes > MAX_EXTRACTED_BYTES:
                            raise LockError("archive exceeds the safe extracted-size limit")
                os.chmod(target, member.mode & 0o7777)
            except FileExistsError as exc:
                raise LockError(f"archive member already exists: {member.name}") from exc
            except OSError as exc:
                raise LockError(f"cannot extract archive member {member.name}: {exc}") from exc
    return destination


def _path_matches(path: str, pattern: str) -> bool:
    # fnmatch treats '/' as an ordinary character, which is exactly what we
    # need for lock patterns.  Matching is case-sensitive even on Windows so
    # a case-only mutation cannot silently replace a required CEF resource.
    return fnmatch.fnmatchcase(path, pattern)


def _pattern_covers(pattern: str, candidate: str) -> bool:
    # Required entries are themselves lock patterns.  An allow-list pattern
    # covers one when the candidate path is accepted by that same safe
    # fnmatch grammar; validation has already rejected absolute and traversal
    # patterns.
    return fnmatch.fnmatchcase(candidate, pattern)


def _find_archive_root(extracted: Path) -> Path:
    roots = [entry for entry in extracted.iterdir() if entry.name not in (".", "..")]
    if len(roots) != 1 or not roots[0].is_dir() or roots[0].is_symlink():
        raise LockError("CEF archive must contain exactly one top-level directory")
    return roots[0]


def _relative_files(root: Path) -> list[Path]:
    if root.is_symlink() or not root.is_dir():
        raise LockError(f"runtime root must be a real directory: {root}")
    files: list[Path] = []
    for path in root.rglob("*"):
        if path.is_symlink():
            raise LockError(f"staged runtime contains a symlink: {path}")
        if path.is_file():
            files.append(path)
    return files


def filesystem_manifest(root: Path | str, *, ignored: Iterable[str] = ()) -> tuple[dict[str, Any], str]:
    root = Path(root)
    ignored_set = set(ignored)
    entries: list[dict[str, Any]] = []
    for path in _relative_files(root):
        relative = path.relative_to(root).as_posix()
        if relative in ignored_set:
            continue
        with path.open("rb") as stream:
            digest = _sha256_stream(stream)
        entries.append(
            {
                "path": relative,
                "size": path.stat().st_size,
                "mode": stat.S_IMODE(path.stat().st_mode),
                "uid": getattr(path.stat(), "st_uid", 0),
                "gid": getattr(path.stat(), "st_gid", 0),
                "sha256": digest,
            }
        )
    entries.sort(key=lambda entry: entry["path"])
    manifest = {"schema": 1, "files": entries}
    return manifest, hashlib.sha256(_canonical_json(manifest)).hexdigest()


def _verify_hashes(archive: Path, record: Mapping[str, Any]) -> tuple[str, str]:
    expected_size = record["archive"]["size"]
    if archive.is_symlink():
        raise LockError(f"archive path must not be a symlink: {archive}")
    try:
        actual_size = archive.stat().st_size
    except OSError as exc:
        raise LockError(f"cannot stat archive {archive}: {exc}") from exc
    if actual_size != expected_size:
        raise LockError(f"archive size mismatch: expected {expected_size}, got {actual_size}")
    sha1, sha256 = _archive_hashes(archive)
    expected_sha1 = record["archive"]["sha1"]
    expected_sha256 = record["archive"]["sha256"]
    if sha1 != expected_sha1:
        raise LockError(f"archive SHA-1 mismatch: expected {expected_sha1}, got {sha1}")
    if sha256 != expected_sha256:
        raise LockError(f"archive SHA-256 mismatch: expected {expected_sha256}, got {sha256}")
    return sha1, sha256


def verify_archive(
    platform: str, archive: Path | str, lock: Mapping[str, Any] | None = None
) -> dict[str, Any]:
    """Verify a local archive and its extracted-file manifest offline."""

    lock = validate_lock(lock or load_lock())
    record = _platform_record(lock, platform)
    archive = Path(archive)
    if archive.name != record["archive"]["filename"]:
        raise LockError(
            f"archive filename is not the locked input: expected {record['archive']['filename']}"
        )
    _verify_hashes(archive, record)
    manifest, manifest_sha256 = archive_manifest(archive)
    expected_manifest = record["raw_manifest_sha256"]
    if manifest_sha256 != expected_manifest:
        raise LockError(
            f"raw manifest mismatch: expected {expected_manifest}, got {manifest_sha256}"
        )
    return {
        "platform": platform,
        "archive": record["archive"]["filename"],
        "sha1": record["archive"]["sha1"],
        "sha256": record["archive"]["sha256"],
        "raw_manifest_sha256": manifest_sha256,
        "file_count": len(manifest["files"]),
    }


class _RejectRedirect(urllib.request.HTTPRedirectHandler):
    def _reject(self, request: urllib.request.Request, *_args: Any) -> Any:
        raise LockError(f"unexpected redirect while fetching locked CEF input: {request.full_url}")

    http_error_301 = _reject
    http_error_302 = _reject
    http_error_303 = _reject
    http_error_307 = _reject
    http_error_308 = _reject


def _open_locked_url(url: str) -> Any:
    request = urllib.request.Request(
        url,
        headers={"User-Agent": "roscord-cef-lock/1", "Accept": "application/octet-stream"},
        method="GET",
    )
    opener = urllib.request.build_opener(_RejectRedirect())
    try:
        response = opener.open(request, timeout=60)
    except LockError:
        raise
    except (OSError, urllib.error.URLError) as exc:
        raise LockError(f"cannot fetch locked URL {url}: {exc}") from exc
    if response.geturl() != url:
        response.close()
        raise LockError(f"locked URL changed during fetch: {url}")
    status = getattr(response, "status", response.getcode())
    if status != 200:
        response.close()
        raise LockError(f"locked URL returned HTTP {status}: {url}")
    return response


def _read_sidecar(url: str, expected_sha1: str) -> None:
    sidecar_url = f"{url}.sha1"
    response = _open_locked_url(sidecar_url)
    try:
        body = response.read(4096).decode("ascii", errors="strict")
    except (OSError, UnicodeError) as exc:
        raise LockError(f"cannot read CEF SHA-1 sidecar {sidecar_url}: {exc}") from exc
    finally:
        response.close()
    match = re.search(r"\b([0-9a-fA-F]{40})\b", body)
    if not match or match.group(1).lower() != expected_sha1:
        raise LockError(f"CEF SHA-1 sidecar does not match the lock: {sidecar_url}")


def fetch_archive(
    platform: str,
    cache_dir: Path | str,
    lock: Mapping[str, Any] | None = None,
) -> Path:
    """Fetch one locked archive into a SHA-256-addressed cache.

    The sidecar and archive are both fetched from the exact locked origin.  A
    cached file is accepted only after the same local hash/size checks as a
    newly downloaded file.
    """

    lock = validate_lock(lock or load_lock())
    record = _platform_record(lock, platform)
    archive_info = record["archive"]
    cache_dir = Path(cache_dir)
    _ensure_no_symlink_ancestors(cache_dir)
    if cache_dir.is_symlink() or (cache_dir.exists() and not cache_dir.is_dir()):
        raise LockError(f"CEF cache directory must be a real directory: {cache_dir}")
    target_dir = cache_dir / archive_info["sha256"]
    target = target_dir / archive_info["filename"]
    target_dir.mkdir(parents=True, exist_ok=True)
    if target.exists():
        verify_archive(platform, target, lock)
        return target

    _read_sidecar(archive_info["url"], archive_info["sha1"])
    response = _open_locked_url(archive_info["url"])
    temporary = target.with_name(f".{target.name}.part")
    try:
        content_length = response.headers.get("Content-Length")
        if content_length is not None and int(content_length) != archive_info["size"]:
            raise LockError("locked CEF archive Content-Length does not match the lock")
        sha1 = hashlib.sha1()
        sha256 = hashlib.sha256()
        total = 0
        with temporary.open("xb") as output:
            for chunk in iter(lambda: response.read(1024 * 1024), b""):
                total += len(chunk)
                if total > archive_info["size"]:
                    raise LockError("locked CEF archive exceeded its locked size")
                output.write(chunk)
                sha1.update(chunk)
                sha256.update(chunk)
        if total != archive_info["size"]:
            raise LockError("locked CEF archive ended before its locked size")
        if sha1.hexdigest() != archive_info["sha1"]:
            raise LockError("downloaded CEF archive SHA-1 does not match the lock")
        if sha256.hexdigest() != archive_info["sha256"]:
            raise LockError("downloaded CEF archive SHA-256 does not match the lock")
        os.replace(temporary, target)
    except (OSError, ValueError) as exc:
        raise LockError(f"cannot cache locked CEF archive: {exc}") from exc
    finally:
        response.close()
        if temporary.exists():
            temporary.unlink()
    verify_archive(platform, target, lock)
    return target


def fetch_pair(
    cache_dir: Path | str, lock: Mapping[str, Any] | None = None
) -> dict[str, Path]:
    """Fetch and verify both members of the one locked desktop pair."""

    lock = validate_lock(lock or load_lock())
    return {
        platform: fetch_archive(platform, cache_dir, lock)
        for platform in ("windows-x64", "linux-x64")
    }


def _stage_files(
    platform: str, source_root: Path, destination: Path, record: Mapping[str, Any]
) -> list[str]:
    runtime = record["runtime"]
    allowlist: list[str] = runtime["allowlist"]
    forbidden: list[str] = runtime.get("forbidden", [])
    files = _relative_files(source_root)
    selected: list[tuple[Path, str]] = []
    for path in files:
        relative = path.relative_to(source_root).as_posix()
        # The standard archive intentionally contains headers, examples, and
        # debug/bootstrap helpers.  They are verified by the raw archive
        # digest but are never copied into a release payload.  A forbidden
        # pattern therefore excludes a source member rather than making a
        # valid standard archive impossible to stage.
        if any(_path_matches(relative, pattern) for pattern in forbidden):
            continue
        if any(_path_matches(relative, pattern) for pattern in allowlist):
            selected.append((path, relative))
        elif relative.startswith(("Release/", "Resources/")):
            raise LockError(f"unexpected CEF runtime file in archive: {relative}")
        else:
            # Build and test files are intentionally not staged.  They remain
            # protected by the archive SHA-256 and raw manifest digest.
            continue
    selected_names = {relative for _, relative in selected}
    for required in runtime["required"]:
        if not any(_path_matches(name, required) for name in selected_names):
            raise LockError(f"required CEF runtime input is missing: {required}")
    if "Resources/locales/en-US.pak" not in selected_names:
        raise LockError(f"{platform} CEF en-US locale is missing")

    _ensure_no_symlink_ancestors(destination)
    if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
        raise LockError(f"staging destination must be a real directory: {destination}")
    if destination.exists() and any(destination.iterdir()):
        raise LockError(f"staging destination must be empty: {destination}")
    destination.mkdir(parents=True, exist_ok=True)
    staged_names: set[str] = set()
    for source, relative in selected:
        staged_name = staged_path(platform, relative)
        if staged_name in staged_names:
            raise LockError(f"two archive files stage to {staged_name}")
        staged_names.add(staged_name)
        target = destination.joinpath(*PurePosixPath(staged_name).parts)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        os.chmod(target, stat.S_IMODE(source.stat().st_mode))
    return sorted(selected_names)


def _strip_libraries(platform: str, destination: Path) -> list[str]:
    """Strips debug and local symbols from the staged Linux libraries.

    The standard Linux distribution ships libcef.so unstripped (about 1.4 GB,
    268 MB stripped).  `--strip-unneeded` keeps the dynamic symbol table, so
    the libraries still load and link exactly as before.
    """

    if platform != "linux-x64":
        raise LockError("only the Linux runtime is stripped")
    release = destination / "Release"
    stripped: list[str] = []
    for library in sorted(release.iterdir()):
        name = library.name
        if not library.is_file() or not (name.endswith(".so") or ".so." in name):
            continue
        try:
            subprocess.run(
                ["strip", "--strip-unneeded", str(library)],
                check=True,
                capture_output=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            raise LockError(f"cannot strip {name}: {exc}") from exc
        stripped.append(f"Release/{name}")
    return stripped


def stage_runtime(
    platform: str,
    archive: Path | str,
    destination: Path | str,
    lock: Mapping[str, Any] | None = None,
    *,
    project_root: Path | str | None = None,
    strip: bool = False,
) -> dict[str, Any]:
    """Verify, safely extract, and stage the allow-listed runtime files."""

    lock = validate_lock(lock or load_lock())
    record = _platform_record(lock, platform)
    verify_archive(platform, archive, lock)
    destination = Path(destination)
    project_bootstrap = _verify_project_bootstrap(platform, project_root, record)
    with tempfile.TemporaryDirectory(prefix="roscord-cef-") as temporary:
        extracted = safe_extract(archive, Path(temporary) / "archive")
        root = _find_archive_root(extracted)
        selected = _stage_files(platform, root, destination, record)
    stripped = _strip_libraries(platform, destination) if strip else []
    manifest, digest = filesystem_manifest(destination)
    return {
        "platform": platform,
        "cef_version": lock["cef_version"],
        "files": selected,
        "stripped": stripped,
        "manifest": manifest,
        "manifest_sha256": digest,
        "bootstrap_project": project_bootstrap,
    }


def stage_sdk(
    platform: str,
    archive: Path | str,
    destination: Path | str,
    lock: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Verify and stage the locked CEF build SDK alongside its runtime.

    Release payloads intentionally omit headers, CMake files, and import
    libraries.  Native host builds use this separate directory, which keeps
    the exact pinned SDK available without ever shipping it in the app.
    """

    lock = validate_lock(lock or load_lock())
    record = _platform_record(lock, platform)
    build_sdk = record["build_sdk"]
    verify_archive(platform, archive, lock)
    destination = Path(destination)
    with tempfile.TemporaryDirectory(prefix="roscord-cef-sdk-") as temporary:
        extracted = safe_extract(archive, Path(temporary) / "archive")
        root = _find_archive_root(extracted)
        runtime = record["runtime"]
        runtime_allowlist = list(runtime["allowlist"])
        build_allowlist = list(build_sdk["allowlist"])
        runtime_forbidden = list(runtime.get("forbidden", []))
        build_forbidden = list(build_sdk.get("forbidden", []))
        files = _relative_files(root)
        selected: list[tuple[Path, str]] = []
        for path in files:
            relative = path.relative_to(root).as_posix()
            if any(_path_matches(relative, pattern) for pattern in build_forbidden):
                continue
            if any(_path_matches(relative, pattern) for pattern in build_allowlist):
                selected.append((path, relative))
            elif any(_path_matches(relative, pattern) for pattern in runtime_allowlist):
                selected.append((path, relative))
            elif any(_path_matches(relative, pattern) for pattern in runtime_forbidden):
                # Runtime-only forbidden files (for example bootstrapc.exe and
                # the import library) are either intentionally omitted or are
                # selected above by the build SDK allow-list.
                continue
            elif relative.startswith(("Release/", "Resources/", "include/", "cmake/", "libcef_dll/")):
                raise LockError(f"unexpected CEF SDK file in archive: {relative}")

        selected_names = {relative for _, relative in selected}
        for required in list(runtime["required"]) + list(build_sdk["required"]):
            if not any(_path_matches(name, required) for name in selected_names):
                raise LockError(f"required CEF SDK input is missing: {required}")
        _ensure_no_symlink_ancestors(destination)
        if destination.is_symlink() or (destination.exists() and not destination.is_dir()):
            raise LockError(f"staging destination must be a real directory: {destination}")
        if destination.exists() and any(destination.iterdir()):
            raise LockError(f"staging destination must be empty: {destination}")
        destination.mkdir(parents=True, exist_ok=True)
        for source, relative in selected:
            target = destination.joinpath(*PurePosixPath(relative).parts)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            os.chmod(target, stat.S_IMODE(source.stat().st_mode))

    manifest, digest = filesystem_manifest(destination)
    return {
        "platform": platform,
        "cef_version": lock["cef_version"],
        "files": sorted(selected_names),
        "manifest": manifest,
        "manifest_sha256": digest,
    }


def _verify_project_bootstrap(
    platform: str,
    project_root: Path | str | None,
    record: Mapping[str, Any],
) -> list[dict[str, Any]]:
    """Verify optional app-owned bootstrap inputs against the lock allow-list."""

    patterns = record["bootstrap"].get("project", [])
    if not patterns or project_root is None:
        return []
    root = Path(project_root)
    _ensure_no_symlink_ancestors(root)
    if root.is_symlink() or not root.is_dir():
        raise LockError(f"{platform} project bootstrap root must be a real directory: {root}")
    files = _relative_files(root)
    matches: list[dict[str, Any]] = []
    for pattern in patterns:
        candidates = [
            path
            for path in files
            if _path_matches(path.relative_to(root).as_posix(), pattern)
        ]
        if len(candidates) != 1:
            raise LockError(
                f"{platform} project bootstrap pattern must match exactly one file: {pattern}"
            )
        path = candidates[0]
        with path.open("rb") as stream:
            digest = _sha256_stream(stream)
        file_stat = path.stat()
        matches.append(
            {
                "path": path.relative_to(root).as_posix(),
                "size": file_stat.st_size,
                "mode": stat.S_IMODE(file_stat.st_mode),
                "uid": getattr(file_stat, "st_uid", 0),
                "gid": getattr(file_stat, "st_gid", 0),
                "sha256": digest,
            }
        )
    return matches


def _required_file(destination: Path, pattern: str) -> Path:
    matches = [
        path
        for path in _relative_files(destination)
        if _path_matches(path.relative_to(destination).as_posix(), pattern)
    ]
    if not matches:
        raise LockError(f"required staged input is missing: {pattern}")
    return matches[0]


def generate_metadata(
    platform: str,
    staged: Path | str,
    output: Path | str,
    lock: Mapping[str, Any] | None = None,
    *,
    project_root: Path | str | None = None,
) -> dict[str, Any]:
    """Generate notices, CycloneDX SBOM, provenance, and a signed-byte-ready manifest."""

    lock = validate_lock(lock or load_lock())
    record = _platform_record(lock, platform)
    staged = Path(staged)
    output = Path(output)
    if not staged.is_dir():
        raise LockError(f"staged runtime directory does not exist: {staged}")
    # Verify that the staged directory contains exactly the policy-selected
    # files before emitting any release metadata.
    files = _relative_files(staged)
    allowlist = [staged_path(platform, pattern) for pattern in record["runtime"]["allowlist"]]
    for file in files:
        relative = file.relative_to(staged).as_posix()
        if not any(_path_matches(relative, pattern) for pattern in allowlist):
            raise LockError(f"unexpected staged runtime file: {relative}")
    for required in record["runtime"]["required"]:
        _required_file(staged, staged_path(platform, required))
    project_bootstrap = _verify_project_bootstrap(platform, project_root, record)
    manifest, manifest_sha256 = filesystem_manifest(staged)
    _ensure_no_symlink_ancestors(output)
    if output.is_symlink() or (output.exists() and not output.is_dir()):
        raise LockError(f"metadata output must be a real directory: {output}")
    output.mkdir(parents=True, exist_ok=True)

    license_file = _required_file(staged, "LICENSE.txt")
    credits_file = _required_file(staged, "CREDITS.html")
    notices = (
        "roscord bundled CEF runtime\n"
        f"CEF version: {lock['cef_version']}\n"
        f"Chromium version: {lock['chromium_version']}\n"
        f"Source: {record['archive']['url']}\n\n"
        "===== CEF LICENSE.txt =====\n"
        f"{license_file.read_text(encoding='utf-8', errors='replace')}\n"
        "===== CEF CREDITS.html =====\n"
        f"{credits_file.read_text(encoding='utf-8', errors='replace')}\n"
    )
    (output / "THIRD_PARTY_NOTICES.txt").write_text(notices, encoding="utf-8", newline="\n")

    native_extensions = {".dll", ".exe", ".so", ".bin"}
    native_files = [
        entry["path"]
        for entry in manifest["files"]
        if (
            Path(entry["path"]).suffix.lower() in native_extensions
            or ".so." in Path(entry["path"]).name.lower()
            or Path(entry["path"]).name == "chrome-sandbox"
        )
    ]
    components: list[dict[str, Any]] = [
        {
            "type": "library",
            "bom-ref": "pkg:generic/cef@" + lock["cef_version"],
            "name": "Chromium Embedded Framework",
            "version": lock["cef_version"],
            "licenses": [{"license": {"id": "BSD-3-Clause"}}],
            "externalReferences": [{"type": "distribution", "url": record["archive"]["url"]}],
            "properties": [
                {"name": "roscord:chromium-version", "value": lock["chromium_version"]},
                {"name": "roscord:archive-sha256", "value": record["archive"]["sha256"]},
            ],
        },
        {
            "type": "library",
            "bom-ref": "pkg:generic/chromium@" + lock["chromium_version"],
            "name": "Chromium",
            "version": lock["chromium_version"],
            "licenses": [{"license": {"id": "BSD-3-Clause"}}],
        },
    ]
    for path in native_files:
        components.append(
            {
                "type": "file",
                "bom-ref": "roscord:cef-file:" + path,
                "name": path,
                "version": lock["cef_version"],
                "hashes": [
                    {
                        "alg": "SHA-256",
                        "content": next(entry["sha256"] for entry in manifest["files"] if entry["path"] == path),
                    }
                ],
                "licenses": [{"license": {"id": "BSD-3-Clause"}}],
                "externalReferences": [
                    {"type": "distribution", "url": record["archive"]["url"]}
                ],
                "properties": [
                    {"name": "roscord:locked-version", "value": lock["cef_version"]},
                    {"name": "roscord:platform", "value": platform},
                ],
            }
        )
    sbom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + hashlib.sha256(_canonical_json(manifest)).hexdigest()[:32],
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": "roscord CEF runtime",
                "version": lock["cef_version"],
            },
            "properties": [
                {"name": "roscord:platform", "value": platform},
                {"name": "roscord:manifest-sha256", "value": manifest_sha256},
            ],
        },
        "components": components,
    }
    (output / "cef.sbom.cdx.json").write_bytes(_canonical_json(sbom) + b"\n")

    final_manifest = {
        "schema_version": 1,
        "platform": platform,
        "cef_version": lock["cef_version"],
        "chromium_version": lock["chromium_version"],
        "archive": record["archive"],
        "raw_manifest_sha256": record["raw_manifest_sha256"],
        "staged_manifest_sha256": manifest_sha256,
        "files": manifest["files"],
        "notices": "THIRD_PARTY_NOTICES.txt",
        "sbom": "cef.sbom.cdx.json",
        "bootstrap_project": project_bootstrap,
    }
    (output / "cef.runtime.manifest.json").write_bytes(_canonical_json(final_manifest) + b"\n")
    provenance = {
        "schema_version": 1,
        "platform": platform,
        "cef_version": lock["cef_version"],
        "cef_branch": lock["cef_branch"],
        "chromium_version": lock["chromium_version"],
        "distribution": lock["distribution"],
        "source": {
            "url": record["archive"]["url"],
            "filename": record["archive"]["filename"],
            "upstream_sha1": record["archive"]["sha1"],
            "project_sha256": record["archive"]["sha256"],
        },
        "raw_manifest_sha256": record["raw_manifest_sha256"],
        "staged_manifest_sha256": manifest_sha256,
        "bootstrap_project": project_bootstrap,
        "runtime_download": False,
        "runtime_source": "bundled-release-payload",
    }
    (output / "cef.provenance.json").write_bytes(_canonical_json(provenance) + b"\n")
    return {"platform": platform, "manifest_sha256": manifest_sha256, "output": str(output)}


def _platform_argument(value: str) -> str:
    aliases = {"windows": "windows-x64", "win64": "windows-x64", "linux": "linux-x64", "linux64": "linux-x64"}
    value = aliases.get(value, value)
    if value not in ("windows-x64", "linux-x64"):
        raise argparse.ArgumentTypeError("platform must be windows-x64 or linux-x64")
    return value


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, default=LOCK_PATH, help="path to cef.lock.json")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser(
        "validate-lock", aliases=["verify-lock"], help="validate the canonical lock"
    )

    fetch = subparsers.add_parser("fetch", help="fetch one locked archive")
    fetch.add_argument("--platform", type=_platform_argument, required=True)
    fetch.add_argument("--cache-dir", type=Path, required=True)

    fetch_pair_parser = subparsers.add_parser("fetch-pair", help="fetch both locked archives")
    fetch_pair_parser.add_argument("--cache-dir", type=Path, required=True)

    verify = subparsers.add_parser("verify", help="verify a local archive offline")
    verify.add_argument("--platform", type=_platform_argument, required=True)
    verify.add_argument("archive", type=Path)

    stage = subparsers.add_parser("stage", help="verify and stage the allow-listed runtime")
    stage.add_argument("--platform", type=_platform_argument, required=True)
    stage.add_argument(
        "--project-root",
        type=Path,
        help="optional app root containing lock-listed project bootstrap inputs",
    )
    stage.add_argument(
        "--strip",
        action="store_true",
        help="strip debug and local symbols from the staged libraries (Linux only)",
    )
    stage.add_argument("archive", type=Path)
    stage.add_argument("destination", type=Path)

    sdk = subparsers.add_parser(
        "stage-sdk", help="verify and stage the locked CEF build SDK"
    )
    sdk.add_argument("--platform", type=_platform_argument, default="windows-x64")
    sdk.add_argument("archive", type=Path)
    sdk.add_argument("destination", type=Path)

    metadata = subparsers.add_parser("metadata", help="generate notices, SBOM, and provenance")
    metadata.add_argument("--platform", type=_platform_argument, required=True)
    metadata.add_argument(
        "--project-root",
        type=Path,
        help="optional app root containing lock-listed project bootstrap inputs",
    )
    metadata.add_argument("staged", type=Path)
    metadata.add_argument("output", type=Path)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        lock = load_lock(args.lock)
        if args.command in ("validate-lock", "verify-lock"):
            print(json.dumps({"lock": str(args.lock), "valid": True}, indent=2))
        elif args.command == "fetch":
            print(fetch_archive(args.platform, args.cache_dir, lock))
        elif args.command == "fetch-pair":
            print(
                json.dumps(
                    {platform: str(path) for platform, path in fetch_pair(args.cache_dir, lock)},
                    indent=2,
                )
            )
        elif args.command == "verify":
            print(json.dumps(verify_archive(args.platform, args.archive, lock), indent=2))
        elif args.command == "stage":
            print(
                json.dumps(
                    stage_runtime(
                        args.platform,
                        args.archive,
                        args.destination,
                        lock,
                        project_root=args.project_root,
                        strip=args.strip,
                    ),
                    indent=2,
                )
            )
        elif args.command == "stage-sdk":
            print(
                json.dumps(
                    stage_sdk(args.platform, args.archive, args.destination, lock),
                    indent=2,
                )
            )
        elif args.command == "metadata":
            print(
                json.dumps(
                    generate_metadata(
                        args.platform,
                        args.staged,
                        args.output,
                        lock,
                        project_root=args.project_root,
                    ),
                    indent=2,
                )
            )
        return 0
    except LockError as exc:
        print(f"cef-runtime: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
