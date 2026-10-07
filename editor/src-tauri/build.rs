fn main() {
    // macOS: the window binary does not link with compact unwind info (ld rejects four of its personality
    // routines), so it is built without it.
    println!("cargo:rustc-link-arg-bin=moonsplice-studio=-Wl,-no_compact_unwind");
    tauri_build::build();
}
