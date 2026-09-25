#[cfg(target_os = "linux")]
fn main() {
    if let Err(error) = rust_lib_commet::cef_host::run(std::env::args_os()) {
        eprintln!("cef_host: {error}");
        // Chromium starts its child processes without our stderr, so a child
        // that fails would otherwise leave no trace.
        if let Some(path) = std::env::var_os("ROSCORD_CEF_HOST_LOG") {
            use std::io::Write;
            if let Ok(mut log) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path)
            {
                let args = std::env::args().collect::<Vec<_>>().join(" ");
                let _ = writeln!(log, "[{}] {error} ({args})", std::process::id());
            }
        }
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("cef_host is only available on Linux");
    std::process::exit(1);
}
