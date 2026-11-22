//! `ark-dav <folder-url> <user> <password-file>`: the calendars and address
//! books a person sees in ark's Radicale (services/radicale), their own and
//! the groups' it links in, as JSON on stdout:
//!
//!   {"realm": "Radicale - Password Required",
//!    "collections": [{"url": "https://…/max/contacts/", "kind": "addressbook",
//!                     "name": "Contacts", "color": null}, …]}
//!
//! For any program that wants them without a list of its own: ark-thunderbird
//! reads it, and so can a script. Exits non-zero, printing nothing, when
//! Radicale can't be asked, so a reader keeps what it had.
mod dav;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let [url, user, password_file] = args.as_slice() else {
        eprintln!("usage: ark-dav <folder-url> <user> <password-file>");
        return ExitCode::from(2);
    };
    let password = match std::fs::read_to_string(password_file) {
        Ok(p) => p.trim_end_matches(['\r', '\n']).to_string(),
        Err(e) => {
            eprintln!("ark-dav: reading {password_file}: {e}");
            return ExitCode::FAILURE;
        }
    };
    let url = if url.ends_with('/') {
        url.clone()
    } else {
        format!("{url}/")
    };
    match dav::discover(&url, user, &password) {
        Ok(found) => {
            println!("{}", serde_json::to_string_pretty(&found).expect("plain data"));
            ExitCode::SUCCESS
        }
        Err(e) => {
            eprintln!("ark-dav: {e}");
            ExitCode::FAILURE
        }
    }
}
