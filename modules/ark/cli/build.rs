//! Finds every service that ships CLI commands (../services/<name>/cli/mod.rs)
//! and generates $OUT_DIR/services.rs, which main.rs includes:
//!
//!     #[path = "/.../services/money/cli/mod.rs"] pub mod money;
//!     pub fn all() -> Vec<&'static Service> { vec![&money::SERVICE] }
//!
//! So adding `ark service foo ...` is creating services/foo/cli/mod.rs with a
//! `pub static SERVICE: crate::service::Service`; nothing else to register.
//! The files are ordinary modules of this crate, which is what lets an editor
//! (rust-analyzer runs build scripts) check them where they live.
use std::{env, fs, path::PathBuf};

fn main() {
    let manifest = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let services = manifest.join("../services").canonicalize().expect("../services next to cli/");
    println!("cargo:rerun-if-changed={}", services.display());

    let mut entries: Vec<_> = fs::read_dir(&services).unwrap().flatten().collect();
    entries.sort_by_key(|e| e.file_name());

    let mut code = String::new();
    let mut names = Vec::new();
    for entry in entries {
        let mod_rs = entry.path().join("cli/mod.rs");
        if !mod_rs.is_file() {
            continue;
        }
        println!("cargo:rerun-if-changed={}", entry.path().join("cli").display());
        let name = entry.file_name().to_string_lossy().replace('-', "_");
        code += &format!("#[path = {:?}]\npub mod {name};\n", mod_rs.display().to_string());
        names.push(name);
    }
    code += "pub fn all() -> Vec<&'static crate::service::Service> {\n    vec![";
    for name in &names {
        code += &format!("&{name}::SERVICE, ");
    }
    code += "]\n}\n";

    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("services.rs");
    fs::write(out, code).unwrap();
}
