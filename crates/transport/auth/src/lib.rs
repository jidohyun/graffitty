//! Shared OPAQUE password authentication. Records contain verifiers, never passwords.
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use opaque_ke::{
    argon2::{Algorithm, Argon2, Params, Version},
    *,
};
use rand_opaque::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use std::{
    path::Path,
    time::{Duration, Instant},
};
use zeroize::Zeroizing;

pub type Result<T> = std::result::Result<T, String>;
struct Suite;
impl CipherSuite for Suite {
    type OprfCs = Ristretto255;
    type KeyExchange = TripleDh<Ristretto255, sha2_opaque::Sha512>;
    type Ksf = Argon2<'static>;
}
const USER: &[u8] = b"graffitty-remote-v1";
fn ksf() -> Argon2<'static> {
    Argon2::new(
        Algorithm::Argon2id,
        Version::V0x13,
        Params::new(19456, 2, 1, None).unwrap(),
    )
}
fn decode(s: &str) -> Result<Vec<u8>> {
    if s.len() > 8192 {
        return Err("Authentication message too large".into());
    }
    B64.decode(s)
        .map_err(|_| "Invalid authentication message".into())
}
fn protocol<T, E>(r: std::result::Result<T, E>) -> Result<T> {
    r.map_err(|_| "Authentication failed".into())
}

#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Record {
    setup: String,
    verifier: String,
}
#[derive(Serialize, Deserialize, Clone)]
#[serde(deny_unknown_fields)]
pub struct Config {
    #[serde(default = "default_temporary_password_length")]
    pub temporary_password_length: usize,
    pub version: u32,
    pub password: Option<Record>,
    #[serde(default)]
    pub telegram_credential: Option<String>,
    #[serde(default)]
    pub telegram_chat_id: Option<String>,
}
fn default_temporary_password_length() -> usize { 6 }

/// Human-readable random passwords, using the same alphabet and lengths as RustDesk.
pub fn temporary_password(length: usize) -> Result<String> {
    use ::rand::RngExt;
    const ALPHABET: &[u8] = b"23456789abcdefghijkmnpqrstuvwxyz";
    if ![6, 8, 10].contains(&length) {
        return Err("Temporary password length must be 6, 8, or 10".into());
    }
    let mut rng = ::rand::rng();
    Ok((0..length)
        .map(|_| ALPHABET[rng.random_range(0..ALPHABET.len())] as char)
        .collect())
}

impl Default for Config {
    fn default() -> Self {
        Self {
            temporary_password_length: 6,
            version: 1,
            password: None,
            telegram_credential: None,
            telegram_chat_id: None,
        }
    }
}
impl Config {
    pub fn load(path: &Path) -> Result<Self> {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(_) => return Err("Cannot read remote authentication settings".into()),
        };
        let config: Self =
            serde_json::from_slice(&bytes).map_err(|_| "Invalid remote authentication settings")?;
        if ![6, 8, 10].contains(&config.temporary_password_length) {
            return Err("Temporary password length must be 6, 8, or 10".into());
        }
        if config.version != 1 {
            return Err("Unsupported authentication settings version".into());
        }
        if let Some(r) = &config.password {
            r.validate()?;
        }
        if config.telegram_credential.as_ref().is_some_and(|p| !graffitty_secrets::valid_name(p)) {
            return Err("Invalid Telegram credential name".into());
        }
        if config.telegram_chat_id.as_ref().is_some_and(|id| id.parse::<i64>().is_err()) {
            return Err("Enter a numeric Telegram chat ID".into());
        }
        Ok(config)
    }
    pub fn save(&self, path: &Path) -> Result<()> {
        use std::io::Write;
        let parent = path.parent().ok_or("Invalid settings path")?;
        std::fs::create_dir_all(parent).map_err(|_| "Cannot create settings directory")?;
        let mut file = tempfile::NamedTempFile::new_in(parent)
            .map_err(|_| "Cannot create private settings file")?;
        // tempfile creates Unix files with mode 0600, before any data is written.
        file.write_all(&serde_json::to_vec_pretty(self).map_err(|_| "Cannot encode settings")?)
            .map_err(|_| "Cannot write settings")?;
        file.as_file()
            .sync_all()
            .map_err(|_| "Cannot sync settings")?;
        file.persist(path).map_err(|_| "Cannot replace settings")?;
        Ok(())
    }
    pub fn set_password(&mut self, password: &str) -> Result<()> {
        if !(8..=1024).contains(&password.len()) {
            return Err("Use a password between 8 and 1024 bytes".into());
        }
        self.password = Some(Record::new(password)?);
        Ok(())
    }
}
impl Record {
    fn new(password: &str) -> Result<Self> {
        let setup = ServerSetup::<Suite>::new(&mut OsRng);
        let c = protocol(ClientRegistration::<Suite>::start(
            &mut OsRng,
            password.as_bytes(),
        ))?;
        let s = protocol(ServerRegistration::<Suite>::start(&setup, c.message, USER))?;
        let ksf = ksf();
        let c = protocol(c.state.finish(
            &mut OsRng,
            password.as_bytes(),
            s.message,
            ClientRegistrationFinishParameters::new(Identifiers::default(), Some(&ksf)),
        ))?;
        let record = ServerRegistration::<Suite>::finish(c.message);
        Ok(Self {
            setup: B64.encode(setup.serialize()),
            verifier: B64.encode(record.serialize()),
        })
    }
    fn validate(&self) -> Result<()> {
        protocol(ServerSetup::<Suite>::deserialize(&decode(&self.setup)?))?;
        protocol(ServerRegistration::<Suite>::deserialize(&decode(
            &self.verifier,
        )?))?;
        Ok(())
    }
}

pub struct Server {
    record: Record,
    pub telegram_credential: Option<String>,
    pub telegram_chat_id: Option<String>,
    attempts: std::collections::VecDeque<Instant>,
}
pub struct Pending {
    state: ServerLogin<Suite>,
    context: Vec<u8>,
    started: Instant,
}
pub struct Client {
    state: ClientLogin<Suite>,
    password: Zeroizing<String>,
    context: Vec<u8>,
}
pub struct Key(Zeroizing<Vec<u8>>);
impl Server {
    pub fn new(config: Config, temporary: &str) -> Result<Self> {
        Ok(Self {
            record: match config.password {
                Some(r) => r,
                None => Record::new(temporary)?,
            },
            telegram_credential: config.telegram_credential,
            telegram_chat_id: config.telegram_chat_id,
            attempts: Default::default(),
        })
    }
    fn allow_attempt(&mut self) -> bool {
        while self
            .attempts
            .front()
            .is_some_and(|t| t.elapsed() > Duration::from_secs(60))
        {
            self.attempts.pop_front();
        }
        if self.attempts.len() >= 20 {
            return false;
        }
        self.attempts.push_back(Instant::now());
        true
    }
    pub fn start(&mut self, request: &str, context: &[u8]) -> Result<(Pending, String)> {
        if !self.allow_attempt() {
            return Err("Too many authentication attempts; try again in a minute".into());
        }
        let setup = protocol(ServerSetup::<Suite>::deserialize(&decode(
            &self.record.setup,
        )?))?;
        let record = protocol(ServerRegistration::<Suite>::deserialize(&decode(
            &self.record.verifier,
        )?))?;
        let request = protocol(CredentialRequest::<Suite>::deserialize(&decode(request)?))?;
        let r = protocol(ServerLogin::<Suite>::start(
            &mut OsRng,
            &setup,
            Some(record),
            request,
            USER,
            ServerLoginParameters {
                context: Some(context),
                ..Default::default()
            },
        ))?;
        Ok((
            Pending {
                state: r.state,
                context: context.into(),
                started: Instant::now(),
            },
            B64.encode(r.message.serialize()),
        ))
    }
}
impl Pending {
    pub fn finish(self, message: &str) -> Result<Key> {
        if self.started.elapsed() > Duration::from_secs(30) {
            return Err("Authentication expired".into());
        }
        let m = protocol(CredentialFinalization::<Suite>::deserialize(&decode(
            message,
        )?))?;
        let r = protocol(self.state.finish(
            m,
            ServerLoginParameters {
                context: Some(&self.context),
                ..Default::default()
            },
        ))?;
        Ok(Key(Zeroizing::new(r.session_key.to_vec())))
    }
}
impl Client {
    pub fn start(password: &str, context: &[u8]) -> Result<(Self, String)> {
        if password.is_empty() || password.len() > 1024 {
            return Err("Enter a password".into());
        }
        let r = protocol(ClientLogin::<Suite>::start(&mut OsRng, password.as_bytes()))?;
        Ok((
            Self {
                state: r.state,
                password: Zeroizing::new(password.into()),
                context: context.into(),
            },
            B64.encode(r.message.serialize()),
        ))
    }
    pub fn finish(self, message: &str) -> Result<(Key, String)> {
        let m = protocol(CredentialResponse::<Suite>::deserialize(&decode(message)?))?;
        let ksf = ksf();
        let r = protocol(self.state.finish(
            &mut OsRng,
            self.password.as_bytes(),
            m,
            ClientLoginFinishParameters::new(
                Some(&self.context),
                Identifiers::default(),
                Some(&ksf),
            ),
        ))?;
        Ok((
            Key(Zeroizing::new(r.session_key.to_vec())),
            B64.encode(r.message.serialize()),
        ))
    }
}
impl Key {
    pub fn code_proof(&self, code: &str) -> String {
        use hmac::{Hmac, KeyInit, Mac};
        let mut mac = Hmac::<sha2::Sha256>::new_from_slice(&self.0).unwrap();
        mac.update(b"graffitty-telegram-code-v1\0");
        mac.update(code.as_bytes());
        B64.encode(mac.finalize().into_bytes())
    }
}
pub struct SecondFactor {
    key: Key,
    code: Zeroizing<String>,
    started: Instant,
    attempts: u8,
}
impl SecondFactor {
    pub fn new(key: Key) -> Self {
        use opaque_ke::rand::Rng;
        Self {
            key,
            code: Zeroizing::new(format!("{:06}", OsRng.gen_range(0..1_000_000u32))),
            started: Instant::now(),
            attempts: 0,
        }
    }
    pub fn code(&self) -> &str {
        &self.code
    }
    pub fn verify(&mut self, proof: &str) -> bool {
        use subtle::ConstantTimeEq;
        if self.attempts >= 5 || self.started.elapsed() > Duration::from_secs(120) {
            return false;
        }
        self.attempts += 1;
        let ok = bool::from(
            self.key
                .code_proof(&self.code)
                .as_bytes()
                .ct_eq(proof.as_bytes()),
        );
        if ok {
            self.attempts = 5;
        }
        ok
    }
}
pub fn random_password() -> String {
    let mut bytes = [0; 24];
    OsRng.fill_bytes(&mut bytes);
    B64.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;
    fn login(server: &mut Server, password: &str) -> Result<(Key, Key)> {
        let (c, m) = Client::start(password, b"main")?;
        let (s, m) = server.start(&m, b"main")?;
        let (ck, m) = c.finish(&m)?;
        Ok((ck, s.finish(&m)?))
    }
    #[test]
    fn auth_settings_use_only_current_credential_schema() {
        let config = Config { telegram_credential: Some("telegram-work".into()), telegram_chat_id: Some("123".into()), ..Config::default() };
        let mut value = serde_json::to_value(&config).unwrap();
        assert_eq!(value["telegram_credential"], "telegram-work");
        assert_eq!(value["telegram_chat_id"], "123");
        value["telegram_profile"] = serde_json::json!("obsolete");
        assert!(serde_json::from_value::<Config>(value).is_err());
    }
    #[test]
    fn persisted_password_and_no_token_bypass() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("auth.json");
        let mut c = Config::default();
        c.set_password("correct horse battery staple").unwrap();
        c.save(&path).unwrap();
        assert!(
            !std::fs::read_to_string(&path)
                .unwrap()
                .contains("correct horse")
        );
        let mut s = Server::new(Config::load(&path).unwrap(), "fallback").unwrap();
        assert!(login(&mut s, "fallback").is_err());
        assert!(login(&mut s, "wrong password").is_err());
        let (ck, sk) = login(&mut s, "correct horse battery staple").unwrap();
        let mut factor = SecondFactor::new(sk);
        let proof = ck.code_proof(factor.code());
        assert!(!factor.verify(&ck.code_proof("wrong")));
        assert!(factor.verify(&proof));
        assert!(!factor.verify(&proof));
    }
    #[test]
    fn fallback_and_fail_closed() {
        let mut s = Server::new(Config::default(), "temporary password").unwrap();
        assert!(login(&mut s, "temporary password").is_ok());
        let d = tempfile::tempdir().unwrap();
        let p = d.path().join("auth.json");
        std::fs::write(&p, "broken").unwrap();
        assert!(Config::load(&p).is_err());
    }
    #[test]
    fn readable_temporary_passwords_and_old_config_defaults() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("auth.json");
        std::fs::write(&path, r#"{"version":1,"password":null}"#).unwrap();
        assert_eq!(Config::load(&path).unwrap().temporary_password_length, 6);
        for length in [6, 8, 10] {
            let password = temporary_password(length).unwrap();
            assert_eq!(password.len(), length);
            assert!(password.bytes().all(|c| b"23456789abcdefghijkmnpqrstuvwxyz".contains(&c)));
            let mut config = Config::default();
            config.temporary_password_length = length;
            config.save(&path).unwrap();
            let loaded = Config::load(&path).unwrap();
            assert_eq!(loaded.temporary_password_length, length);
            let mut server = Server::new(loaded, &password).unwrap();
            assert!(login(&mut server, &password).is_ok());
            assert!(login(&mut server, "wrong").is_err());
        }
        assert!(temporary_password(7).is_err());
        std::fs::write(&path, r#"{"version":1,"password":null,"temporary_password_length":7}"#).unwrap();
        assert!(Config::load(&path).is_err());
    }

    #[test]
    fn short_temporary_passwords_keep_attempt_limit() {
        let password = temporary_password(6).unwrap();
        let mut server = Server::new(Config::default(), &password).unwrap();
        let (_, guess) = Client::start("wrong", b"main").unwrap();
        for _ in 0..20 {
            assert!(server.start(&guess, b"main").is_ok());
        }
        assert!(server.start(&guess, b"main").is_err());
        assert!(login(&mut server, &password).is_err());
    }
    #[test]
    fn context_and_session_binding() {
        let mut s = Server::new(Config::default(), "temporary password").unwrap();
        let (c, m) = Client::start("temporary password", b"different workspace").unwrap();
        let (_, m) = s.start(&m, b"main").unwrap();
        assert!(c.finish(&m).is_err());
        let (c, m) = Client::start("temporary password", b"main").unwrap();
        let (pending, m) = s.start(&m, b"main").unwrap();
        let (_, finish) = c.finish(&m).unwrap();
        let (_, m) = Client::start("temporary password", b"main").unwrap();
        let (other, _) = s.start(&m, b"main").unwrap();
        assert!(other.finish(&finish).is_err());
        assert!(pending.finish(&finish).is_ok());
    }
}

mod channel;
pub use channel::{Channel, Kind, OVERHEAD as CHANNEL_OVERHEAD, Role};
mod datagram;
pub use datagram::{Datagram, OVERHEAD as DATAGRAM_OVERHEAD};
pub mod wire;
pub mod telegram;
pub use graffitty_secrets::valid_name as valid_credential_name;
