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
RUST_HOST_SOURCE = (
    ROOT / "rust" / "rust" / "src" / "cef_host.rs"
).read_text(encoding="utf-8")
CMAKE = (HOST / "CMakeLists.txt").read_text(encoding="utf-8")
WINDOWS_CMAKE = (ROOT / "commet" / "windows" / "CMakeLists.txt").read_text(
    encoding="utf-8"
)
DART_RUNTIME = (
    ROOT / "commet" / "lib" / "browser_runtime" / "windows_browser_runtime.dart"
).read_text(encoding="utf-8")
PROFILE_RUNTIME = (ROOT / "rust" / "rust" / "src" / "browser_profile.rs").read_text(
    encoding="utf-8"
)
PROFILE_DOC = (ROOT / "docs" / "cef-browser-runtime-profiles.md").read_text(
    encoding="utf-8"
)
LIFECYCLE_RUST = (
    ROOT / "rust" / "rust" / "src" / "browser_runtime_lifecycle.rs"
).read_text(encoding="utf-8")
LIFECYCLE_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "runtime_lifecycle.dart"
).read_text(encoding="utf-8")
LINUX_RUNTIME = (
    ROOT / "rust" / "rust" / "src" / "linux_browser_runtime.rs"
).read_text(encoding="utf-8")
FILE_ACCESS_RUST = (ROOT / "rust" / "rust" / "src" / "browser_file_access.rs").read_text(
    encoding="utf-8"
)
FILE_ACCESS_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "file_access.dart"
).read_text(encoding="utf-8")
FILE_ACCESS_DOC = (ROOT / "docs" / "cef-browser-runtime-file-access.md").read_text(
    encoding="utf-8"
)
BROWSER_RUNTIME_RUST = (ROOT / "rust" / "rust" / "src" / "browser_runtime.rs").read_text(
    encoding="utf-8"
)
BROWSER_RUNTIME_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "browser_runtime.dart"
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

    def test_script_commands_execute_in_cef_and_page_messages_return_as_events(self) -> None:
        for token in (
            "BrowserRuntimeSendHandler",
            "__roscordBrowserRuntimeSend",
            "roscord_browser_runtime_send",
            "ExecuteJavaScript",
            "__roscordBrowserRuntimeReceive",
            "SendScriptComplete",
            "OnProcessMessageReceived",
            "script_message",
        ):
            self.assertIn(token, SOURCE)

    def test_matrix_protocol_vocabulary_stays_outside_cef_hosts(self) -> None:
        for source in (SOURCE, RUST_HOST_SOURCE):
            lowered = source.lower()
            for token in ("matrix", "org.matrix", "chat.commet", "fromwidget", "towidget"):
                self.assertNotIn(token, lowered)

    def test_bounded_recovery_and_observability_are_wired(self) -> None:
        for token in (
            "RuntimeState",
            "runtime_epoch",
            "event_seq",
            "FailureScope",
            "HostUnresponsive",
            "CommandOutcome",
            "MAX_AUTOMATIC_HOST_RESTARTS",
            "HEARTBEAT_TIMEOUT_MS",
            "HOST_TERMINATION_GRACE_MS",
            "FaultPoint",
        ):
            self.assertIn(token, LIFECYCLE_RUST)
        for token in (
            "RuntimeState",
            "runtimeEpoch",
            "eventSeq",
            "hostUnresponsive",
            "CommandOutcome",
            "maxAutomaticHostRestarts",
            "heartbeatTimeoutMs",
            "parseFaultPoint",
        ):
            self.assertIn(token, LIFECYCLE_DART)
        self.assertIn('"heartbeat_ack"', SOURCE)
        self.assertIn("SendHeartbeatAck", SOURCE)
        self.assertIn('GetType("request_id")', SOURCE)
        self.assertIn("SendAck(request_id)", SOURCE)
        for token in (
            "OnRenderProcessTerminated",
            "OnRenderProcessUnresponsive",
            "renderer_oom",
            "profile_locked",
        ):
            self.assertIn(token, SOURCE)
        self.assertIn("Timer.periodic", DART_RUNTIME)
        self.assertIn("retryBrowser", DART_RUNTIME)
        self.assertIn("retry_browser", LINUX_RUNTIME)
        self.assertIn("held_presentation", LINUX_RUNTIME)
        self.assertIn("beginShutdown", DART_RUNTIME)
        for token in (
            "reconnect_if_due",
            "restore_surfaces",
            "host_protocol_violation",
            "RuntimeState::Restarting",
        ):
            self.assertIn(token, LINUX_RUNTIME)

    def test_no_runtime_download_or_backend_fallback(self) -> None:
        self.assertNotIn("URLDownloadToFile", SOURCE)
        self.assertNotIn("WebView2", SOURCE)
        self.assertNotIn("webkit", SOURCE.lower())
        self.assertNotIn("wry", SOURCE.lower())
        self.assertNotIn("browser_subprocess_path", SOURCE)

    def test_account_profiles_private_contexts_and_data_transition_are_bound(self) -> None:
        self.assertIn("--profile-root", SOURCE)
        self.assertIn("ProfileManager", SOURCE)
        self.assertIn("CefRequestContext::CreateContext", SOURCE)
        self.assertIn("settings.cache_path", SOURCE)
        self.assertIn("persist_session_cookies", SOURCE)
        self.assertIn("persist_user_preferences", SOURCE)
        self.assertIn("FILE_ATTRIBUTE_REPARSE_POINT", SOURCE)
        self.assertIn("profile.manifest", SOURCE)
        self.assertIn("MoveFileExW", SOURCE)
        self.assertIn("ClearData", SOURCE)
        self.assertIn("FlushStore", SOURCE)
        self.assertIn("CloseAllConnections", SOURCE)
        self.assertIn("ClearCertificateExceptions", SOURCE)
        self.assertIn("ClearHttpAuthCredentials", SOURCE)
        self.assertIn("RejectReparseBelow", SOURCE)
        self.assertIn("SetAsPopup", SOURCE)
        self.assertIn("--profile-root=$profileRoot", DART_RUNTIME)

        self.assertIn("same_account_shares_persistent_context", PROFILE_RUNTIME)
        self.assertIn("private_contexts_are_distinct", PROFILE_RUNTIME)
        self.assertIn("missing_or_mismatched_manifests_are_quarantined", PROFILE_RUNTIME)
        self.assertIn("clear_data_requires_quiescence", PROFILE_RUNTIME)
        self.assertIn("legacy", PROFILE_DOC.lower())
        self.assertIn("quarantine", PROFILE_DOC.lower())

    def test_navigation_certificate_and_popup_policy_is_fail_closed(self) -> None:
        for token in (
            "NavigationPolicy",
            "allowed_loopback_origins",
            "allow_external_navigation",
            "PolicyAllowsInProcess",
            "EvaluateNavigation",
            "OnBeforeBrowse",
            "OnOpenURLFromTab",
            "OnCertificateError",
            "OnSelectClientCertificate",
            "callback->Cancel()",
            "callback->Select(nullptr)",
            "OnBeforePopup",
            "SendPopupRequest",
            "SendSurfaceFailure",
            "is_redirect",
            "PolicyAllowsInProcess(surface->policy, url)",
            '"popup_request"',
            '"certificate_denied"',
            '"client_certificate_denied"',
            '"outcome", std::string(outcome)',
        ):
            self.assertIn(token, SOURCE)
        self.assertNotIn("ignore_certificate_errors", SOURCE)
        self.assertNotIn("--ignore-certificate-errors", SOURCE)

    def test_file_access_clipboard_and_uploads_are_mediated(self) -> None:
        for token in (
            "OnBeforeDownload",
            "OnDownloadUpdated",
            "OnFileDialog",
            "FILE_DIALOG_OPEN",
            "GetDownloadHandler",
            "GetDialogHandler",
            "SendDownloadRequest",
            "SendClipboardRequest",
            "SendUploadRequest",
            "CancelPendingFileAccess",
            "CancelAllPendingFileAccess",
            "ResolveFileAccessCommand",
            "SanitizeDownloadName",
            "ResolveNonOverwritingLeaf",
            "AtomicCommitDownload",
            "StagedUpload",
            "AllowClipboardRead",
            "AllowClipboardWrite",
            "AllowStagedUpload",
            '"download_request"',
            '"clipboard_request"',
            '"upload_request"',
            "pending_downloads",
            "pending_clipboards",
            "pending_uploads",
        ):
            self.assertIn(token, SOURCE)
        for token in (
            "sanitizeSuggestedDownloadName",
            "resolveNonOverwritingLeaf",
            "decideClipboardRead",
            "decideClipboardWrite",
            "decideUpload",
            "PendingFileAccessRegistry",
            "cancelForNavigation",
            "cancelForClose",
            "cancelForHostLoss",
            "cancelForUnavailableUi",
            "fileAccessRequestTimeoutMs",
            "UploadDecision",
            "FileAccessCancelReason",
        ):
            self.assertIn(token, FILE_ACCESS_DART)
        for token in (
            "sanitize_suggested_download_name",
            "resolve_non_overwriting_leaf",
            "decide_clipboard_read",
            "decide_clipboard_write",
            "decide_upload",
            "PendingFileAccessRegistry",
            "cancel_for_navigation",
            "cancel_for_close",
            "cancel_for_host_loss",
            "cancel_for_unavailable_ui",
            "FILE_ACCESS_REQUEST_TIMEOUT_MS",
            "UploadDecision",
            "FileAccessKind",
        ):
            self.assertIn(token, FILE_ACCESS_RUST)
        for token in ("UploadDecision", "UploadRequest", "Upload {"):
            self.assertIn(token, BROWSER_RUNTIME_RUST)
        for token in ("UploadDecision", "UploadRequestEvent", "'upload'"):
            self.assertIn(token, BROWSER_RUNTIME_DART)
        self.assertIn("UploadRequest", LINUX_RUNTIME)
        for token in (
            "AtomicCommitDownload",
            "one-shot",
            "read-only staging",
            "CancelPendingFileAccess",
            "PendingFileAccessRegistry",
        ):
            self.assertIn(token, FILE_ACCESS_DOC)

    def test_policy_contract_is_shared_with_typed_runtime(self) -> None:
        browser_runtime = (
            ROOT / "rust" / "rust" / "src" / "browser_runtime.rs"
        ).read_text(encoding="utf-8")
        dart_runtime = (
            ROOT / "commet" / "lib" / "browser_runtime" / "browser_runtime.dart"
        ).read_text(encoding="utf-8")
        for source in (browser_runtime, dart_runtime):
            for token in (
                "allowed_loopback_origins",
                "allow_external_navigation",
                "NavigationPolicyDecision",
                "NavigationOutcome",
                "External",
            ):
                self.assertIn(token, source)


if __name__ == "__main__":
    unittest.main()
