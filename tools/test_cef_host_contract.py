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
LINUX_EMBEDDED_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "linux_embedded_presenter.dart"
).read_text(encoding="utf-8")
LINUX_EMBEDDED_RUST = (
    ROOT / "rust" / "rust" / "src" / "browser_linux_embedded.rs"
).read_text(encoding="utf-8")
LINUX_EMBEDDED_DOC = (
    ROOT / "docs" / "cef-browser-runtime-linux-embedded.md"
).read_text(encoding="utf-8")
RUST_LIB = (ROOT / "rust" / "rust" / "src" / "lib.rs").read_text(encoding="utf-8")
DART_BARREL = (ROOT / "commet" / "lib" / "browser_runtime.dart").read_text(
    encoding="utf-8"
)
LINUX_EMBEDDED_TEST = (
    ROOT / "commet" / "unit_test" / "linux_embedded_presenter_test.dart"
).read_text(encoding="utf-8")
EMBEDDED_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "embedded_browser_surface.dart"
).read_text(encoding="utf-8")
LINUX_STANDALONE_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "linux_standalone_presenter.dart"
).read_text(encoding="utf-8")
LINUX_STANDALONE_RUST = (
    ROOT / "rust" / "rust" / "src" / "browser_linux_standalone.rs"
).read_text(encoding="utf-8")
LINUX_STANDALONE_DOC = (
    ROOT / "docs" / "cef-browser-runtime-linux-standalone.md"
).read_text(encoding="utf-8")
LINUX_STANDALONE_TEST = (
    ROOT / "commet" / "unit_test" / "linux_standalone_presenter_test.dart"
).read_text(encoding="utf-8")
FLATPAK_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "flatpak_presenter.dart"
).read_text(encoding="utf-8")
FLATPAK_RUST = (ROOT / "rust" / "rust" / "src" / "browser_flatpak.rs").read_text(
    encoding="utf-8"
)
FLATPAK_DOC = (ROOT / "docs" / "cef-browser-runtime-flatpak.md").read_text(
    encoding="utf-8"
)
FLATPAK_TEST = (
    ROOT / "commet" / "unit_test" / "flatpak_presenter_test.dart"
).read_text(encoding="utf-8")
FLATPAK_MANIFEST = (
    ROOT / "commet" / "linux" / "flatpak" / "chat.commet.commetapp.yaml"
).read_text(encoding="utf-8")
STANDALONE_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "standalone_browser_surface.dart"
).read_text(encoding="utf-8")
RECOVERY_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "surface_recovery.dart"
).read_text(encoding="utf-8")
DIAGNOSTICS_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "surface_diagnostics.dart"
).read_text(encoding="utf-8")
RECOVERY_UI_DART = (
    ROOT / "commet" / "lib" / "browser_runtime" / "recovery_surface_ui.dart"
).read_text(encoding="utf-8")
RECOVERY_TEST = (
    ROOT / "commet" / "unit_test" / "surface_recovery_test.dart"
).read_text(encoding="utf-8")
DIAGNOSTICS_TEST = (
    ROOT / "commet" / "unit_test" / "surface_diagnostics_test.dart"
).read_text(encoding="utf-8")
RECOVERY_UI_TEST = (
    ROOT / "commet" / "unit_test" / "recovery_surface_ui_test.dart"
).read_text(encoding="utf-8")
MEDIA_ADAPTER = (
    ROOT
    / "commet"
    / "lib"
    / "client"
    / "components"
    / "video_embed"
    / "media_embed_adapter.dart"
).read_text(encoding="utf-8")
QUALIFY_FLATPAK_TOOL = (ROOT / "tools" / "qualify_flatpak_artifact.py").read_text(
    encoding="utf-8"
)
FLATPAK_ARTIFACT_DOC = (
    ROOT / "docs" / "cef-browser-runtime-flatpak-artifacts.md"
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

    def test_linux_embedded_cells_use_osr_cpu_flutter_texture(self) -> None:
        for token in (
            "LinuxCompositor",
            "parseLinuxCompositor",
            "linuxEmbeddedPresentationPath",
            "osr-cpu-flutter-texture",
            "linuxEmbeddedUsesOsrCpuFrames",
            "linuxEmbeddedUsesFlutterTexture",
            "linuxEmbeddedUsesNativeChildEmbedding",
            "LinuxEmbeddedPresenter",
            "validateLinuxEmbeddedFrame",
            "presentationPath",
            "takeFrame",
        ):
            self.assertIn(token, LINUX_EMBEDDED_DART)
        for token in (
            "LinuxCompositor",
            "parse_linux_compositor",
            "EMBEDDED_PRESENTATION_PATH",
            "osr-cpu-flutter-texture",
            "uses_osr_cpu_frames",
            "uses_flutter_texture",
            "uses_native_child_embedding",
            "validate_embedded_frame",
            "resolve_embedded_backend",
        ):
            self.assertIn(token, LINUX_EMBEDDED_RUST)
        self.assertIn("browser_linux_embedded", RUST_LIB)
        self.assertIn("linux_embedded_presenter", DART_BARREL)
        for token in (
            "osr-cpu-flutter-texture",
            "forced cpu",
            "no fallback",
            "webkitgtk",
        ):
            self.assertIn(token, LINUX_EMBEDDED_DOC.lower())

    def test_linux_embedded_matches_windows_contract_without_child_embedding(
        self,
    ) -> None:
        for token in (
            "ResizeCommand",
            "FocusCommand",
            "InputCommand",
            "ReleaseFrameCommand",
            "runtime.close",
            "stale surface",
        ):
            self.assertIn(token, LINUX_EMBEDDED_DART)
        # The presenter is runtime-agnostic, so the embedded Matrix contract
        # is pinned in its fixture: same embedded spec, profile, navigation,
        # input/IME/focus/resize/DPI/close vocabulary as Windows.
        for token in (
            "PresentationMode.embedded",
            "Matrix launch builds the same embedded surface spec",
            "input, IME, focus, resize, DPI, and close round-trip",
            "profiles, navigation, and command ordering match Windows",
            "profileMismatch",
            "sequenceViolation",
            "navigationDecision",
        ):
            self.assertIn(token, LINUX_EMBEDDED_TEST)
        self.assertIn("cpuOsr", LINUX_EMBEDDED_DART)
        self.assertIn("CpuOsr", LINUX_EMBEDDED_RUST)
        self.assertIn("forced_cpu_rendering", LINUX_EMBEDDED_RUST)
        # Both presenters document that native child embedding is absent;
        # only embedding *APIs* are forbidden in the sources.
        for source in (LINUX_EMBEDDED_DART, LINUX_EMBEDDED_RUST):
            self.assertIn("native child embedding", source.lower().replace("_", " "))
            for token in ("GDK_BACKEND", "gtk_window", "GtkWidget"):
                self.assertNotIn(token, source)

    def test_linux_embedded_has_no_fallback_engine(self) -> None:
        for token in (
            "isForbiddenEmbeddedBackend",
            "assertNoFallbackEngine",
            "resolveLinuxEmbeddedBackend",
            "cef-osr-cpu",
            "webkit",
            "wry",
            "system cef",
            "external chromium",
            "WebView2",
            "unowned browser",
        ):
            self.assertIn(token.lower(), LINUX_EMBEDDED_DART.lower())
        for token in (
            "is_forbidden_backend",
            "assert_no_fallback_engine",
            "resolve_embedded_backend",
            "cef-osr-cpu",
            "webkit",
            "wry",
            "system cef",
            "external chromium",
            "webview2",
            "unowned browser",
        ):
            self.assertIn(token.lower(), LINUX_EMBEDDED_RUST.lower())
        for source in (LINUX_EMBEDDED_DART, LINUX_EMBEDDED_RUST):
            lowered = source.lower()
            # The forbidden list itself names the engines only to deny them;
            # no fallback may be imported, instantiated, or registered.
            self.assertNotIn("import 'package:webview", lowered)
            self.assertNotIn("desktop_webview_window", lowered)
            self.assertNotIn("system cef lookup", lowered)
            self.assertNotIn("external cef download", lowered)

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

    def test_linux_standalone_cells_use_owned_window_osr_cpu(self) -> None:
        for token in (
            "LinuxStandaloneCompositor",
            "parseLinuxStandaloneCompositor",
            "linuxStandalonePresentationPath",
            "osr-cpu-owned-window",
            "linuxStandaloneUsesOsrCpuFrames",
            "linuxStandaloneUsesOwnedWindow",
            "linuxStandaloneUsesNativeChildEmbedding",
            "LinuxStandalonePresenter",
            "validateLinuxStandaloneFrame",
            "validateLinuxStandaloneGeometry",
            "presentationPath",
            "takeFrame",
            "bringToFront",
            "sendToBack",
        ):
            self.assertIn(token, LINUX_STANDALONE_DART)
        for token in (
            "LinuxCompositor",
            "parse_linux_compositor",
            "STANDALONE_PRESENTATION_PATH",
            "osr-cpu-owned-window",
            "uses_osr_cpu_frames",
            "uses_owned_window",
            "uses_native_child_embedding",
            "validate_standalone_frame",
            "validate_standalone_geometry",
            "resolve_standalone_backend",
            "StandaloneWindowState",
        ):
            self.assertIn(token, LINUX_STANDALONE_RUST)
        self.assertIn("browser_linux_standalone", RUST_LIB)
        self.assertIn("linux_standalone_presenter", DART_BARREL)
        for token in (
            "osr-cpu-owned-window",
            "forced cpu",
            "no fallback",
            "webkitgtk",
        ):
            self.assertIn(token, LINUX_STANDALONE_DOC.lower())

    def test_linux_standalone_owned_window_behavior_on_both_compositors(
        self,
    ) -> None:
        for token in (
            "LinuxStandaloneGeometry",
            "LinuxStandaloneZOrder",
            "ResizeCommand",
            "FocusCommand",
            "InputCommand",
            "ReleaseFrameCommand",
            "runtime.close",
            "stale surface",
            "ownedPopupSpec",
            "noteHostLost",
            "isReconnecting",
        ):
            self.assertIn(token, LINUX_STANDALONE_DART)
        for token in (
            "PresentationMode.standalone",
            "Matrix launch builds the same spec except presentation",
            "owned-window geometry, z-order, focus",
            "profiles, navigation, and command ordering match embedded",
            "profileMismatch",
            "sequenceViolation",
            "navigationDecision",
            "host loss",
        ):
            self.assertIn(token, LINUX_STANDALONE_TEST)
        self.assertIn("cpuOsr", LINUX_STANDALONE_DART)
        self.assertIn("CpuOsr", LINUX_STANDALONE_RUST)
        self.assertIn("forced_cpu_rendering", LINUX_STANDALONE_RUST)
        for source in (LINUX_STANDALONE_DART, LINUX_STANDALONE_RUST):
            self.assertIn("native child embedding", source.lower().replace("_", " "))
            self.assertIn("unowned", source.lower())
            for token in ("GDK_BACKEND", "gtk_window", "GtkWidget"):
                self.assertNotIn(token, source)

    def test_linux_standalone_shares_account_state_without_new_host(
        self,
    ) -> None:
        # Standalone reuses the same four-operation seam, profile key, and
        # policy vocabulary as embedded; no second host is started.
        for token in (
            "ProfileKey('account-record-1')",
            "PresentationMode.standalone",
            "allowExternalNavigation",
            "FakeBrowserRuntime",
        ):
            self.assertIn(token, LINUX_STANDALONE_TEST)
        self.assertIn("same_account", RUST_HOST_SOURCE + BROWSER_RUNTIME_RUST)
        self.assertIn("Standalone", RUST_HOST_SOURCE)

    def test_linux_standalone_has_no_child_embedding_or_unowned_window(
        self,
    ) -> None:
        for token in (
            "isForbiddenStandaloneBackend",
            "assertNoStandaloneFallback",
            "resolveLinuxStandaloneBackend",
            "cef-osr-cpu",
            "native child",
            "child embedding",
            "unowned window",
            "unowned browser",
            "webkit",
            "wry",
            "system cef",
            "external chromium",
            "WebView2",
        ):
            self.assertIn(token.lower(), LINUX_STANDALONE_DART.lower())
        for token in (
            "is_forbidden_backend",
            "assert_no_fallback_engine",
            "resolve_standalone_backend",
            "cef-osr-cpu",
            "native child",
            "child embedding",
            "unowned window",
            "unowned browser",
            "webkit",
            "wry",
            "system cef",
            "external chromium",
            "webview2",
        ):
            self.assertIn(token.lower(), LINUX_STANDALONE_RUST.lower())
        for source in (LINUX_STANDALONE_DART, LINUX_STANDALONE_RUST):
            lowered = source.lower()
            self.assertNotIn("import 'package:webview", lowered)
            self.assertNotIn("desktop_webview_window", lowered)
            self.assertNotIn("system cef lookup", lowered)
            self.assertNotIn("external cef download", lowered)

    def test_flatpak_presentations_load_without_host_engines_or_gpu(self) -> None:
        for token in (
            "FlatpakCompositor",
            "parseFlatpakCompositor",
            "flatpakEmbeddedPresentationPath",
            "flatpakStandalonePresentationPath",
            "flatpakPresentationPath",
            "osr-cpu-flutter-texture",
            "osr-cpu-owned-window",
            "flatpakUsesOsrCpuFrames",
            "flatpakUsesBundledCef",
            "flatpakUsesHostCef",
            "flatpakUsesHostWebKitGtk",
            "flatpakWorksWithoutGpu",
            "FlatpakEmbeddedPresenter",
            "FlatpakStandalonePresenter",
            "validateFlatpakFrame",
            "resolveFlatpakCefBundlePath",
            "flatpakCefBundleRoot",
            "/app",
            "takeFrame",
        ):
            self.assertIn(token, FLATPAK_DART)
        for token in (
            "FlatpakCompositor",
            "parse_flatpak_compositor",
            "FLATPAK_EMBEDDED_PRESENTATION_PATH",
            "FLATPAK_STANDALONE_PRESENTATION_PATH",
            "osr-cpu-flutter-texture",
            "osr-cpu-owned-window",
            "uses_osr_cpu_frames",
            "uses_bundled_cef",
            "uses_host_cef",
            "uses_host_webkitgtk",
            "works_without_gpu",
            "validate_flatpak_frame",
            "resolve_cef_bundle_path",
            "FLATPAK_CEF_BUNDLE_ROOT",
            "/app",
        ):
            self.assertIn(token, FLATPAK_RUST)
        self.assertIn("browser_flatpak", RUST_LIB)
        self.assertIn("flatpak_presenter", DART_BARREL)
        for token in (
            "both presentations load without host cef",
            "bundled",
            "/app",
            "without host",
            "or gpu",
        ):
            self.assertIn(token, FLATPAK_TEST.lower())
        for token in (
            "osr-cpu-flutter-texture",
            "osr-cpu-owned-window",
            "/app",
            "without host cef",
            "host webkitgtk",
        ):
            self.assertIn(token, FLATPAK_DOC.lower())

    def test_flatpak_sandbox_and_least_privilege_permissions_are_proven(self) -> None:
        for token in (
            "flatpakUsesUserNamespaceSandbox",
            "flatpakUsesSeccompSandbox",
            "validateFlatpakFinishArgs",
            "isForbiddenFlatpakFinishArg",
            "--device=dri",
            "least-privilege",
            "least_privilege",
        ):
            self.assertIn(token.lower(), (FLATPAK_DART + FLATPAK_RUST).lower())
        for token in (
            "uses_user_namespace_sandbox",
            "uses_seccomp_sandbox",
            "validate_finish_args",
            "is_forbidden_finish_arg",
        ):
            self.assertIn(token, FLATPAK_RUST)
        # The shipped manifest carries the hardened least-privilege set.
        for token in (
            "--share=ipc",
            "--socket=fallback-x11",
            "--socket=wayland",
            "--socket=pulseaudio",
            "--share=network",
            "--device=dri",
        ):
            self.assertIn(token, FLATPAK_MANIFEST)
        self.assertNotIn("--device=all", FLATPAK_MANIFEST)
        self.assertNotIn("filesystem=host", FLATPAK_MANIFEST)
        self.assertNotIn("filesystem=home", FLATPAK_MANIFEST)
        self.assertIn("org.gnome.Platform", FLATPAK_MANIFEST)
        self.assertIn("48", FLATPAK_MANIFEST)
        self.assertIn("x86_64", FLATPAK_MANIFEST)
        self.assertIn("/app", FLATPAK_MANIFEST)

    def test_flatpak_capture_uses_portals_and_denial_keeps_the_sandbox(self) -> None:
        for token in (
            "flatpakRequiresPortals",
            "flatpakUsesPortalForCapability",
            "flatpakPortalCapabilities",
            "assertFlatpakPortalDenialKeepsSandbox",
            "flatpakPortalDenialBroadensSandbox",
            "camera",
            "microphone",
            "display_video",
            "portal",
        ):
            self.assertIn(token.lower(), FLATPAK_DART.lower())
        for token in (
            "requires_portals",
            "uses_portal_for_capability",
            "assert_portal_denial_keeps_sandbox",
            "portal_denial_broadens_sandbox",
            "CapturePortalOutcome",
        ):
            self.assertIn(token.lower(), (FLATPAK_RUST + MEDIA_RUST).lower())
        for token in (
            "portal",
            "denial never broadens",
            "ScreenCast",
            "PipeWire",
        ):
            self.assertIn(token.lower(), FLATPAK_DOC.lower())
        for token in (
            "use portals",
            "denial never broadens",
            "portal",
        ):
            self.assertIn(token, FLATPAK_TEST.lower())

    def test_flatpak_cpu_rendering_remains_fully_functional(self) -> None:
        for token in (
            "FlatpakRendering",
            "cpuOsr",
            "flatpakForcedCpuRendering",
            "resolveFlatpakBackend",
            "cef-osr-cpu",
            "validateFlatpakStandaloneGeometry",
            "bringToFront",
            "sendToBack",
        ):
            self.assertIn(token, FLATPAK_DART)
        for token in (
            "FlatpakRendering",
            "CpuOsr",
            "forced_cpu_rendering",
            "resolve_flatpak_backend",
            "cef-osr-cpu",
            "FlatpakWindowGeometry",
            "FlatpakWindowState",
        ):
            self.assertIn(token, FLATPAK_RUST)
        for token in (
            "cpu rendering remains fully functional",
            "forced cpu",
            "osr",
        ):
            self.assertIn(token, FLATPAK_TEST.lower())
        self.assertIn("cpu", FLATPAK_DOC.lower())

    def test_flatpak_has_no_child_embedding_broadening_or_host_filesystem(
        self,
    ) -> None:
        for token in (
            "isForbiddenFlatpakBackend",
            "assertNoFlatpakFallback",
            "resolveFlatpakBackend",
            "cef-osr-cpu",
            "native child",
            "child embedding",
            "unowned window",
            "unowned browser",
            "host cef",
            "host webkit",
            "webkit",
            "wry",
            "system cef",
            "external chromium",
            "WebView2",
        ):
            self.assertIn(token.lower(), FLATPAK_DART.lower())
        for token in (
            "is_forbidden_backend",
            "assert_no_fallback_engine",
            "resolve_flatpak_backend",
            "cef-osr-cpu",
            "native child",
            "child embedding",
            "unowned window",
            "host cef",
            "webkit",
            "wry",
            "system cef",
            "external chromium",
            "webview2",
        ):
            self.assertIn(token.lower(), FLATPAK_RUST.lower())
        for token in (
            "isFlatpakHostFilesystemPath",
            "assertNoFlatpakHostFilesystemAccess",
            "isFlatpakDynamicBroadening",
            "assertNoFlatpakDynamicBroadening",
            "flatpak-spawn",
            "host filesystem",
        ):
            self.assertIn(token.lower(), (FLATPAK_DART + FLATPAK_RUST).lower())
        for source in (FLATPAK_DART, FLATPAK_RUST):
            lowered = source.lower()
            self.assertNotIn("import 'package:webview", lowered)
            self.assertNotIn("desktop_webview_window", lowered)
            self.assertNotIn("system cef lookup", lowered)
            self.assertNotIn("external cef download", lowered)
            for token in ("GDK_BACKEND", "gtk_window", "GtkWidget"):
                self.assertNotIn(token, source)
        for token in (
            "no native child embedding",
            "dynamic broadening",
            "host filesystem",
        ):
            self.assertIn(token, FLATPAK_TEST.lower())
            self.assertIn(token, FLATPAK_DOC.lower())

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

    def test_recovery_restores_declarative_state_without_replay(self) -> None:
        for token in (
            "SurfaceRecoveryCoordinator",
            "SurfaceRecoveryRegistry",
            "restoreOrder",
            "declarativeSnapshots",
            "isSideEffectingCommand",
            "isIdempotentPresentationCommand",
            "shouldReplayCommand",
            "shutdownDrainOrder",
            "SurfaceHostLossTracker",
        ):
            self.assertIn(token, RECOVERY_DART)
        for token in (
            "stable",
            "never replayed",
            "close always wins",
        ):
            self.assertIn(token.lower(), RECOVERY_DART.lower())
        for token in (
            "noteHostLost",
            "isReconnecting",
            "noteRestored",
        ):
            for source in (
                EMBEDDED_DART,
                STANDALONE_DART,
                LINUX_EMBEDDED_DART,
                LINUX_STANDALONE_DART,
                FLATPAK_DART,
                MEDIA_ADAPTER,
            ):
                self.assertIn(token, source, f"missing {token}")
        self.assertIn("surface_recovery", DART_BARREL)
        self.assertIn("restore plan is in stable", RECOVERY_TEST.lower())

    def test_renderer_gpu_budgets_and_terminal_states_are_shared(self) -> None:
        for token in (
            "maxRendererRecoveries",
            "maxGpuFailures",
            "gpuDisabled",
            "surfaceRecovering",
            "surfaceRestored",
            "surfaceFailed",
        ):
            self.assertIn(token, RECOVERY_DART + LIFECYCLE_DART)
        self.assertIn("surface-scoped", RECOVERY_DART.lower())
        self.assertIn("degrades to cpu", (RECOVERY_DART + RECOVERY_TEST).lower())

    def test_recovery_ui_is_accessible(self) -> None:
        for token in (
            "ReconnectingBrowserOverlay",
            "CrashedSurfaceCard",
            "RuntimeUnavailableCard",
            "Reconnecting browser",
            "This embedded page crashed. Retry",
            "Graphics unavailable. Retry",
            "Embedded browser unavailable. Retry browser",
            "Copy diagnostic ID",
            "liveRegion",
        ):
            self.assertIn(token, RECOVERY_UI_DART)
        self.assertIn("recovery_surface_ui", DART_BARREL)
        for forbidden in (
            "CefBrowser",
            "GetNamedPipeClientProcessId",
        ):
            self.assertNotIn(forbidden, RECOVERY_UI_DART)

    def test_diagnostics_are_consent_gated_rate_limited_and_redacted(
        self,
    ) -> None:
        for token in (
            "DiagnosticConsent",
            "hashProfileKey",
            "diagnosticOrigin",
            "redactDiagnosticMessage",
            "DiagnosticId",
            "RateLimitedDiagnosticStore",
            "tryCapture",
            "tryUpload",
            "copyDiagnosticId",
            "wouldExceedDiskBudget",
        ):
            self.assertIn(token, DIAGNOSTICS_DART)
        self.assertIn("surface_diagnostics", DART_BARREL)
        self.assertIn("consent", DIAGNOSTICS_DART.lower())
        self.assertIn("rate", DIAGNOSTICS_DART.lower())
        self.assertIn("redact", DIAGNOSTICS_DART.lower())

    def test_clean_close_drains_without_orphaning(self) -> None:
        self.assertIn("shutdownDrainOrder", RECOVERY_DART)
        self.assertIn("close always wins", RECOVERY_DART.lower())
        self.assertIn("clean stop", RECOVERY_DART.lower())
        self.assertIn("close", MEDIA_ADAPTER.lower())
        self.assertIn("shutdown", RECOVERY_TEST.lower())

    def test_flatpak_artifact_staging_covers_the_locked_payload(self) -> None:
        # The Flatpak files root carries the flattened linux-x64 runtime
        # under cef/ (/app at runtime); the offline qualification tool
        # enforces the same set against built Flatpak artifacts.
        for token in (
            "libcef.so",
            "chrome-sandbox",
            "libEGL.so",
            "libGLESv2.so",
            "libvk_swiftshader.so",
            "libvulkan.so.1",
            "vk_swiftshader_icd.json",
            "v8_context_snapshot.bin",
        ):
            self.assertIn(token, QUALIFY_FLATPAK_TOOL, f"qualifier is missing: {token}")
        # Resource pak inputs are lock-driven; they must appear across the
        # qualifier doc/layout, the lock, and the artifact doc.
        for token in (
            "chrome_100_percent.pak",
            "chrome_200_percent.pak",
            "icudtl.dat",
            "resources.pak",
            "en-US.pak",
        ):
            self.assertIn(
                token,
                QUALIFY_FLATPAK_TOOL + CEF_LOCK + FLATPAK_ARTIFACT_DOC,
                f"staging is missing: {token}",
            )
        for token in (
            "find_cef_payload",
            "check_staged",
            "check_hashes",
            "libcef.so",
            "/app",
        ):
            self.assertIn(token, QUALIFY_FLATPAK_TOOL)
        self.assertIn("qualify_flatpak_artifact", FLATPAK_ARTIFACT_DOC)
        self.assertIn("/app/cef/libcef.so", FLATPAK_DART + FLATPAK_RUST)
        self.assertIn("cef", FLATPAK_ARTIFACT_DOC)

    def test_flatpak_artifact_manifests_notices_sbom_and_signatures(self) -> None:
        for token in (
            "check_hashes",
            "check_metadata",
            "check_signatures",
            "check_manifest",
            "cef.runtime.manifest.json",
            "cef.sbom.cdx.json",
            "THIRD_PARTY_NOTICES.txt",
            "cef.provenance.json",
            "signatures.json",
            "--require-signatures",
            "CycloneDX",
            "runtime_download",
            "bundled-release-payload",
        ):
            self.assertIn(token, QUALIFY_FLATPAK_TOOL)
        self.assertIn("OSTree", FLATPAK_ARTIFACT_DOC)
        self.assertIn("signatures.json", FLATPAK_ARTIFACT_DOC)
        self.assertIn("CycloneDX", FLATPAK_ARTIFACT_DOC)
        self.assertIn("THIRD_PARTY_NOTICES", FLATPAK_ARTIFACT_DOC)
        # The release Flatpak job qualifies the files root after it is
        # built; a qualification failure blocks the artifact.
        self.assertIn("qualify_flatpak_artifact", RELEASE_WORKFLOW)

    def test_flatpak_sandbox_manifest_portals_and_denial_pass(self) -> None:
        # Least-privilege finish-args plus portal mediation with fail-closed
        # denial are proven by the presenter suites and re-checked by the
        # artifact qualifier against the real manifest.
        for token in (
            "REQUIRED_FINISH_ARGS",
            "FORBIDDEN_FINISH_ARG_FRAGMENTS",
            "check_sandbox_helpers",
            "--device=all",
            "flatpak-spawn",
            "--no-sandbox",
        ):
            self.assertIn(token, QUALIFY_FLATPAK_TOOL)
        for token in (
            "--share=ipc",
            "--socket=fallback-x11",
            "--socket=wayland",
            "--socket=pulseaudio",
            "--share=network",
            "--device=dri",
        ):
            self.assertIn(token, FLATPAK_MANIFEST)
            self.assertIn(token, QUALIFY_FLATPAK_TOOL)
        self.assertNotIn("--device=all", FLATPAK_MANIFEST)
        for token in (
            "flatpakUsesPortalForCapability",
            "assertFlatpakPortalDenialKeepsSandbox",
            "CapturePortalOutcome",
        ):
            self.assertIn(token, FLATPAK_DART + FLATPAK_RUST + MEDIA_RUST)
        self.assertIn("denial", FLATPAK_ARTIFACT_DOC.lower())
        self.assertIn("never broadens", FLATPAK_ARTIFACT_DOC.lower())
        self.assertIn("portal", FLATPAK_ARTIFACT_DOC.lower())

    def test_flatpak_surfaces_run_from_the_bundle_without_downloads(self) -> None:
        # Embedded and standalone both resolve only under /app via the
        # BrowserRuntime seam; no surface may reach a host CEF, a download,
        # or a foreign engine.
        for token in (
            "check_no_foreign_backends",
            "webkitgtk",
            "desktop_webview_window",
            "cef_binary_",
            "/run/host",
        ):
            self.assertIn(token.lower(), QUALIFY_FLATPAK_TOOL.lower())
        self.assertIn("/app", FLATPAK_DART)
        self.assertIn("/app", FLATPAK_RUST)
        self.assertIn("resolveFlatpakCefBundlePath", FLATPAK_DART)
        self.assertIn("isHostCefPath", FLATPAK_DART)
        self.assertIn("isHostWebKitGtkPath", FLATPAK_DART)
        self.assertNotIn("cef-builds.spotifycdn.com", FLATPAK_DART)
        self.assertNotIn("cef-builds.spotifycdn.com", FLATPAK_RUST)
        self.assertIn("no host cef", FLATPAK_ARTIFACT_DOC.lower())

    def test_flatpak_forced_cpu_remains_functional(self) -> None:
        for token in (
            "check_cpu_fallback",
            "libvk_swiftshader.so",
            "libEGL.so",
            "libGLESv2.so",
            "cef-osr-cpu",
        ):
            self.assertIn(token, QUALIFY_FLATPAK_TOOL + FLATPAK_DART + FLATPAK_RUST)
        self.assertIn("cpu", FLATPAK_ARTIFACT_DOC.lower())
        self.assertIn("forced CPU", FLATPAK_ARTIFACT_DOC)


if __name__ == "__main__":
    unittest.main()
