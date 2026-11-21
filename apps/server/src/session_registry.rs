//! Bind immutable owner-internal workspace keys to public session identities.
//! Renaming never moves a PTY, graph, layout or client to another workspace.
use graffitty_workspace_core::session::{Session, SessionError, SessionId, Sessions};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Registry {
    sessions: Sessions,
    keys: BTreeMap<String, SessionId>,
}
impl Registry {
    pub fn insert(&mut self, key: String) -> bool {
        if self.keys.contains_key(&key) {
            return false;
        }
        let id = self
            .sessions
            .create(None)
            .expect("session identity space exhausted");
        self.keys.insert(key, id);
        true
    }
    pub fn remove(&mut self, key: &str) -> bool {
        self.keys
            .remove(key)
            .and_then(|id| self.sessions.remove(id))
            .is_some()
    }
    pub fn contains(&self, key: &str) -> bool {
        self.keys.contains_key(key)
    }
    pub fn len(&self) -> usize {
        self.keys.len()
    }
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
    pub fn iter(&self) -> impl Iterator<Item = &String> {
        self.keys.keys()
    }
    pub fn info(&self, key: &str) -> &Session {
        self.sessions.get(self.keys[key]).unwrap()
    }
    pub fn id(&self, key: &str) -> String {
        self.info(key).id.to_string()
    }
    pub fn resolve(&self, target: &str) -> Result<String, SessionError> {
        let id = self.sessions.resolve(target)?;
        self.keys
            .iter()
            .find_map(|(key, value)| (*value == id).then(|| key.clone()))
            .ok_or(SessionError::InvalidState)
    }
    pub fn check_name(&self, name: Option<&str>) -> Result<(), SessionError> {
        self.sessions.clone().create(name).map(|_| ())
    }
    pub fn rename(&mut self, key: &str, name: Option<&str>) -> Result<(), SessionError> {
        self.sessions.rename(self.keys[key], name)
    }
    pub fn validate(&self) -> Result<(), SessionError> {
        self.sessions.validate()?;
        let ids: std::collections::BTreeSet<_> = self.keys.values().copied().collect();
        if ids.len() != self.keys.len()
            || ids.len() != self.sessions.iter().count()
            || ids.iter().any(|id| self.sessions.get(*id).is_none())
        {
            return Err(SessionError::InvalidState);
        }
        Ok(())
    }
}
