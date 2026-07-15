use std::time::{SystemTime, UNIX_EPOCH};

fn main() {
    println!("cargo:rerun-if-env-changed=SOURCE_DATE_EPOCH");

    let build_epoch = std::env::var("SOURCE_DATE_EPOCH")
        .map(|value| {
            value.parse::<u64>().unwrap_or_else(|_| {
                panic!("SOURCE_DATE_EPOCH must be a non-negative Unix timestamp, got {value:?}")
            })
        })
        .unwrap_or_else(|_| {
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("system clock is before the Unix epoch")
                .as_secs()
        });
    println!("cargo:rustc-env=PIXIV_SLIDES_BUILD_EPOCH={build_epoch}");

    tauri_build::build()
}
