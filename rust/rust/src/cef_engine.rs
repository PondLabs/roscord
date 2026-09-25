//! Loader and FFI for `libroscord_cef_engine.so`, the CEF half of the Linux
//! `cef_host`.
//!
//! The host validates the bundled runtime first, then opens the locked
//! `Release/libcef.so` by absolute path with `RTLD_GLOBAL`, and only then the
//! engine.  The engine has no `DT_NEEDED` entry for libcef: its CEF symbols
//! bind to the copy already loaded, so the dynamic loader never searches for
//! CEF on its own.  The C ABI is `commet/linux/cef_engine/roscord_cef_engine.h`;
//! keep the two in step (the ABI version is checked at load time).

use std::ffi::{c_char, c_int, c_void, CStr, CString, OsString};
use std::fs::symlink_metadata;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::browser_runtime::{ImePhase, InputEvent, PointerKind, SurfaceId};
use crate::cef_host::HostError;

pub const ENGINE_ABI_VERSION: u32 = 2;
pub const ENGINE_LIBRARY: &str = "libroscord_cef_engine.so";

const POINTER_DOWN: i32 = 0;
const POINTER_UP: i32 = 1;
const POINTER_MOVE: i32 = 2;
const POINTER_ENTER: i32 = 3;
const POINTER_LEAVE: i32 = 4;
const POINTER_WHEEL: i32 = 5;

const IME_START: i32 = 0;
const IME_UPDATE: i32 = 1;
const IME_COMMIT: i32 = 2;
const IME_CANCEL: i32 = 3;

const NAVIGATION_ALLOW: i32 = 0;
const NAVIGATION_CANCEL: i32 = 1;

pub const LOG_INFO: i32 = 0;
pub const LOG_WARNING: i32 = 1;
pub const LOG_ERROR: i32 = 2;

/// Receives engine callbacks.  Calls arrive on CEF threads; see the ABI
/// header for which.
pub trait EngineEvents: Send + Sync {
    /// Returns true when the navigation may proceed.
    fn before_browse(
        &self,
        surface_id: SurfaceId,
        url: &str,
        main_frame: bool,
        user_gesture: bool,
        is_redirect: bool,
    ) -> bool;
    fn open_url(&self, surface_id: SurfaceId, url: &str, user_gesture: bool);
    fn frame_ready(
        &self,
        surface_id: SurfaceId,
        buffer: &str,
        slot: u32,
        width: u32,
        height: u32,
        frame_sequence: u64,
    );
    fn browser_created(&self, surface_id: SurfaceId);
    fn browser_closed(&self, surface_id: SurfaceId);
    fn load_failed(&self, surface_id: SurfaceId, error_code: i32, url: &str);
    fn certificate_error(&self, surface_id: SurfaceId, url: &str);
    fn renderer_gone(&self, surface_id: SurfaceId, status: i32);
    fn cursor_changed(&self, surface_id: SurfaceId, cursor: &str);
    fn script_message(&self, surface_id: SurfaceId, frame_url: &str, json: &str);
    /// Returns true to cancel the request.  Only consulted when the engine
    /// was initialized with request filtering enabled.
    fn filter_request(
        &self,
        surface_id: SurfaceId,
        url: &str,
        initiator: &str,
        resource_type: i32,
    ) -> bool;
    fn log(&self, level: i32, message: &str);
}

/// Everything the engine needs to start CEF in the browser process.
pub struct EngineSettings<'a> {
    pub cef_root: &'a Path,
    pub profile_root: &'a Path,
    pub frame_namespace: &'a str,
    pub software_rendering: bool,
    pub filter_requests: bool,
    pub frame_rate: i32,
}

/// One browser to create.
pub struct BrowserOptions<'a> {
    pub url: &'a str,
    /// Persistent profile directory below the profile root; `None` for an
    /// in-memory private context.
    pub cache_path: Option<&'a Path>,
    pub width: u32,
    pub height: u32,
    pub device_scale_factor: f64,
    pub document_start_script: Option<&'a str>,
}

#[repr(C)]
struct RawCallbacks {
    context: *mut c_void,
    before_browse: unsafe extern "C" fn(*mut c_void, u64, *const c_char, i32, i32, i32) -> i32,
    open_url: unsafe extern "C" fn(*mut c_void, u64, *const c_char, i32),
    frame_ready: unsafe extern "C" fn(*mut c_void, u64, *const c_char, u32, u32, u32, u64),
    browser_created: unsafe extern "C" fn(*mut c_void, u64),
    browser_closed: unsafe extern "C" fn(*mut c_void, u64),
    load_failed: unsafe extern "C" fn(*mut c_void, u64, i32, *const c_char),
    certificate_error: unsafe extern "C" fn(*mut c_void, u64, *const c_char),
    renderer_gone: unsafe extern "C" fn(*mut c_void, u64, i32),
    cursor_changed: unsafe extern "C" fn(*mut c_void, u64, *const c_char),
    script_message: unsafe extern "C" fn(*mut c_void, u64, *const c_char, *const c_char),
    filter_request:
        unsafe extern "C" fn(*mut c_void, u64, *const c_char, *const c_char, i32) -> i32,
    log: unsafe extern "C" fn(*mut c_void, i32, *const c_char),
}

#[repr(C)]
struct RawConfig {
    abi_version: u32,
    cef_root: *const c_char,
    profile_root: *const c_char,
    frame_namespace: *const c_char,
    software_rendering: i32,
    filter_requests: i32,
    frame_rate: i32,
}

#[repr(C)]
struct RawBrowserOptions {
    url: *const c_char,
    cache_path: *const c_char,
    width: u32,
    height: u32,
    device_scale_factor: f64,
    document_start_script: *const c_char,
}

struct EngineFunctions {
    abi_version: unsafe extern "C" fn() -> u32,
    execute_process: unsafe extern "C" fn(i32, *mut *mut c_char) -> i32,
    initialize:
        unsafe extern "C" fn(i32, *mut *mut c_char, *const RawConfig, *const RawCallbacks) -> i32,
    create_browser: unsafe extern "C" fn(u64, *const RawBrowserOptions) -> i32,
    close_browser: unsafe extern "C" fn(u64),
    navigate: unsafe extern "C" fn(u64, *const c_char),
    resize: unsafe extern "C" fn(u64, u32, u32, f64),
    focus: unsafe extern "C" fn(u64, i32),
    pointer: unsafe extern "C" fn(u64, i32, f64, f64, u32, u32, f64, f64),
    key: unsafe extern "C" fn(u64, *const c_char, *const c_char, *const c_char, u32, i32),
    ime: unsafe extern "C" fn(u64, i32, *const c_char, u32, u32),
    execute_script: unsafe extern "C" fn(u64, *const c_char),
    shutdown: unsafe extern "C" fn(),
}

/// The loaded engine.  Both libraries stay loaded for the life of the
/// process: CEF cannot be unloaded once initialized.
pub struct EngineLibrary {
    functions: EngineFunctions,
}

// The engine's commands are thread-safe by contract (they post to the CEF UI
// thread), and the function pointers never change after load.
unsafe impl Send for EngineLibrary {}
unsafe impl Sync for EngineLibrary {}

impl EngineLibrary {
    /// Opens the locked libcef and the engine from explicit paths.  Both must
    /// already have been validated by the caller.
    pub fn load(cef_root: &Path, engine_path: &Path) -> Result<Self, HostError> {
        let cef = cef_root.join("Release").join("libcef.so");
        // RTLD_GLOBAL so the engine's undefined CEF symbols bind to this copy.
        let _cef_handle = open_library(&cef, libc::RTLD_NOW | libc::RTLD_GLOBAL)
            .map_err(|_| HostError::Cef("cannot load the locked libcef.so".to_owned()))?;
        let engine = open_library(engine_path, libc::RTLD_NOW | libc::RTLD_LOCAL)
            .map_err(|_| HostError::Cef("cannot load the CEF engine".to_owned()))?;
        let functions = unsafe {
            EngineFunctions {
                abi_version: resolve(engine, b"roscord_cef_engine_abi_version\0")?,
                execute_process: resolve(engine, b"roscord_cef_engine_execute_process\0")?,
                initialize: resolve(engine, b"roscord_cef_engine_initialize\0")?,
                create_browser: resolve(engine, b"roscord_cef_engine_create_browser\0")?,
                close_browser: resolve(engine, b"roscord_cef_engine_close_browser\0")?,
                navigate: resolve(engine, b"roscord_cef_engine_navigate\0")?,
                resize: resolve(engine, b"roscord_cef_engine_resize\0")?,
                focus: resolve(engine, b"roscord_cef_engine_focus\0")?,
                pointer: resolve(engine, b"roscord_cef_engine_pointer\0")?,
                key: resolve(engine, b"roscord_cef_engine_key\0")?,
                ime: resolve(engine, b"roscord_cef_engine_ime\0")?,
                execute_script: resolve(engine, b"roscord_cef_engine_execute_script\0")?,
                shutdown: resolve(engine, b"roscord_cef_engine_shutdown\0")?,
            }
        };
        let version = unsafe { (functions.abi_version)() };
        if version != ENGINE_ABI_VERSION {
            return Err(HostError::Cef(format!(
                "CEF engine ABI {version} does not match host ABI {ENGINE_ABI_VERSION}"
            )));
        }
        Ok(Self { functions })
    }

    /// Runs a CEF child process.  Returns its exit code, or `None` when the
    /// arguments are not a child invocation.
    pub fn execute_process(&self, args: &[OsString]) -> Result<Option<i32>, HostError> {
        let mut argv = CArgv::new(args)?;
        let code = unsafe { (self.functions.execute_process)(argv.argc(), argv.as_mut_ptr()) };
        Ok((code >= 0).then_some(code))
    }

    /// Starts CEF in the browser process.  `events` receives callbacks for
    /// the rest of the process's life.
    pub fn initialize(
        &self,
        program: &OsString,
        settings: &EngineSettings<'_>,
        events: Arc<dyn EngineEvents>,
    ) -> Result<(), HostError> {
        let cef_root = path_cstring(settings.cef_root)?;
        let profile_root = path_cstring(settings.profile_root)?;
        let frame_namespace = CString::new(settings.frame_namespace)
            .map_err(|_| HostError::Cef("frame namespace contains NUL".to_owned()))?;
        let config = RawConfig {
            abi_version: ENGINE_ABI_VERSION,
            cef_root: cef_root.as_ptr(),
            profile_root: profile_root.as_ptr(),
            frame_namespace: frame_namespace.as_ptr(),
            software_rendering: settings.software_rendering as i32,
            filter_requests: settings.filter_requests as i32,
            frame_rate: settings.frame_rate,
        };
        // The callback context lives for the rest of the process: CEF may call
        // back until shutdown, and the engine keeps the pointer.
        let context = Box::into_raw(Box::new(events)) as *mut c_void;
        let callbacks = RawCallbacks {
            context,
            before_browse: before_browse_trampoline,
            open_url: open_url_trampoline,
            frame_ready: frame_ready_trampoline,
            browser_created: browser_created_trampoline,
            browser_closed: browser_closed_trampoline,
            load_failed: load_failed_trampoline,
            certificate_error: certificate_error_trampoline,
            renderer_gone: renderer_gone_trampoline,
            cursor_changed: cursor_changed_trampoline,
            script_message: script_message_trampoline,
            filter_request: filter_request_trampoline,
            log: log_trampoline,
        };
        // CEF only needs the program name; the host's own arguments are not
        // Chromium switches.
        let mut argv = CArgv::new(std::slice::from_ref(program))?;
        let initialized = unsafe {
            (self.functions.initialize)(argv.argc(), argv.as_mut_ptr(), &config, &callbacks)
        };
        if initialized != 1 {
            return Err(HostError::Cef("CEF initialization was rejected".to_owned()));
        }
        Ok(())
    }

    pub fn create_browser(
        &self,
        surface_id: SurfaceId,
        options: &BrowserOptions<'_>,
    ) -> Result<(), HostError> {
        let url = CString::new(options.url)
            .map_err(|_| HostError::Runtime("navigation URL contains NUL".to_owned()))?;
        let cache_path = options.cache_path.map(path_cstring).transpose()?;
        let script = options
            .document_start_script
            .map(CString::new)
            .transpose()
            .map_err(|_| HostError::Runtime("document script contains NUL".to_owned()))?;
        let raw = RawBrowserOptions {
            url: url.as_ptr(),
            cache_path: cache_path
                .as_ref()
                .map_or(std::ptr::null(), |path| path.as_ptr()),
            width: options.width,
            height: options.height,
            device_scale_factor: options.device_scale_factor,
            document_start_script: script
                .as_ref()
                .map_or(std::ptr::null(), |script| script.as_ptr()),
        };
        let scheduled = unsafe { (self.functions.create_browser)(surface_id.0, &raw) };
        if scheduled != 1 {
            return Err(HostError::Runtime(
                "the browser could not be scheduled".to_owned(),
            ));
        }
        Ok(())
    }

    pub fn close_browser(&self, surface_id: SurfaceId) {
        unsafe { (self.functions.close_browser)(surface_id.0) }
    }

    pub fn navigate(&self, surface_id: SurfaceId, url: &str) {
        if let Ok(url) = CString::new(url) {
            unsafe { (self.functions.navigate)(surface_id.0, url.as_ptr()) }
        }
    }

    pub fn resize(&self, surface_id: SurfaceId, width: u32, height: u32, scale: f64) {
        unsafe { (self.functions.resize)(surface_id.0, width, height, scale) }
    }

    pub fn focus(&self, surface_id: SurfaceId, focused: bool) {
        unsafe { (self.functions.focus)(surface_id.0, focused as i32) }
    }

    pub fn input(&self, surface_id: SurfaceId, input: &InputEvent) {
        match input {
            InputEvent::Pointer {
                kind,
                x,
                y,
                buttons,
                delta_x,
                delta_y,
                modifiers,
            } => {
                let kind = match kind {
                    PointerKind::Down => POINTER_DOWN,
                    PointerKind::Up => POINTER_UP,
                    PointerKind::Move => POINTER_MOVE,
                    PointerKind::Enter => POINTER_ENTER,
                    PointerKind::Leave => POINTER_LEAVE,
                    PointerKind::Wheel => POINTER_WHEEL,
                };
                unsafe {
                    (self.functions.pointer)(
                        surface_id.0,
                        kind,
                        *x,
                        *y,
                        *buttons,
                        *modifiers,
                        *delta_x,
                        *delta_y,
                    )
                }
            }
            InputEvent::Keyboard {
                key,
                code,
                modifiers,
                pressed,
                text,
            } => {
                let (Ok(key), Ok(code), Ok(text)) = (
                    CString::new(key.as_str()),
                    CString::new(code.as_str()),
                    CString::new(text.as_deref().unwrap_or_default()),
                ) else {
                    return;
                };
                unsafe {
                    (self.functions.key)(
                        surface_id.0,
                        key.as_ptr(),
                        code.as_ptr(),
                        text.as_ptr(),
                        *modifiers,
                        *pressed as i32,
                    )
                }
            }
            InputEvent::Ime {
                phase,
                text,
                selection_start,
                selection_end,
            } => {
                let Ok(text) = CString::new(text.as_str()) else {
                    return;
                };
                let phase = match phase {
                    ImePhase::Start => IME_START,
                    ImePhase::Update => IME_UPDATE,
                    ImePhase::Commit => IME_COMMIT,
                    ImePhase::Cancel => IME_CANCEL,
                };
                unsafe {
                    (self.functions.ime)(
                        surface_id.0,
                        phase,
                        text.as_ptr(),
                        *selection_start,
                        *selection_end,
                    )
                }
            }
        }
    }

    pub fn execute_script(&self, surface_id: SurfaceId, script: &str) {
        if let Ok(script) = CString::new(script) {
            unsafe { (self.functions.execute_script)(surface_id.0, script.as_ptr()) }
        }
    }

    /// Closes every browser and shuts CEF down.  Must run on the thread that
    /// called [`EngineLibrary::initialize`].
    pub fn shutdown(&self) {
        unsafe { (self.functions.shutdown)() }
    }
}

/// The engine library bundled next to the host: `<exe dir>/lib/`.
pub fn bundled_engine_path() -> Result<PathBuf, HostError> {
    let executable = std::fs::read_link("/proc/self/exe")
        .map_err(|_| HostError::Cef("cannot locate the cef_host executable".to_owned()))?;
    let directory = executable
        .parent()
        .ok_or_else(|| HostError::Cef("cef_host has no parent directory".to_owned()))?;
    Ok(directory.join("lib").join(ENGINE_LIBRARY))
}

/// The engine must be a regular file owned by the user or root and not
/// writable by anyone else, like every other bundled CEF input.
pub fn validate_engine_path(path: &Path) -> Result<(), HostError> {
    let metadata = symlink_metadata(path)
        .map_err(|_| HostError::Cef("the bundled CEF engine is missing".to_owned()))?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(HostError::Cef(
            "the bundled CEF engine must be a regular file".to_owned(),
        ));
    }
    let uid = unsafe { libc::geteuid() };
    if metadata.mode() & 0o022 != 0 || (metadata.uid() != uid && metadata.uid() != 0) {
        return Err(HostError::Permission(
            "the bundled CEF engine is not owner-controlled".to_owned(),
        ));
    }
    Ok(())
}

fn open_library(path: &Path, flags: c_int) -> Result<*mut c_void, ()> {
    let path = CString::new(path.as_os_str().as_bytes()).map_err(|_| ())?;
    let handle = unsafe { libc::dlopen(path.as_ptr(), flags) };
    if handle.is_null() {
        Err(())
    } else {
        Ok(handle)
    }
}

/// Resolves one engine export as the function type `T`.
unsafe fn resolve<T: Copy>(handle: *mut c_void, name: &[u8]) -> Result<T, HostError> {
    debug_assert_eq!(std::mem::size_of::<T>(), std::mem::size_of::<*mut c_void>());
    let symbol = libc::dlsym(handle, name.as_ptr() as *const c_char);
    if symbol.is_null() {
        let name = String::from_utf8_lossy(&name[..name.len().saturating_sub(1)]);
        return Err(HostError::Cef(format!("the CEF engine lacks {name}")));
    }
    Ok(std::mem::transmute_copy::<*mut c_void, T>(&symbol))
}

fn path_cstring(path: &Path) -> Result<CString, HostError> {
    CString::new(path.as_os_str().as_bytes())
        .map_err(|_| HostError::Cef("path contains NUL".to_owned()))
}

/// A NUL-terminated C argv that owns its strings.
struct CArgv {
    _strings: Vec<CString>,
    pointers: Vec<*mut c_char>,
}

impl CArgv {
    fn new(args: &[OsString]) -> Result<Self, HostError> {
        let strings = args
            .iter()
            .map(|argument| CString::new(argument.as_bytes()))
            .collect::<Result<Vec<_>, _>>()
            .map_err(|_| HostError::Cef("CEF argument contains NUL".to_owned()))?;
        let mut pointers = strings
            .iter()
            .map(|argument| argument.as_ptr() as *mut c_char)
            .collect::<Vec<_>>();
        pointers.push(std::ptr::null_mut());
        Ok(Self {
            _strings: strings,
            pointers,
        })
    }

    fn argc(&self) -> i32 {
        (self.pointers.len() - 1) as i32
    }

    fn as_mut_ptr(&mut self) -> *mut *mut c_char {
        self.pointers.as_mut_ptr()
    }
}

unsafe fn events<'a>(context: *mut c_void) -> &'a Arc<dyn EngineEvents> {
    &*(context as *const Arc<dyn EngineEvents>)
}

unsafe fn text<'a>(value: *const c_char) -> std::borrow::Cow<'a, str> {
    if value.is_null() {
        return std::borrow::Cow::Borrowed("");
    }
    CStr::from_ptr(value).to_string_lossy()
}

/// Runs a callback without letting a panic unwind into C++.
fn guarded<R>(fallback: R, callback: impl FnOnce() -> R) -> R {
    catch_unwind(AssertUnwindSafe(callback)).unwrap_or(fallback)
}

unsafe extern "C" fn before_browse_trampoline(
    context: *mut c_void,
    surface_id: u64,
    url: *const c_char,
    main_frame: i32,
    user_gesture: i32,
    is_redirect: i32,
) -> i32 {
    guarded(NAVIGATION_CANCEL, || {
        let allowed = events(context).before_browse(
            SurfaceId(surface_id),
            &text(url),
            main_frame != 0,
            user_gesture != 0,
            is_redirect != 0,
        );
        if allowed {
            NAVIGATION_ALLOW
        } else {
            NAVIGATION_CANCEL
        }
    })
}

unsafe extern "C" fn open_url_trampoline(
    context: *mut c_void,
    surface_id: u64,
    url: *const c_char,
    user_gesture: i32,
) {
    guarded((), || {
        events(context).open_url(SurfaceId(surface_id), &text(url), user_gesture != 0)
    })
}

unsafe extern "C" fn frame_ready_trampoline(
    context: *mut c_void,
    surface_id: u64,
    buffer: *const c_char,
    slot: u32,
    width: u32,
    height: u32,
    frame_sequence: u64,
) {
    guarded((), || {
        events(context).frame_ready(
            SurfaceId(surface_id),
            &text(buffer),
            slot,
            width,
            height,
            frame_sequence,
        )
    })
}

unsafe extern "C" fn browser_created_trampoline(context: *mut c_void, surface_id: u64) {
    guarded((), || {
        events(context).browser_created(SurfaceId(surface_id))
    })
}

unsafe extern "C" fn browser_closed_trampoline(context: *mut c_void, surface_id: u64) {
    guarded((), || events(context).browser_closed(SurfaceId(surface_id)))
}

unsafe extern "C" fn load_failed_trampoline(
    context: *mut c_void,
    surface_id: u64,
    error_code: i32,
    url: *const c_char,
) {
    guarded((), || {
        events(context).load_failed(SurfaceId(surface_id), error_code, &text(url))
    })
}

unsafe extern "C" fn certificate_error_trampoline(
    context: *mut c_void,
    surface_id: u64,
    url: *const c_char,
) {
    guarded((), || {
        events(context).certificate_error(SurfaceId(surface_id), &text(url))
    })
}

unsafe extern "C" fn renderer_gone_trampoline(context: *mut c_void, surface_id: u64, status: i32) {
    guarded((), || {
        events(context).renderer_gone(SurfaceId(surface_id), status)
    })
}

unsafe extern "C" fn cursor_changed_trampoline(
    context: *mut c_void,
    surface_id: u64,
    cursor: *const c_char,
) {
    guarded((), || {
        events(context).cursor_changed(SurfaceId(surface_id), &text(cursor))
    })
}

unsafe extern "C" fn script_message_trampoline(
    context: *mut c_void,
    surface_id: u64,
    frame_url: *const c_char,
    json: *const c_char,
) {
    guarded((), || {
        events(context).script_message(SurfaceId(surface_id), &text(frame_url), &text(json))
    })
}

unsafe extern "C" fn filter_request_trampoline(
    context: *mut c_void,
    surface_id: u64,
    url: *const c_char,
    initiator: *const c_char,
    resource_type: i32,
) -> i32 {
    guarded(0, || {
        events(context).filter_request(
            SurfaceId(surface_id),
            &text(url),
            &text(initiator),
            resource_type,
        ) as i32
    })
}

unsafe extern "C" fn log_trampoline(context: *mut c_void, level: i32, message: *const c_char) {
    guarded((), || events(context).log(level, &text(message)))
}
