//! Authenticated encryption for the video datagram side channel.
//!
//! Datagrams may be lost, duplicated or reordered, so unlike the record
//! channel each packet carries its explicit 64-bit counter.
//!
//! Each direction has its own ChaCha20-Poly1305 key, expanded from the OPAQUE
//! session key under a label distinct from the record channel's. The
//! cleartext packet header and counter are authenticated as associated data.
//!
//! A forged packet is rejected without affecting the session; a replayed one
//! is rejected by a sliding window of recently accepted counters.
use super::{Key, Result, Role};
use chacha20poly1305::{AeadInPlace, ChaCha20Poly1305, KeyInit, Nonce, Tag};
use zeroize::Zeroizing;

const LABEL: &[u8] = b"graffitty-datagram-v1";
/// Explicit counter and authentication tag added to each packet.
pub const OVERHEAD: usize = COUNTER + TAG;
const COUNTER: usize = 8;
const TAG: usize = 16;
/// Counters this far behind the newest accepted one are rejected as stale.
const WINDOW: u64 = 1024;

pub struct Datagram {
    seal: ChaCha20Poly1305,
    open: ChaCha20Poly1305,
    sent: u64,
    /// Newest accepted counter plus one; zero before any packet.
    newest: u64,
    /// Bit `n` marks counter `newest - 1 - n` as already accepted.
    seen: [u64; (WINDOW / 64) as usize],
}

impl Key {
    /// Both ends derive the same key pair; each seals with its own direction.
    pub fn datagram(&self, role: Role) -> Datagram {
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
        Datagram {
            seal,
            open,
            sent: 0,
            newest: 0,
            seen: [0; (WINDOW / 64) as usize],
        }
    }
}

impl Datagram {
    /// `header || counter || ciphertext || tag`; header and counter are
    /// authenticated, the payload also encrypted.
    pub fn seal(&mut self, header: &[u8], payload: &[u8]) -> Result<Vec<u8>> {
        let counter = self.sent;
        self.sent = counter.checked_add(1).ok_or("Datagram session exhausted")?;
        let mut packet = Vec::with_capacity(header.len() + OVERHEAD + payload.len());
        packet.extend_from_slice(header);
        packet.extend_from_slice(&counter.to_be_bytes());
        let start = packet.len();
        packet.extend_from_slice(payload);
        let (aad, body) = packet.split_at_mut(start);
        let tag = self
            .seal
            .encrypt_in_place_detached(&nonce(counter), aad, body)
            .map_err(|_| "Cannot encrypt datagram")?;
        packet.extend_from_slice(&tag);
        Ok(packet)
    }

    /// The payload of an authentic, not yet accepted packet whose cleartext
    /// header is `header_len` bytes long.
    pub fn open(&mut self, packet: &[u8], header_len: usize) -> Result<Vec<u8>> {
        if packet.len() < header_len + OVERHEAD {
            return Err("Short datagram".into());
        }
        let counter =
            u64::from_be_bytes(packet[header_len..header_len + COUNTER].try_into().unwrap());
        if self.accepted(counter) {
            return Err("Replayed datagram".into());
        }
        let (aad, rest) = packet.split_at(header_len + COUNTER);
        let (body, tag) = rest.split_at(rest.len() - TAG);
        let mut plain = body.to_vec();
        self.open
            .decrypt_in_place_detached(&nonce(counter), aad, &mut plain, Tag::from_slice(tag))
            .map_err(|_| "Datagram rejected")?;
        // Record the counter only once authentic: a forged packet must not
        // advance the window and make genuine ones look stale.
        self.accept(counter);
        Ok(plain)
    }

    fn accepted(&self, counter: u64) -> bool {
        if counter >= self.newest {
            return false;
        }
        let age = self.newest - 1 - counter;
        age >= WINDOW || self.seen[(age / 64) as usize] & (1 << (age % 64)) != 0
    }

    fn accept(&mut self, counter: u64) {
        if counter >= self.newest {
            let shift = counter + 1 - self.newest;
            self.shift(shift);
            self.newest = counter + 1;
            self.seen[0] |= 1;
        } else {
            let age = self.newest - 1 - counter;
            self.seen[(age / 64) as usize] |= 1 << (age % 64);
        }
    }

    /// Age every recorded counter by `by` positions.
    fn shift(&mut self, by: u64) {
        if by >= WINDOW {
            self.seen = [0; (WINDOW / 64) as usize];
            return;
        }
        let (words, bits) = ((by / 64) as usize, (by % 64) as u32);
        for i in (0..self.seen.len()).rev() {
            let low = i.checked_sub(words).map_or(0, |j| self.seen[j]);
            let carry = if bits == 0 {
                0
            } else {
                i.checked_sub(words + 1)
                    .map_or(0, |j| self.seen[j] >> (64 - bits))
            };
            self.seen[i] = (low << bits) | carry;
        }
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

    fn pair() -> (Datagram, Datagram) {
        let password = "datagram test password";
        let mut server = Server::new(Config::default(), password).unwrap();
        let (client, message) = Client::start(password, b"test").unwrap();
        let (pending, message) = server.start(&message, b"test").unwrap();
        let (client_key, finish) = client.finish(&message).unwrap();
        let server_key = pending.finish(&finish).unwrap();
        (
            client_key.datagram(Role::Client),
            server_key.datagram(Role::Server),
        )
    }

    #[test]
    fn packets_survive_loss_and_reordering_but_not_replay_or_tampering() {
        let (mut client, mut server) = pair();
        let header = [0x80, 96, 0, 1, 0, 0, 0, 0, 1, 2, 3, 4];
        let packets: Vec<_> = (0..5u8)
            .map(|i| server.seal(&header, &[i; 40]).unwrap())
            .collect();
        assert_eq!(
            client.open(&packets[3], 12).unwrap(),
            vec![3; 40],
            "Earlier losses do not block later packets"
        );
        assert_eq!(
            client.open(&packets[1], 12).unwrap(),
            vec![1; 40],
            "Reordered packets within the window open"
        );
        assert!(
            client.open(&packets[3], 12).is_err(),
            "Replays are rejected"
        );
        assert!(
            client.open(&packets[1], 12).is_err(),
            "Replays of reordered packets are rejected"
        );
        let mut tampered = packets[4].clone();
        tampered[1] ^= 1;
        assert!(
            client.open(&tampered, 12).is_err(),
            "The cleartext header is authenticated"
        );
        assert_eq!(
            client.open(&packets[4], 12).unwrap(),
            vec![4; 40],
            "A forgery does not disturb the session"
        );
        let reflected = client.seal(&header, b"echo").unwrap();
        assert!(
            client.open(&reflected, 12).is_err(),
            "Each direction has its own key"
        );
        assert_eq!(server.open(&reflected, 12).unwrap(), b"echo");
    }

    #[test]
    fn the_replay_window_slides_and_rejects_stale_counters() {
        let (mut client, mut server) = pair();
        let packets: Vec<_> = (0..WINDOW + 200)
            .map(|_| server.seal(&[], b"x").unwrap())
            .collect();
        assert!(client.open(&packets[100], 0).is_ok());
        assert!(client.open(&packets[(WINDOW + 150) as usize], 0).is_ok());
        assert!(client.open(&packets[100], 0).is_err());
        assert!(
            client.open(&packets[149], 0).is_err(),
            "Counters older than the window are stale"
        );
        assert!(
            client.open(&packets[(WINDOW + 100) as usize], 0).is_ok(),
            "Unseen counters inside the window open"
        );
        assert!(client.open(&packets[(WINDOW + 100) as usize], 0).is_err());
        assert!(client.open(&packets[(WINDOW + 199) as usize], 0).is_ok());
        assert!(
            client.open(&packets[(WINDOW + 100) as usize], 0).is_err(),
            "Shifted marks are preserved"
        );
        assert!(client.open(&packets[(WINDOW + 101) as usize], 0).is_ok());
    }
}
