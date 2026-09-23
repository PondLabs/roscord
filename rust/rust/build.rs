use std::env;
use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-env-changed=ROSCORD_CEF_SDK_ROOT");
    println!("cargo:rerun-if-changed=src/cef_bridge.c");

    if env::var("CARGO_CFG_TARGET_OS").ok().as_deref() != Some("linux") {
        return;
    }

    let Some(root) = env::var_os("ROSCORD_CEF_SDK_ROOT") else {
        return;
    };
    let root = PathBuf::from(root);
    if !root.join("include/capi/cef_app_capi.h").is_file() {
        panic!(
            "ROSCORD_CEF_SDK_ROOT must point at the full CEF SDK (include/capi/cef_app_capi.h missing)"
        );
    }

    cc::Build::new()
        .file("src/cef_bridge.c")
        .include(&root)
        .warnings_into_errors(true)
        .compile("roscord_cef_bridge");

    println!("cargo:rustc-cfg=roscord_cef_bridge");
    // The host opens the explicitly supplied libcef.so at runtime.  Do not
    // add a link-time CEF dependency: the dynamic loader must not search the
    // system before cef_host can enforce the locked runtime path.
    println!("cargo:rustc-link-lib=dylib=dl");
}
