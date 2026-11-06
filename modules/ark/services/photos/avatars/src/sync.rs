//! Makes the directory match Immich: <name>.png holds the picture of
//! whoever has that username, if they have an Immich account with one, and
//! nothing else is there. Always PNG, whatever Immich keeps (its cropper
//! has uploaded PNG and WebP): every service takes PNG, not all of them
//! WebP (Nextcloud's user_oidc takes only JPEG, PNG and GIF).
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use crate::config::Config;
use crate::pg::Conn;
use crate::state::Picture;
use crate::{image, Result};

/// The kinds of picture taken, by extension, and the ImageMagick decoder
/// for each.
const KINDS: [(&str, &str); 5] = [("png", "png"), ("jpg", "jpeg"), ("jpeg", "jpeg"), ("webp", "webp"), ("gif", "gif")];

const PICTURES: &str = r#"SELECT email, "profileImagePath" FROM "user" WHERE "deletedAt" IS NULL"#;

/// Everyone whose picture it could decide on, for the long poll (state.rs).
pub fn sync(config: &Config, conn: &mut Conn) -> Result<HashMap<String, Option<Picture>>> {
    let mut pictures = HashMap::new();
    for row in conn.query(PICTURES)? {
        if let [Some(mail), Some(path)] = &row[..] {
            if !path.is_empty() {
                pictures.insert(mail.to_lowercase(), path.clone());
            }
        }
    }

    let mut found = HashMap::new();
    for person in &config.persons {
        let to = config.dir.join(format!("{}.png", person.name));
        let picture = match pictures.get(&person.mail.to_lowercase()) {
            Some(path) => match copy(config, &person.name, Path::new(path)) {
                Ok(picture) => picture,
                // Leave what was there: Immich may be between two writes.
                Err(e) => {
                    eprintln!("photos-avatars: {}: {path}: {e}", person.name);
                    continue;
                }
            },
            None => None,
        };
        if picture.is_none() {
            remove(&to, &person.name)?;
        }
        found.insert(person.name.clone(), picture);
    }

    // Anyone no longer configured, anything left half written, and what
    // older versions kept under other extensions.
    for entry in fs::read_dir(&config.dir)? {
        let path = entry?.path();
        let name = path.file_name().and_then(|s| s.to_str()).unwrap_or("");
        if !config.persons.iter().any(|p| name == format!("{}.png", p.name)) {
            remove(&path, name)?;
        }
    }
    Ok(found)
}

/// Writes `from` as <name>.png unless it already holds the same bytes; None
/// for a kind it does not take.
fn copy(config: &Config, name: &str, from: &Path) -> Result<Option<Picture>> {
    let ext = from.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let Some(&(_, decoder)) = KINDS.iter().find(|(e, _)| *e == ext) else {
        eprintln!("photos-avatars: {name}: {} is not a kind it takes", from.display());
        return Ok(None);
    };
    let original = fs::read(from)?;
    let png = match decoder {
        "png" => original.clone(),
        _ => image::png(&config.magick, decoder, &original)?,
    };
    let to = config.dir.join(format!("{name}.png"));
    if fs::read(&to).ok().as_deref() != Some(&png[..]) {
        // Renamed into place, so nginx never serves half a picture.
        let tmp = config.dir.join(format!(".{name}.tmp"));
        fs::write(&tmp, &png)?;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o644))?;
        fs::rename(&tmp, &to)?;
        eprintln!("photos-avatars: {name}: {}", from.display());
    }
    Ok(Some(Picture::new(&original, png)))
}

fn remove(path: &Path, name: &str) -> Result<()> {
    match fs::remove_file(path) {
        Ok(()) => {
            eprintln!("photos-avatars: {name}: removed {}", path.display());
            Ok(())
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("removing {}: {e}", path.display()).into()),
    }
}
