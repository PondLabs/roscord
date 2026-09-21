mod frb_generated;

pub mod api;
pub mod browser_runtime;
pub mod browser_runtime_lifecycle;
#[cfg(target_os = "linux")]
pub mod cef_host;
#[cfg(target_os = "linux")]
pub mod linux_browser_runtime;

// Voice DSP (noise suppression, gate, ducking). Re-exported so its C ABI
// symbols are linked into this library; Dart loads them from here.
pub use audio_dsp;

// Soundboard clip decoder (MP3/Ogg/FLAC/WAV to PCM), same C ABI arrangement.
pub use audio_decode;

// DJ music player (local file to 48 kHz stereo for the WebRTC music track),
// same C ABI arrangement.
pub use dj_audio;

#[cfg(any(target_os = "windows", target_os = "linux"))]
mod widget_runner;

#[no_mangle]
pub extern "C" fn commet_widget_runner() {
    #[cfg(any(target_os = "windows", target_os = "linux"))]
    {
        widget_runner::run();
    }
}
