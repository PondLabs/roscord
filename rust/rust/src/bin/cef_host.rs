#[cfg(target_os = "linux")]
fn main() {
    if let Err(error) = rust_lib_commet::cef_host::run(std::env::args_os()) {
        eprintln!("cef_host: {error}");
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("cef_host is only available on Linux");
    std::process::exit(1);
}
