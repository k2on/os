//! photos-avatars: everyone's Immich profile picture, as a file named
//! after their username, for the `picture` claim Kanidm hands every
//! service (../../default.nix).
//!
//!   photos-avatars <config.json>
//!
//! Immich's own database says who has which picture, so this needs no API
//! key: it connects as Immich's role on the local socket, puts a trigger on
//! Immich's user table that NOTIFYs when an address, a picture or a
//! deletion changes, and copies the pictures again whenever it fires
//! (sync.rs). Everything is synced when it connects, so whatever changed
//! while it was down is caught up, and again every `recheckSeconds`, when
//! the trigger is also put back in case a migration of Immich's dropped it.
//! When the connection goes, it connects again.
//!
//! With `listen`, devices also keep a copy of someone's picture by long
//! poll (http.rs), hearing of a change as the sync makes it, cropped to a
//! circle if they ask (image.rs).
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

mod config;
mod http;
mod image;
mod pg;
mod state;
mod sync;

pub type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

/// In a schema of its own, apart from Immich's tables. Statement-level: one
/// notification for however many rows an update touches, as the sync reads
/// them all anyway.
const INSTALL: &str = r#"
CREATE SCHEMA IF NOT EXISTS photos_avatars;
CREATE OR REPLACE FUNCTION photos_avatars.notify() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_notify('photos_avatars', '');
  RETURN NULL;
END $$;
CREATE OR REPLACE TRIGGER photos_avatars
  AFTER INSERT OR DELETE OR UPDATE OF email, "profileImagePath", "deletedAt" ON "user"
  FOR EACH STATEMENT EXECUTE FUNCTION photos_avatars.notify();
LISTEN photos_avatars;
"#;

fn run(config: &config::Config, pictures: &state::Pictures) -> Result<()> {
    let circle = |p: &state::Picture| {
        image::circle(&config.magick, &p.bytes)
            .map_err(|e| eprintln!("photos-avatars: cropping a picture to a circle: {e}"))
            .ok()
    };
    let mut conn = pg::Conn::connect(&config.socket, &config.user, &config.database)?;
    let recheck = Duration::from_secs(config.recheck_seconds);
    loop {
        conn.query(INSTALL)?;
        pictures.update(sync::sync(config, &mut conn)?, circle);
        while conn.wait(recheck)? {
            pictures.update(sync::sync(config, &mut conn)?, circle);
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let config = match &args[..] {
        [path] => config::Config::load(Path::new(path)),
        _ => Err("usage: photos-avatars <config.json>".into()),
    };
    let config = config.unwrap_or_else(|e| {
        eprintln!("photos-avatars: {e}");
        std::process::exit(1);
    });
    eprintln!("photos-avatars: {} people, into {}", config.persons.len(), config.dir.display());
    let pictures = Arc::new(state::Pictures::default());
    if let Some(listen) = config.listen.clone() {
        let persons = config.persons.iter().map(|p| p.name.clone()).collect();
        let pictures = pictures.clone();
        std::thread::spawn(move || {
            if let Err(e) = http::serve(&listen, pictures, persons) {
                eprintln!("photos-avatars: {e}");
                std::process::exit(1);
            }
        });
    }
    loop {
        if let Err(e) = run(&config, &pictures) {
            eprintln!("photos-avatars: {e}; again in 5s");
        }
        std::thread::sleep(Duration::from_secs(5));
    }
}
