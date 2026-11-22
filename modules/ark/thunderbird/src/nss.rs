//! Thunderbird's password encryption: NSS's "secret decoder ring", keyed by
//! the profile's key4.db, which is what logins.json's entries are sealed with.
//! The same calls Thunderbird makes, through the NSS it is built against.
use std::ffi::{c_char, c_int, c_uint, c_void, CString};
use std::path::Path;

use base64::{engine::general_purpose::STANDARD, Engine};

use crate::logins::Cipher;

#[repr(C)]
struct SecItem {
    kind: c_uint,
    data: *mut u8,
    len: c_uint,
}

impl SecItem {
    fn empty() -> Self {
        SecItem {
            kind: 0,
            data: std::ptr::null_mut(),
            len: 0,
        }
    }

    /// Borrows `bytes`; NSS only reads an input item.
    fn of(bytes: &[u8]) -> Self {
        SecItem {
            kind: 0,
            data: bytes.as_ptr() as *mut u8,
            len: bytes.len() as c_uint,
        }
    }
}

#[link(name = "nss3")]
extern "C" {
    fn NSS_InitReadWrite(dir: *const c_char) -> c_int;
    fn NSS_Shutdown() -> c_int;
    fn PK11_GetInternalKeySlot() -> *mut c_void;
    fn PK11_FreeSlot(slot: *mut c_void);
    fn PK11_NeedUserInit(slot: *mut c_void) -> c_int;
    fn PK11_InitPin(slot: *mut c_void, sso: *const c_char, pin: *const c_char) -> c_int;
    fn PK11_Authenticate(slot: *mut c_void, load_certs: c_int, cx: *mut c_void) -> c_int;
    fn PK11SDR_Encrypt(
        key: *mut SecItem,
        data: *mut SecItem,
        out: *mut SecItem,
        cx: *mut c_void,
    ) -> c_int;
    fn PK11SDR_Decrypt(data: *mut SecItem, out: *mut SecItem, cx: *mut c_void) -> c_int;
}

#[link(name = "nssutil3")]
extern "C" {
    fn SECITEM_ZfreeItem(item: *mut SecItem, free_it: c_int);
    fn PORT_GetError() -> c_int;
}

const OK: c_int = 0;

/// A profile's key store, open. NSS is one per process: open one at a time.
pub struct Nss {
    slot: *mut c_void,
}

fn failed(what: &str) -> String {
    format!("{what} failed (NSS error {})", unsafe { PORT_GetError() })
}

impl Nss {
    /// Opens (making, if it isn't there) the key store in `profile`.
    pub fn open(profile: &Path) -> Result<Self, String> {
        // sql: the key4.db Thunderbird uses, not the old key3.db.
        let dir = CString::new(format!("sql:{}", profile.display())).map_err(|e| e.to_string())?;
        if unsafe { NSS_InitReadWrite(dir.as_ptr()) } != OK {
            return Err(failed("opening the key store"));
        }
        let slot = unsafe { PK11_GetInternalKeySlot() };
        if slot.is_null() {
            unsafe { NSS_Shutdown() };
            return Err(failed("finding the key slot"));
        }
        let nss = Nss { slot };
        let empty = CString::default();
        // A new key4.db has no password yet: the empty one, as Thunderbird
        // sets when nobody sets a primary password.
        if unsafe { PK11_NeedUserInit(slot) } != 0
            && unsafe { PK11_InitPin(slot, std::ptr::null(), empty.as_ptr()) } != OK
        {
            return Err(failed("setting up the key store"));
        }
        if unsafe { PK11_Authenticate(slot, 1, std::ptr::null_mut()) } != OK {
            return Err(failed(
                "unlocking the key store (is a primary password set? \
                 passwords can only be filled in without one)",
            ));
        }
        Ok(nss)
    }
}

impl Drop for Nss {
    fn drop(&mut self) {
        unsafe {
            PK11_FreeSlot(self.slot);
            NSS_Shutdown();
        }
    }
}

impl Cipher for Nss {
    fn encrypt(&self, text: &str) -> Result<String, String> {
        let mut key = SecItem::empty();
        let mut data = SecItem::of(text.as_bytes());
        let mut out = SecItem::empty();
        if unsafe { PK11SDR_Encrypt(&mut key, &mut data, &mut out, std::ptr::null_mut()) } != OK {
            return Err(failed("encrypting"));
        }
        let sealed = unsafe { std::slice::from_raw_parts(out.data, out.len as usize) }.to_vec();
        unsafe { SECITEM_ZfreeItem(&mut out, 0) };
        Ok(STANDARD.encode(sealed))
    }

    fn decrypt(&self, sealed: &str) -> Option<String> {
        let bytes = STANDARD.decode(sealed).ok()?;
        let mut data = SecItem::of(&bytes);
        let mut out = SecItem::empty();
        if unsafe { PK11SDR_Decrypt(&mut data, &mut out, std::ptr::null_mut()) } != OK {
            return None;
        }
        let plain = unsafe { std::slice::from_raw_parts(out.data, out.len as usize) }.to_vec();
        unsafe { SECITEM_ZfreeItem(&mut out, 0) };
        String::from_utf8(plain).ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A new key store, sealed with and opened again: what Thunderbird reads
    /// back. One test, as NSS is one per process.
    #[test]
    fn seals_in_a_new_profile_and_opens_again() {
        let dir = std::env::temp_dir().join(format!("ark-thunderbird-nss-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let sealed = {
            let nss = Nss::open(&dir).expect("opens");
            let sealed = nss.encrypt("hunter2").unwrap();
            assert_ne!(sealed, "hunter2");
            assert_eq!(nss.decrypt(&sealed).as_deref(), Some("hunter2"));
            assert_eq!(nss.decrypt("bm90IHNlYWxlZA=="), None);
            sealed
        };
        assert!(dir.join("key4.db").exists());
        // Opened again, as the next launch does: the same key.
        let nss = Nss::open(&dir).expect("opens again");
        assert_eq!(nss.decrypt(&sealed).as_deref(), Some("hunter2"));
        drop(nss);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
