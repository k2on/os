//! Files crossing the channel, both ways over Signal.
//!
//! Received: signal-cli downloads an attachment into its own data directory,
//! which the model may not read (it holds the Signal account), so the file
//! is moved into the workspace's inbox/, where the model reads it like any
//! other file (images included).
//!
//! Sent: `reply` and `signal_send` take paths of files to attach. Only
//! files inside the workspace go out, by their resolved path: the channel
//! runs outside the model's sandbox, so without that check a path, or a
//! symlink in the workspace, could send what the model may not read.

use std::path::{Path, PathBuf};

use crate::signal::Attachment;
use crate::state::Config;

/// The directory under the workspace that received files go to.
pub const INBOX: &str = "inbox";

/// A received file, as told to the model.
#[derive(Debug, Clone, PartialEq)]
pub struct Received {
    pub path: PathBuf,
    pub content_type: String,
}

impl Received {
    /// One line for the channel event, e.g. `[file: /w/inbox/a.jpg (image/jpeg)]`.
    pub fn line(&self) -> String {
        format!("[file: {} ({})]", self.path.display(), self.content_type)
    }
}

/// Moves received attachments into the inbox. A file that cannot be moved
/// is reported on stderr and left out, never failing the message.
pub fn receive(config: &Config, attachments: &[Attachment]) -> Vec<Received> {
    let inbox = config.workspace.join(INBOX);
    if let Err(e) = std::fs::create_dir_all(&inbox) {
        eprintln!("sivrad: cannot create {}: {e}", inbox.display());
        return Vec::new();
    }
    attachments
        .iter()
        .filter_map(|a| {
            // signal-cli names the file by the attachment id, already
            // reduced to [A-Za-z0-9_.-]; take the file name part anyway.
            let name = Path::new(&a.id).file_name()?;
            let from = config.signal_attachments.join(name);
            let to = inbox.join(name);
            match move_file(&from, &to) {
                Ok(()) => Some(Received {
                    path: to,
                    content_type: a.content_type.clone(),
                }),
                Err(e) => {
                    eprintln!("sivrad: attachment {}: {e}", from.display());
                    None
                }
            }
        })
        .collect()
}

fn move_file(from: &Path, to: &Path) -> std::io::Result<()> {
    if std::fs::rename(from, to).is_ok() {
        return Ok(());
    }
    std::fs::copy(from, to)?;
    std::fs::remove_file(from)
}

/// The files the model asks to send, each resolved and checked to be a
/// regular file inside the workspace; the first bad one fails the lot.
pub fn outgoing(config: &Config, paths: &[String]) -> Result<Vec<String>, String> {
    let workspace = config
        .workspace
        .canonicalize()
        .map_err(|e| format!("workspace {}: {e}", config.workspace.display()))?;
    paths
        .iter()
        .map(|p| {
            let given = if Path::new(p).is_absolute() {
                PathBuf::from(p)
            } else {
                config.workspace.join(p)
            };
            let real = given.canonicalize().map_err(|e| format!("{p}: {e}"))?;
            if !real.starts_with(&workspace) {
                return Err(format!("{p}: only files in the workspace can be sent"));
            }
            if !real.is_file() {
                return Err(format!("{p}: not a file"));
            }
            Ok(real.to_string_lossy().into_owned())
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::random_id;
    use std::fs;

    /// A workspace and an attachments directory under a fresh temp root.
    fn config() -> Config {
        let root = std::env::temp_dir().join(format!("sivrad-files-{}", random_id()));
        let config = Config {
            timeout: std::time::Duration::from_secs(1),
            tool_wait: std::time::Duration::from_secs(1),
            people_file: "/nonexistent".into(),
            signal_socket: "/nonexistent.sock".into(),
            workspace: root.join("workspace"),
            signal_attachments: root.join("attachments"),
        };
        fs::create_dir_all(&config.workspace).unwrap();
        fs::create_dir_all(&config.signal_attachments).unwrap();
        config
    }

    fn cleanup(config: &Config) {
        fs::remove_dir_all(config.workspace.parent().unwrap()).unwrap();
    }

    #[test]
    fn received_files_move_to_the_inbox() {
        let c = config();
        fs::write(c.signal_attachments.join("abc.jpg"), b"jpeg").unwrap();
        let got = receive(
            &c,
            &[
                Attachment {
                    id: "abc.jpg".into(),
                    content_type: "image/jpeg".into(),
                },
                Attachment {
                    id: "missing.png".into(),
                    content_type: "image/png".into(),
                },
            ],
        );
        let path = c.workspace.join(INBOX).join("abc.jpg");
        assert_eq!(
            got,
            [Received {
                path: path.clone(),
                content_type: "image/jpeg".into()
            }]
        );
        assert_eq!(fs::read(&path).unwrap(), b"jpeg");
        assert!(!c.signal_attachments.join("abc.jpg").exists());
        assert_eq!(
            got[0].line(),
            format!("[file: {} (image/jpeg)]", path.display())
        );
        cleanup(&c);
    }

    #[test]
    fn only_workspace_files_go_out() {
        let c = config();
        let shot = c.workspace.join("shot.png");
        fs::write(&shot, b"png").unwrap();
        let secret = c.signal_attachments.join("secret");
        fs::write(&secret, b"x").unwrap();
        let real = shot.canonicalize().unwrap().to_string_lossy().into_owned();
        assert_eq!(
            outgoing(&c, &[shot.to_string_lossy().into_owned()]),
            Ok(vec![real.clone()])
        );
        // relative to the workspace
        assert_eq!(outgoing(&c, &["shot.png".into()]), Ok(vec![real]));
        assert!(outgoing(&c, &[secret.to_string_lossy().into_owned()])
            .unwrap_err()
            .contains("only files in the workspace"));
        assert!(outgoing(&c, &["../attachments/secret".into()])
            .unwrap_err()
            .contains("only files in the workspace"));
        // a symlink out of the workspace resolves out of it
        std::os::unix::fs::symlink(&secret, c.workspace.join("link")).unwrap();
        assert!(outgoing(&c, &["link".into()])
            .unwrap_err()
            .contains("only files in the workspace"));
        assert!(outgoing(&c, &["nope.png".into()]).is_err());
        assert!(outgoing(&c, &[c.workspace.to_string_lossy().into_owned()])
            .unwrap_err()
            .contains("not a file"));
        // one bad file fails the whole send
        assert!(outgoing(&c, &["shot.png".into(), "nope.png".into()]).is_err());
        cleanup(&c);
    }
}
