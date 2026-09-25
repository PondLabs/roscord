fn main() {
    // cef_host opens the locked libcef.so and the CEF engine at runtime, from
    // paths it has validated; nothing CEF is linked or compiled here.
    if std::env::var("CARGO_CFG_TARGET_OS").ok().as_deref() == Some("linux") {
        println!("cargo:rustc-link-lib=dylib=dl");
    }
}
