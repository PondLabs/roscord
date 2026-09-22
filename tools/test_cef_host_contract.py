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
MEDIA_RUST = (ROOT / "rust" / "rust" / "src" / "browser_media.rs").read_text(
    encoding="utf-8"
)
MEDIA_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "media_permission.dart"
).read_text(encoding="utf-8")
BROWSER_RUNTIME_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "browser_runtime.dart"
).read_text(encoding="utf-8")
BROWSER_RUNTIME_RUST = (
    ROOT / "rust" / "rust" / "src" / "browser_runtime.rs"
).read_text(encoding="utf-8")
MEDIA_DOC = (ROOT / "docs" / "cef-browser-runtime-media.md").read_text(
    encoding="utf-8"
)
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
EMBEDDED_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "embedded_browser_surface.dart"
).read_text(encoding="utf-8")
STANDALONE_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "standalone_browser_surface.dart"
).read_text(encoding="utf-8")


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
        self.assertIn("SetAsChild", SOURCE)
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

    def test_media_and_capture_permissions_are_mediated(self) -> None:
        for token in (
            "OnRequestMediaAccessPermission",
            "GetPermissionHandler",
            "CefPermissionHandler",
            "CefMediaAccessCallback",
            "CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE",
            "CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE",
            "CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE",
            "CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE",
            "callback->Cancel()",
            "callback->Continue(",
            "OnShowPermissionPrompt",
            "OnDismissPermissionPrompt",
            "CEF_PERMISSION_RESULT_DENY",
            "SendPermissionRequest",
            '"permission_request"',
            '"permission_denied"',
            "MediaGrantKey",
            "MediaGrantCovers",
            "RememberMediaGrant",
            "ResolveMediaDecision",
            "ResolveMediaOnUi",
            "CancelPendingMediaOnUi",
            "SanitizedMediaDeniedMessage",
            "fresh consent",
            "unknown_permission_request",
        ):
            self.assertIn(token, SOURCE)
        for token in (
            "--enable-media-stream",
            "--use-fake-device-for-media-stream",
            "--use-fake-ui-for-media-stream",
        ):
            self.assertIn(token, SOURCE)

        for token in (
            "HostPermissionRegistry",
            "MediaCapability",
            "MediaPolicyView",
            "CapturePortalOutcome",
            "permission_denied",
            "capture_denied",
            "register_permission_request",
            "stored_media_grant_covers",
            "report_portal_outcome",
            "resolve_permission_command",
            "unknown_permission_request",
        ):
            self.assertIn(token, RUST_HOST_SOURCE)
        for token in (
            "--use-fake-device-for-media-stream",
            "--use-fake-ui-for-media-stream",
        ):
            self.assertIn(token, RUST_HOST_SOURCE)

        for source in (MEDIA_RUST, MEDIA_DART):
            for token in (
                "camera",
                "microphone",
                "display_video",
                "display_audio",
                "CapturePortalOutcome",
                "MediaGrantStore",
                "MediaGrantScope",
                "HostPermissionRegistry",
                "fresh consent",
            ):
                self.assertIn(token, source)
        for token in (
            "FAILURE_PERMISSION_DENIED",
            "FAILURE_CAPTURE_DENIED",
            "MediaPolicyView",
            "PermissionResolution",
            "PendingPermissionRequest",
        ):
            self.assertIn(token, MEDIA_RUST)
        self.assertIn("denies_page", MEDIA_RUST)
        self.assertIn("deniesPage", MEDIA_DART)
        for token in (
            "HostPermissionRegistry",
            "storedGrantCovers",
            "reportPortalOutcome",
            "unknown permission request",
        ):
            self.assertIn(token, MEDIA_DART)
        for token in (
            "permissionDenied",
            "captureDenied",
            "permission_denied",
            "capture_denied",
        ):
            self.assertIn(token, BROWSER_RUNTIME_DART)
        for token in ("PermissionDenied", "CaptureDenied"):
            self.assertIn(token, BROWSER_RUNTIME_RUST)
        for token in (
            "unknown_permission_request",
            "FailureKind.permissionDenied",
            "FailureKind.captureDenied",
        ):
            self.assertIn(token, DART_RUNTIME)
        for token in (
            "deny-by-default",
            "fresh consent",
            "permission_denied",
            "capture_denied",
            "ScreenCast",
            "PipeWire",
        ):
            self.assertIn(token, MEDIA_DOC)

    def test_no_unmediated_capture_path_exists(self) -> None:
        for source in (SOURCE, RUST_HOST_SOURCE, MEDIA_RUST):
            for token in (
                "XGetImage",
                "XShmGetImage",
                "XOpenDisplay",
                "xcb_image",
                "DuplicateOutput",
                "IDXGIOutputDuplication",
            ):
                self.assertNotIn(token, source)
        self.assertNotIn("URLDownloadToFile", SOURCE)
        self.assertNotIn("getDisplayMedia", SOURCE)

    def test_windows_embedded_frame_ring_is_client_owned(self) -> None:
        for token in (
            "OnPaintFrame",
            "SendFrameReady",
            "frame_pixels.assign",
            "frame_ready",
            "kFrameRingSlots",
            "next_frame_sequence",
            "bgra_premultiplied",
            "PET_VIEW",
            "ClientFrameRing",
            "EmbeddedBrowserSurface",
            "EmbeddedBrowserView",
            "Texture(textureId",
            "presentLatestAsTexture",
            "release_frame",
        ):
            self.assertIn(
                token, SOURCE + EMBEDDED_DART + BROWSER_RUNTIME_DART,
                f"missing embedded frame-ring token: {token}",
            )
        # The CEF buffer is never retained: the copy is synchronous and the
        # event carries only slot/size/stride/format/sequence.
        self.assertIn("never be retained", SOURCE)
        self.assertNotIn("CefBrowser;", EMBEDDED_DART)
        self.assertNotIn("CefFrame", EMBEDDED_DART)

    def test_windows_embedded_input_resize_focus_and_close(self) -> None:
        for token in (
            "ApplyInputOnUi",
            "ApplyResizeOnUi",
            "ApplyFocusOnUi",
            "ApplyReleaseFrame",
            "InputSurfaceTask",
            "ResizeSurfaceTask",
            "FocusSurfaceTask",
            "SendMouseClickEvent",
            "SendMouseMoveEvent",
            "SendMouseWheelEvent",
            "SendKeyEvent",
            "ImeSetComposition",
            "ImeCommitText",
            "ImeCancelComposition",
            "ImeFinishComposingText",
            "WasResized",
            "NotifyScreenInfoChanged",
            "SetFocus",
            "GetViewSize",
            "GetScreenInfo",
            "device_scale_factor",
            "ImePhase",
            "PointerKind.wheel",
            "CloseBrowser(true)",
        ):
            self.assertIn(
                token, SOURCE + EMBEDDED_DART,
                f"missing embedded input token: {token}",
            )

    def test_windows_embedded_matrix_fixture_contract(self) -> None:
        adapter = (
            ROOT / "commet" / "lib" / "client" / "matrix" / "components"
            / "widgets" / "matrix_widget_adapter.dart"
        ).read_text(encoding="utf-8")
        for token in (
            "profileKey",
            "allowedOrigins",
            "DownloadCommand",
            "ClipboardCommand",
            "UploadCommand",
            "PermissionCommand",
            "profileMismatch",
        ):
            self.assertIn(
                token,
                BROWSER_RUNTIME_DART + EMBEDDED_DART,
                f"missing matrix fixture token: {token}",
            )
        self.assertIn("commet://fixture/", SOURCE)
        self.assertIn("MatrixWidgetAdapter", adapter)
        self.assertIn("matrixWidgetBridgeInstallOperation", adapter)

    def test_windows_embedded_software_rendering_matches_contract(self) -> None:
        for token in (
            "--cef-software-rendering",
            "forceSoftwareRendering",
            "software_rendering",
            "disable-gpu",
            "disable-gpu-compositing",
            "CPU OnPaint",
        ):
            self.assertIn(
                token, SOURCE + DART_RUNTIME + EMBEDDED_DART,
                f"missing software-rendering token: {token}",
            )

    def test_windows_embedded_forbids_foreign_backends(self) -> None:
        # No foreign engine backend may be reachable: the host links only the
        # bundled runtime and the Dart presenter only builds a Flutter texture
        # or placeholder for its owned surface.
        self.assertNotIn("wry", SOURCE.lower())
        self.assertNotIn("wry", EMBEDDED_DART.lower())
        self.assertNotIn("webkit", SOURCE.lower())
        self.assertNotIn("EdgeWebView2", SOURCE)
        self.assertNotIn("CreateCoreWebView2", SOURCE)
        self.assertNotIn("desktop_webview_window", EMBEDDED_DART)
        self.assertNotIn("flutter_inappwebview", EMBEDDED_DART)
        self.assertNotIn("CefBrowser;", EMBEDDED_DART)
        self.assertIn("never selects another engine", SOURCE)
        self.assertIn("only ever builds a Flutter texture", EMBEDDED_DART)

    def test_windows_standalone_shares_host_profile_policy_and_permissions(self) -> None:
        for token in (
            "StandaloneBrowserSurface",
            "StandaloneBrowserWindow",
            "PresentationMode.standalone",
            "shares one runtime",
            "same account",
            "profileKey",
            "profileMismatch",
            "PermissionCommand",
            "DownloadCommand",
            "ClipboardCommand",
            "UploadCommand",
            "PopupCommand",
        ):
            self.assertIn(
                token, STANDALONE_DART + BROWSER_RUNTIME_DART,
                f"missing standalone sharing token: {token}",
            )
        # The host uses one ProfileManager context per account for both
        # presentations; standalone never starts a second host process.
        for token in (
            "profiles_.Open",
            "CefRequestContext::CreateContext",
            "SetAsChild",
            "owned_window",
        ):
            self.assertIn(token, SOURCE, f"missing standalone host token: {token}")
        self.assertNotIn("Process.start", STANDALONE_DART)

    def test_windows_standalone_owned_window_behavior(self) -> None:
        for token in (
            "CreateStandaloneWindow",
            "DestroyStandaloneWindow",
            "RegisterStandaloneWindowClass",
            "StandaloneWindowProc",
            "RoscordBrowserStandalone",
            "SetAsChild",
            "SetWindowPos",
            "BringWindowToTop",
            "SetForegroundWindow",
            "NotifyMoveOrResizeStarted",
            "NotifyScreenInfoChanged",
            "SendWindowChanged",
            "window_changed",
            "ApplyResizeOnUi",
            "ApplyFocusOnUi",
            "ApplyInputOnUi",
            "ImeSetComposition",
            "ImeCommitText",
            "ImeCancelComposition",
            "SendMouseClickEvent",
            "SendMouseMoveEvent",
            "SendMouseWheelEvent",
            "SendKeyEvent",
            "SetFocus",
            "CloseBrowser(true)",
            "device_scale_factor",
            "bringToFront",
            "setFocus",
            "StandaloneWindowGeometry",
        ):
            self.assertIn(
                token, SOURCE + STANDALONE_DART,
                f"missing standalone window token: {token}",
            )
        # Standalone windows never emit frames through Flutter.
        self.assertIn("never emit frames", SOURCE)
        self.assertNotIn("Texture(textureId", STANDALONE_DART)
        self.assertNotIn("frame_ready", STANDALONE_DART)
        self.assertNotIn("CefBrowser;", STANDALONE_DART)

    def test_windows_standalone_shared_state_software_and_cleanup(self) -> None:
        for token in (
            "forceSoftwareRendering",
            "--cef-software-rendering",
            "disable-gpu",
            "CPU",
            "same",
            "close",
            "CloseBrowser(true)",
            "OnBrowserClosed",
            "DestroyStandaloneWindow",
            "profiles_.Release",
        ):
            self.assertIn(
                token, SOURCE + STANDALONE_DART + DART_RUNTIME,
                f"missing standalone software/cleanup token: {token}",
            )

    def test_windows_standalone_forbids_foreign_backends(self) -> None:
        self.assertNotIn("wry", STANDALONE_DART.lower())
        self.assertNotIn("webkit", SOURCE.lower())
        self.assertNotIn("EdgeWebView2", SOURCE)
        self.assertNotIn("CreateCoreWebView2", SOURCE)
        self.assertNotIn("desktop_webview_window", STANDALONE_DART)
        self.assertNotIn("flutter_inappwebview", STANDALONE_DART)
        self.assertNotIn("SetAsPopup", SOURCE)
        self.assertIn("never selects another engine", SOURCE)
        self.assertIn("never builds a", STANDALONE_DART)


if __name__ == "__main__":
    unittest.main()
