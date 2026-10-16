//! The little of Bitwarden's encryption an organization owner does.
//!
//! A symmetric key is 64 bytes: AES-256 key, then HMAC-SHA256 key. What it
//! encrypts is a cipher string of type 2, `2.<iv>|<ciphertext>|<mac>`
//! (AES-CBC with PKCS#7, the MAC over iv and ciphertext). Handing the
//! organization's key to a member is type 4, `4.<RSA-OAEP-SHA1 ciphertext>`,
//! to the public key their client registered (base64 SPKI DER, as
//! Vaultwarden stores it).
use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ring::hmac;
use rsa::pkcs8::{DecodePublicKey, EncodePrivateKey, EncodePublicKey};
use rsa::rand_core::{OsRng, RngCore};
use rsa::{Oaep, RsaPrivateKey, RsaPublicKey};

use crate::{bail, Result};

type Enc = cbc::Encryptor<aes::Aes256>;
type Dec = cbc::Decryptor<aes::Aes256>;

pub struct SymKey {
    bytes: [u8; 64],
}

impl SymKey {
    pub fn from_base64(text: &str) -> Result<SymKey> {
        let raw = B64.decode(text.trim()).map_err(|e| format!("the key is not base64: {e}"))?;
        let Ok(bytes) = <[u8; 64]>::try_from(raw.as_slice()) else {
            bail!("the key is {} bytes, not 64", raw.len());
        };
        Ok(SymKey { bytes })
    }

    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }

    fn enc(&self) -> &[u8] {
        &self.bytes[..32]
    }

    fn mac(&self, data: &[&[u8]]) -> hmac::Tag {
        let key = hmac::Key::new(hmac::HMAC_SHA256, &self.bytes[32..]);
        let mut ctx = hmac::Context::with_key(&key);
        for d in data {
            ctx.update(d);
        }
        ctx.sign()
    }

    /// A type 2 cipher string of `plain`.
    pub fn encrypt(&self, plain: &[u8]) -> String {
        let mut iv = [0u8; 16];
        OsRng.fill_bytes(&mut iv);
        let ct = Enc::new(self.enc().into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain);
        let mac = self.mac(&[&iv, &ct]);
        format!("2.{}|{}|{}", B64.encode(iv), B64.encode(&ct), B64.encode(mac.as_ref()))
    }

    /// The plaintext of a type 2 cipher string; fails unless the MAC says
    /// this key made it.
    pub fn decrypt(&self, text: &str) -> Result<Vec<u8>> {
        let Some(body) = text.strip_prefix("2.") else {
            bail!("not a type 2 cipher string");
        };
        let parts: Vec<&str> = body.split('|').collect();
        let [iv, ct, mac] = parts[..] else {
            bail!("a type 2 cipher string has three parts");
        };
        let (iv, ct, mac) = (B64.decode(iv)?, B64.decode(ct)?, B64.decode(mac)?);
        let key = hmac::Key::new(hmac::HMAC_SHA256, &self.bytes[32..]);
        if hmac::verify(&key, &[iv.as_slice(), &ct].concat(), &mac).is_err() {
            bail!("made with another key");
        }
        let Ok(iv) = <[u8; 16]>::try_from(iv.as_slice()) else {
            bail!("the iv is not 16 bytes");
        };
        Dec::new(self.enc().into(), &iv.into())
            .decrypt_padded_vec_mut::<Pkcs7>(&ct)
            .map_err(|_| "bad padding".into())
    }
}

/// `key` for the holder of `public_key` (base64 SPKI DER): a type 4 cipher string.
pub fn share(public_key: &str, key: &SymKey) -> Result<String> {
    let der = B64.decode(public_key.trim())?;
    let public = RsaPublicKey::from_public_key_der(&der).map_err(|e| format!("not an RSA public key: {e}"))?;
    let ct = public.encrypt(&mut OsRng, Oaep::new::<sha1::Sha1>(), key.bytes())?;
    Ok(format!("4.{}", B64.encode(ct)))
}

/// The organization's own key pair, as the web vault makes one: the public
/// key in base64 SPKI DER, the private one as PKCS#8 DER encrypted with the
/// organization's key.
pub fn org_keypair(key: &SymKey) -> Result<(String, String)> {
    let private = RsaPrivateKey::new(&mut OsRng, 2048)?;
    let public = private.to_public_key().to_public_key_der()?;
    let private = private.to_pkcs8_der()?;
    Ok((B64.encode(public.as_bytes()), key.encrypt(private.as_bytes())))
}

/// A random (version 4) UUID, the kind Vaultwarden gives its rows.
pub fn uuid() -> String {
    let mut b = [0u8; 16];
    OsRng.fill_bytes(&mut b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h: String = b.iter().map(|x| format!("{x:02x}")).collect();
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

#[cfg(test)]
mod tests {
    use super::*;
    use rsa::pkcs8::DecodePrivateKey;

    fn key() -> SymKey {
        SymKey { bytes: std::array::from_fn(|i| i as u8) }
    }

    #[test]
    fn round_trip() {
        let k = key();
        let s = k.encrypt(b"Family");
        assert!(s.starts_with("2."));
        assert_eq!(k.decrypt(&s).unwrap(), b"Family");
    }

    #[test]
    fn another_key_is_refused() {
        let s = key().encrypt(b"Family");
        let other = SymKey { bytes: [7; 64] };
        assert!(other.decrypt(&s).is_err());
    }

    #[test]
    fn shared_key_opens_with_the_private_key() {
        let k = key();
        let private = RsaPrivateKey::new(&mut OsRng, 2048).unwrap();
        let public = B64.encode(private.to_public_key().to_public_key_der().unwrap().as_bytes());
        let s = share(&public, &k).unwrap();
        let ct = B64.decode(s.strip_prefix("4.").unwrap()).unwrap();
        assert_eq!(private.decrypt(Oaep::new::<sha1::Sha1>(), &ct).unwrap(), k.bytes());
    }

    #[test]
    fn org_private_key_decrypts_to_pkcs8() {
        let k = key();
        let (public, private) = org_keypair(&k).unwrap();
        let private = RsaPrivateKey::from_pkcs8_der(&k.decrypt(&private).unwrap()).unwrap();
        let public = RsaPublicKey::from_public_key_der(&B64.decode(public).unwrap()).unwrap();
        assert_eq!(private.to_public_key(), public);
    }

    #[test]
    fn uuids_look_like_uuids() {
        let u = uuid();
        assert_eq!(u.len(), 36);
        assert_eq!(&u[14..15], "4");
        assert_ne!(u, uuid());
    }
}
