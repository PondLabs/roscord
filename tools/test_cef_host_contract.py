"""Static contract checks for the opt-in Windows CEF host.

The GitHub Windows release job builds this target with the staged CEF SDK.  CI
on other platforms cannot compile the Windows/CEF headers, so these checks
keep the security-critical wiring visible until the native qualification job
is available: the bootstrap path, sandbox handoff, authenticated transport,
bounded framing, and fixture lifecycle must all remain present.
"""

from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / "commet" / "windows" / "cef_host"
SOURCE = (HOST / "cef_host.cpp").read_text(encoding="utf-8")
CMAKE = (HOST / "CMakeLists.txt").read_text(encoding="utf-8")
WINDOWS_CMAKE = (ROOT / "commet" / "windows" / "CMakeLists.txt").read_text(
    encoding="utf-8"
)
DART_RUNTIME = (
    ROOT / "commet" / "lib" / "browser_runtime" / "windows_browser_runtime.dart"
).read_text(encoding="utf-8")
RUNTIME_TOOL = (ROOT / "tools" / "cef_runtime.py").read_text(encoding="utf-8")
MAIN_DART = (ROOT / "commet" / "lib" / "main.dart").read_text(encoding="utf-8")
CEF_LOCK = (ROOT / "third_party" / "cef" / "cef.lock.json").read_text(
    encoding="utf-8"
)
DESKTOP_WORKFLOW = (ROOT / ".github" / "workflows" / "desktop-build.yml").read_text(
    encoding="utf-8"
)
RELEASE_WORKFLOW = (ROOT / ".github" / "workflows" / "release.yml").read_text(
    encoding="utf-8"
)
BUILD_WORKFLOW = (ROOT / ".github" / "workflows" / "build.yml").read_text(
    encoding="utf-8"
)


class CefHostContractTests(unittest.TestCase):
    def test_host_is_opt_in_until_locked_runtime_is_staged(self) -> None:
        self.assertIn(
            'option(ROSCORD_BUILD_CEF_HOST "Build the bundled Windows CEF host" OFF)',
            WINDOWS_CMAKE,
        )
        self.assertIn("find_package(CEF REQUIRED)", CMAKE)
        self.assertIn("bootstrap.exe", CMAKE)
        self.assertIn('OUTPUT_NAME "client"', CMAKE)
        self.assertIn("ENV{ROSCORD_BUILD_CEF_HOST}", WINDOWS_CMAKE)
        self.assertIn("ENV{CEF_ROOT}", WINDOWS_CMAKE)
        self.assertIn("stage-sdk", RUNTIME_TOOL)
        self.assertIn('"build_sdk"', CEF_LOCK)
        self.assertIn("ROSCORD_BUILD_CEF_HOST=ON", DESKTOP_WORKFLOW)
        self.assertIn("ROSCORD_BUILD_CEF_HOST=ON", RELEASE_WORKFLOW)
        self.assertIn("ROSCORD_BUILD_CEF_HOST=ON", BUILD_WORKFLOW)
        for workflow in (BUILD_WORKFLOW, DESKTOP_WORKFLOW, RELEASE_WORKFLOW):
            self.assertIn(
                'Get-ChildItem -LiteralPath $cache -Filter "*.tar.bz2" -File -Recurse',
                workflow,
            )

    def test_parent_lazily_owns_one_authenticated_host(self) -> None:
        self.assertIn("class WindowsBrowserRuntime implements BrowserRuntime", DART_RUNTIME)
        self.assertIn("Process.start", DART_RUNTIME)
        self.assertIn("--parent-pid=", DART_RUNTIME)
        self.assertIn("--nonce=", DART_RUNTIME)
        self.assertIn("ipc.connect", DART_RUNTIME)
        self.assertIn("_startup", DART_RUNTIME)
        self.assertIn("FramedCodec", DART_RUNTIME)
        self.assertIn("browserRuntime ??= WindowsBrowserRuntime()", MAIN_DART)

    def test_bootstrap_and_sandbox_are_owned_by_the_host(self) -> None:
        self.assertIn("CEF_BOOTSTRAP_EXPORT", SOURCE)
        self.assertIn("CefExecuteProcess", SOURCE)
        self.assertIn("CefInitialize", SOURCE)
        self.assertIn("CefShutdown", SOURCE)
        self.assertIn("sandbox_info == nullptr", SOURCE)
        self.assertIn("settings.no_sandbox = false", SOURCE)
        self.assertNotIn("settings.no_sandbox = true", SOURCE)
        self.assertNotIn("browser_subprocess_path", SOURCE)

    def test_pipe_is_authenticated_and_framed(self) -> None:
        self.assertIn("CreateNamedPipeW", SOURCE)
        self.assertIn("GetNamedPipeClientProcessId", SOURCE)
        self.assertIn("EqualSid", SOURCE)
        self.assertIn("kPipePrefix", SOURCE)
        self.assertIn("kConnectTimeoutMs", SOURCE)
        self.assertIn("PIPE_NOWAIT", SOURCE)
        self.assertIn("SetNamedPipeHandleState", SOURCE)
        self.assertIn("kMaxFrameBytes = 1024u * 1024u", SOURCE)
        self.assertIn("nonce_mismatch", SOURCE)
        self.assertIn("unsupported_version", SOURCE)
        self.assertIn("size > kMaxFrameBytes", SOURCE)

    def test_fixture_has_public_lifecycle_events(self) -> None:
        self.assertIn('kFixtureUrl[] = "commet://fixture/"', SOURCE)
        self.assertIn("SendOpened", SOURCE)
        self.assertIn("SendReady", SOURCE)
        self.assertIn("SendClosed", SOURCE)
        self.assertIn("CreateBrowserSync", SOURCE)
        self.assertIn("CloseBrowser(true)", SOURCE)

    def test_no_runtime_download_or_backend_fallback(self) -> None:
        self.assertNotIn("URLDownloadToFile", SOURCE)
        self.assertNotIn("WebView2", SOURCE)
        self.assertNotIn("webkit", SOURCE.lower())
        self.assertNotIn("wry", SOURCE.lower())
        self.assertNotIn("browser_subprocess_path", SOURCE)


if __name__ == "__main__":
    unittest.main()
