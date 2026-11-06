//! What ImageMagick makes of a picture, told which decoder to use rather
//! than left to guess: the picture as a PNG (sync.rs), and cropped to a
//! circle for desktops that draw it square (COSMIC's login and lock
//! screens): a SIZE×SIZE PNG, the middle of the picture, transparent
//! outside the circle, made once per new picture (state.rs).
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

const SIZE: u32 = 256;

/// The first frame of a picture `decoder` reads, as a PNG.
pub fn png(magick: &Path, decoder: &str, bytes: &[u8]) -> Result<Vec<u8>, String> {
    let args = [format!("{decoder}:-[0]"), "-auto-orient".into(), "-strip".into(), "png:-".into()];
    run(magick, &args, bytes)
}

/// A PNG cropped to a circle.
pub fn circle(magick: &Path, png: &[u8]) -> Result<Vec<u8>, String> {
    let (s, r) = (SIZE.to_string(), (SIZE as f64 - 1.0) / 2.0);
    let size = format!("{s}x{s}");
    let args = [
        "png:-".into(),
        "-resize".into(),
        format!("{size}^"),
        "-gravity".into(),
        "center".into(),
        "-extent".into(),
        size.clone(),
        "(".into(),
        "-size".into(),
        size,
        "xc:black".into(),
        "-fill".into(),
        "white".into(),
        "-draw".into(),
        format!("circle {r},{r} {r},0"),
        ")".into(),
        "-alpha".into(),
        "off".into(),
        "-compose".into(),
        "CopyOpacity".into(),
        "-composite".into(),
        "-strip".into(),
        "-depth".into(),
        "8".into(),
        "png:-".into(),
    ];
    run(magick, &args, png)
}

fn run(magick: &Path, args: &[String], bytes: &[u8]) -> Result<Vec<u8>, String> {
    let mut child = Command::new(magick)
        .args(args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("running {}: {e}", magick.display()))?;
    // ImageMagick reads all of it before it writes anything, so this cannot
    // block on a full stdout.
    let written = child.stdin.take().unwrap().write_all(bytes);
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    if !out.status.success() || written.is_err() || out.stdout.is_empty() {
        return Err(String::from_utf8_lossy(&out.stderr).trim().to_string());
    }
    Ok(out.stdout)
}
