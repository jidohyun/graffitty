//! Encrypted records for every network message after `auth_finish`.
//!
//! Each direction has its own ChaCha20-Poly1305 key, expanded from the OPAQUE
//! session key, and numbers its records with an implicit counter nonce.
//!
//! A tampered, replayed, reordered, reflected or dropped record fails
//! authentication, and the channel refuses everything after a failure.
//!
//! Plaintext is padded to 256-byte buckets, so a typed key and a pasted
//! password produce records of the same size.
use super::{Key, Result};
use chacha20poly1305::{AeadInPlace, ChaCha20Poly1305, KeyInit, Nonce};
use zeroize::Zeroizing;

const LABEL: &[u8] = b"graffitty-channel-v1";
const BUCKET: usize = 256;
const MARK: u8 = 0x80;
/// Bytes a record adds to its payload at most: kind, mark, padding and tag.
pub const OVERHEAD: usize = BUCKET + 16;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Client,
    Server,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Text = 1,
    Binary = 2,
}

pub struct Channel {
    seal: ChaCha20Poly1305,
    open: ChaCha20Poly1305,
    sent: u64,
    received: u64,
    broken: bool,
}

impl Key {
    /// Both ends derive the same key pair; each seals with its own direction.
    pub fn channel(&self, role: Role) -> Channel {
        let cipher = |info: &[u8]| {
            let mut key = Zeroizing::new([0u8; 32]);
            hkdf::Hkdf::<sha2::Sha256>::new(Some(LABEL), &self.0)
                .expand(info, key.as_mut_slice())
                .expect("32 bytes is a valid HKDF-SHA256 output length");
            ChaCha20Poly1305::new(chacha20poly1305::Key::from_slice(key.as_slice()))
        };
        let (client, server) = (cipher(b"client to server"), cipher(b"server to client"));
        let (seal, open) = match role {
            Role::Client => (client, server),
            Role::Server => (server, client),
        };
        Channel { seal, open, sent: 0, received: 0, broken: false }
    }
}

impl Channel {
    pub fn seal(&mut self, kind: Kind, payload: &[u8]) -> Result<Vec<u8>> {
        if self.broken {
            return Err("Encrypted session failed".into());
        }
        let size = (payload.len() + 2).div_ceil(BUCKET) * BUCKET;
        let mut record = Vec::with_capacity(size + 16);
        record.extend_from_slice(payload);
        record.extend_from_slice(&[kind as u8, MARK]);
        record.resize(size, 0);
        let nonce = nonce(self.sent);
        self.sent = self.sent.checked_add(1).ok_or("Encrypted session exhausted")?;
        if self.seal.encrypt_in_place(&nonce, b"", &mut record).is_err() {
            self.broken = true;
            return Err("Cannot encrypt session record".into());
        }
        Ok(record)
    }

    pub fn open(&mut self, record: &[u8]) -> Result<(Kind, Vec<u8>)> {
        let result = self.open_inner(record);
        if result.is_err() {
            self.broken = true;
        }
        result
    }

    fn open_inner(&mut self, record: &[u8]) -> Result<(Kind, Vec<u8>)> {
        if self.broken {
            return Err("Encrypted session failed".into());
        }
        let mut plain = record.to_vec();
        self.open
            .decrypt_in_place(&nonce(self.received), b"", &mut plain)
            .map_err(|_| "Encrypted session record rejected")?;
        self.received = self.received.checked_add(1).ok_or("Encrypted session exhausted")?;
        let end = plain
            .iter()
            .rposition(|b| *b != 0)
            .filter(|end| *end >= 1 && plain[*end] == MARK)
            .ok_or("Malformed session record")?;
        let kind = match plain[end - 1] {
            1 => Kind::Text,
            2 => Kind::Binary,
            _ => return Err("Malformed session record".into()),
        };
        plain.truncate(end - 1);
        Ok((kind, plain))
    }
}

fn nonce(counter: u64) -> Nonce {
    let mut nonce = Nonce::default();
    nonce[4..].copy_from_slice(&counter.to_be_bytes());
    nonce
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Client, Config, Server};

    fn keys(password: &str) -> (Key, Key) {
        let mut server = Server::new(Config::default(), password).unwrap();
        let (client, message) = Client::start(password, b"test").unwrap();
        let (pending, message) = server.start(&message, b"test").unwrap();
        let (client_key, finish) = client.finish(&message).unwrap();
        (client_key, pending.finish(&finish).unwrap())
    }

    fn pair() -> (Channel, Channel) {
        let (client, server) = keys("channel test password");
        (client.channel(Role::Client), server.channel(Role::Server))
    }

    #[test]
    fn records_round_trip_in_both_directions() {
        let (mut client, mut server) = pair();
        let large: Vec<u8> = (0..70_000u32).map(|i| (i % 251) as u8).collect();
        for (kind, payload) in [
            (Kind::Text, &b"{\"type\":\"subscribe\"}"[..]),
            (Kind::Binary, &[][..]),
            (Kind::Binary, &[7, 0, 0][..]),
            (Kind::Binary, &large[..]),
        ] {
            let record = client.seal(kind, payload).unwrap();
            assert_eq!(server.open(&record).unwrap(), (kind, payload.to_vec()));
            let record = server.seal(kind, payload).unwrap();
            assert_eq!(client.open(&record).unwrap(), (kind, payload.to_vec()));
        }
    }

    #[test]
    fn records_hide_content_and_small_sizes() {
        let (mut client, _) = pair();
        let marker = b"plaintext-marker";
        let record = client.seal(Kind::Text, marker).unwrap();
        assert!(!record.windows(marker.len()).any(|w| w == marker));
        let key = client.seal(Kind::Binary, b"k").unwrap();
        let paste = client.seal(Kind::Binary, &[b'p'; 200]).unwrap();
        assert_eq!(key.len(), BUCKET + 16);
        assert_eq!(paste.len(), key.len());
    }

    #[test]
    fn tampering_replay_reordering_and_reflection_fail_closed() {
        let (mut client, mut server) = pair();
        let mut tampered = client.seal(Kind::Text, b"ls").unwrap();
        tampered[3] ^= 1;
        assert!(server.open(&tampered).is_err());
        let record = client.seal(Kind::Text, b"ls").unwrap();
        assert!(server.open(&record).is_err(), "A failed channel stays closed");

        let (mut client, mut server) = pair();
        let _first = client.seal(Kind::Text, b"first").unwrap();
        let second = client.seal(Kind::Text, b"second").unwrap();
        assert!(server.open(&second).is_err(), "Out-of-order record");

        let (mut client, mut server) = pair();
        let record = client.seal(Kind::Text, b"once").unwrap();
        server.open(&record).unwrap();
        assert!(server.open(&record).is_err(), "Replayed record");

        let (mut client, _) = pair();
        let record = client.seal(Kind::Text, b"echo").unwrap();
        assert!(client.open(&record).is_err(), "Reflected record");
    }

    #[test]
    fn every_login_has_its_own_keys() {
        let (mut first, _) = pair();
        let (_, mut other) = pair();
        let record = first.seal(Kind::Text, b"hello").unwrap();
        assert!(other.open(&record).is_err());
    }
}
