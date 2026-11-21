//! Stable named-session identities and tmux-style session-only targets.
//! Names are presentation, never the identity of a running session.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fmt;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct SessionId(pub u64);

impl fmt::Display for SessionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "${}", self.0)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Session {
    pub id: SessionId,
    /// None means tmux's numeric default name, displayed as just `$id` in the UI.
    pub name: Option<String>,
}

impl Session {
    pub fn target_name(&self) -> String {
        self.name.clone().unwrap_or_else(|| self.id.0.to_string())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionError {
    InvalidName,
    DuplicateName(String),
    NotFound(String),
    Ambiguous(String),
    IdExhausted,
    InvalidState,
}
impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidName => write!(
                f,
                "Session names must be nonempty and contain no colon, period or control character"
            ),
            Self::DuplicateName(n) => write!(f, "Duplicate session: {n}"),
            Self::NotFound(n) => write!(f, "Session not found: {n}"),
            Self::Ambiguous(n) => write!(f, "Ambiguous session: {n}"),
            Self::IdExhausted => write!(f, "Session identity exhausted"),
            Self::InvalidState => write!(f, "Invalid session registry"),
        }
    }
}
impl std::error::Error for SessionError {}

/// One monotonic namespace per server. Snapshot validation must precede adoption.
#[derive(Debug, Default, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Sessions {
    next_id: u64,
    entries: BTreeMap<SessionId, Session>,
}

impl Sessions {
    pub fn iter(&self) -> impl Iterator<Item = &Session> {
        self.entries.values()
    }
    pub fn get(&self, id: SessionId) -> Option<&Session> {
        self.entries.get(&id)
    }

    pub fn create(&mut self, name: Option<&str>) -> Result<SessionId, SessionError> {
        if let Some(name) = name {
            validate_name(name)?;
        }
        let mut number = self.next_id.max(1);
        // Like tmux, numeric default names must not collide with explicit names.
        while name.is_none() && self.name_exists(&number.to_string(), None) {
            number = number.checked_add(1).ok_or(SessionError::IdExhausted)?;
        }
        let next = number.checked_add(1).ok_or(SessionError::IdExhausted)?;
        let id = SessionId(number);
        let session = Session {
            id,
            name: name.map(str::to_owned),
        };
        if self.name_exists(&session.target_name(), None) {
            return Err(SessionError::DuplicateName(session.target_name()));
        }
        self.entries.insert(id, session);
        self.next_id = next;
        Ok(id)
    }

    pub fn rename(&mut self, id: SessionId, name: Option<&str>) -> Result<(), SessionError> {
        if !self.entries.contains_key(&id) {
            return Err(SessionError::NotFound(id.to_string()));
        }
        if let Some(name) = name {
            validate_name(name)?;
        }
        let target = name.map(str::to_owned).unwrap_or_else(|| id.0.to_string());
        if self.name_exists(&target, Some(id)) {
            return Err(SessionError::DuplicateName(target));
        }
        self.entries.get_mut(&id).unwrap().name = name.map(str::to_owned);
        Ok(())
    }

    pub fn remove(&mut self, id: SessionId) -> Option<Session> {
        self.entries.remove(&id)
    }

    /// `$id`, exact name (`=name` disables prefix matching), or unique prefix.
    /// A terminal ':' is accepted for a session-only tmux target.
    pub fn resolve(&self, target: &str) -> Result<SessionId, SessionError> {
        let original = target;
        let target = target.strip_suffix(':').unwrap_or(target);
        if let Some(number) = target.strip_prefix('$') {
            let id = number.parse::<u64>().ok().map(SessionId);
            return id
                .filter(|id| self.entries.contains_key(id))
                .ok_or_else(|| SessionError::NotFound(original.into()));
        }
        let exact = target.strip_prefix('=');
        let name = exact.unwrap_or(target);
        if name.is_empty() {
            return Err(SessionError::NotFound(original.into()));
        }
        if let Some(session) = self.iter().find(|s| s.target_name() == name) {
            return Ok(session.id);
        }
        if exact.is_some() {
            return Err(SessionError::NotFound(original.into()));
        }
        let mut matches = self.iter().filter(|s| s.target_name().starts_with(name));
        let id = matches
            .next()
            .map(|s| s.id)
            .ok_or_else(|| SessionError::NotFound(original.into()))?;
        if matches.next().is_some() {
            return Err(SessionError::Ambiguous(original.into()));
        }
        Ok(id)
    }

    pub fn validate(&self) -> Result<(), SessionError> {
        let mut names = std::collections::HashSet::new();
        for (id, session) in &self.entries {
            if *id != session.id || id.0 >= self.next_id || !names.insert(session.target_name()) {
                return Err(SessionError::InvalidState);
            }
            if let Some(name) = &session.name {
                validate_name(name)?;
            }
        }
        Ok(())
    }

    fn name_exists(&self, name: &str, except: Option<SessionId>) -> bool {
        self.iter()
            .any(|s| Some(s.id) != except && s.target_name() == name)
    }
}

/// Cluster directories by path text. Rank ancestors by pane coverage,
/// then depth, then lexical path order.
///
/// Exclude broad roots such as home so project directories can form clusters.
pub fn automatic_name<'a>(
    directories: impl IntoIterator<Item = &'a std::path::Path>,
    home: Option<&std::path::Path>,
) -> Option<String> {
    use std::path::Path;
    fn contains(parent: &Path, child: &Path) -> bool {
        let mut parts = child.components();
        parent.components().all(|a| parts.next().is_some_and(|b|
            same_component(a.as_os_str(), b.as_os_str())))
    }
    fn broad(path: &Path) -> bool {
        let Some(name) = path.file_name() else { return true };
        matches!(name.to_string_lossy().to_ascii_lowercase().as_str(),
            "home" | "users" | "tmp" | "temp" | "var" | "private" | "volumes"
            | "project" | "projects" | "repos" | "repositories" | "workspace"
            | "workspaces" | "code" | "dev" | "development")
    }
    let paths: Vec<_> = directories.into_iter().filter(|p| p.is_absolute()).collect();
    let mut best: Option<(&Path, usize, usize)> = None;
    for candidate in paths.iter().flat_map(|p| p.ancestors()) {
        if broad(candidate) || home.is_some_and(|h| contains(candidate, h)) {
            continue;
        }
        let score = paths.iter().filter(|p| contains(candidate, p)).count();
        let depth = candidate.components().count();
        if best.is_none_or(|(path, count, level)|
            (score, depth) > (count, level)
                || (score, depth) == (count, level) && candidate < path)
        {
            best = Some((candidate, score, depth));
        }
    }
    best.and_then(|(path, _, _)| path.file_name())
        .map(|name| name.to_string_lossy().into_owned())
        .or_else(|| home.filter(|h| paths.iter().any(|p|
            contains(h, p) && contains(p, h))).map(|_| "~".into()))
}

fn same_component(a: &std::ffi::OsStr, b: &std::ffi::OsStr) -> bool {
    #[cfg(windows)]
    {
        a.to_string_lossy()
            .eq_ignore_ascii_case(&b.to_string_lossy())
    }
    #[cfg(not(windows))]
    {
        a == b
    }
}

fn validate_name(name: &str) -> Result<(), SessionError> {
    if name.is_empty() || name.chars().any(|c| c.is_control() || c == ':' || c == '.') {
        Err(SessionError::InvalidName)
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn clusters_respect_component_boundaries() {
        use std::path::Path;
        let home = std::env::temp_dir().join("fixture-home");
        let base = home.join("projects");
        let project = base.join("godot-ghostty");
        let a = project.join("src");
        let b = project.join("tests");
        assert_eq!(
            automatic_name([a.as_path(), b.as_path(), project.as_path()], None),
            Some("godot-ghostty".into())
        );
        assert_eq!(
            automatic_name([a.as_path(), Path::new("unknown-relative")], None),
            Some("src".into())
        );
        let sibling = base.join("godot-ghostty-other");
        assert_eq!(
            automatic_name([project.as_path(), sibling.as_path()], Some(&home)),
            Some("godot-ghostty".into())
        );
        assert_eq!(automatic_name([], None), None);
    }
    #[test]
    fn home_is_tilde_and_root_alone_has_no_name() {
        let home = std::env::temp_dir().join("fixture-home");
        let a = home.join("one");
        let b = home.join("two");
        assert_eq!(
            automatic_name([a.as_path(), b.as_path()], Some(&home)),
            Some("one".into())
        );
        assert_eq!(
            automatic_name([home.as_path()], Some(&home)),
            Some("~".into())
        );
        let root = home.ancestors().last().unwrap();
        assert_eq!(automatic_name([root], Some(&home)), None);
    }
    #[test]
    fn project_majority_survives_root_home_and_unrelated_outliers() {
        let home = std::env::temp_dir().join("fixture-home");
        let root = home.ancestors().last().unwrap();
        let a = home.join("projects/alpha/src");
        let b = home.join("projects/alpha/tests");
        let c = home.join("projects/beta");
        let paths = [root, home.as_path(), a.as_path(), b.as_path(), c.as_path()];
        assert_eq!(automatic_name(paths, Some(&home)), Some("alpha".into()));
        assert_eq!(automatic_name(paths.into_iter().rev(), Some(&home)), Some("alpha".into()));
    }

    #[test]
    fn equally_supported_projects_choose_one_stable_label() {
        let home = std::env::temp_dir().join("fixture-home");
        let a = home.join("projects/alpha/src");
        let b = home.join("projects/alpha/tests");
        let c = home.join("projects/beta/src");
        let d = home.join("projects/beta/tests");
        for paths in [[&a, &b, &c, &d], [&d, &c, &b, &a], [&c, &a, &d, &b]] {
            assert_eq!(automatic_name(paths.map(|p| p.as_path()), Some(&home)), Some("alpha".into()));
        }
    }

    #[test]
    fn repeated_directory_votes_and_root_only_inputs() {
        let home = std::env::temp_dir().join("fixture-home");
        let a = home.join("projects/alpha");
        let b = home.join("projects/beta");
        let root = home.ancestors().last().unwrap();
        assert_eq!(automatic_name([&a, &b, &b].map(|p| p.as_path()), Some(&home)), Some("beta".into()));
        assert_eq!(automatic_name([root, a.as_path()], Some(&home)), Some("alpha".into()));
        assert_eq!(automatic_name([root, root], Some(&home)), None);
    }

    #[test]
    fn ids_survive_rename_and_are_never_reused() {
        let mut sessions = Sessions::default();
        let first = sessions.create(Some("api")).unwrap();
        assert_eq!(first.to_string(), "$1");
        sessions.rename(first, Some("backend")).unwrap();
        assert_eq!(sessions.resolve("$1"), Ok(first));
        assert_eq!(sessions.resolve("backend"), Ok(first));
        assert!(matches!(
            sessions.resolve("api"),
            Err(SessionError::NotFound(_))
        ));
        sessions.remove(first);
        let second = sessions.create(Some("api")).unwrap();
        assert_eq!(second.to_string(), "$2");
        assert!(sessions.resolve("$1").is_err());
    }
    #[test]
    fn defaults_exact_targets_prefixes_and_ambiguity() {
        let mut sessions = Sessions::default();
        let first = sessions.create(None).unwrap();
        assert_eq!(sessions.get(first).unwrap().name, None);
        assert_eq!(sessions.resolve("1:"), Ok(first));
        let api = sessions.create(Some("api")).unwrap();
        sessions.create(Some("api-worker")).unwrap();
        assert_eq!(sessions.resolve("api"), Ok(api));
        assert_eq!(sessions.resolve("=api"), Ok(api));
        assert_eq!(sessions.resolve("$2:"), Ok(api));
        assert!(matches!(
            sessions.resolve("ap"),
            Err(SessionError::Ambiguous(_))
        ));
        assert!(sessions.resolve("=ap").is_err());
        assert!(sessions.resolve("").is_err());
    }
    #[test]
    fn explicit_numeric_names_do_not_get_overwritten() {
        let mut sessions = Sessions::default();
        let named = sessions.create(Some("2")).unwrap();
        assert_eq!(named, SessionId(1));
        assert_eq!(sessions.create(None), Ok(SessionId(3)));
        assert_eq!(sessions.resolve("2"), Ok(named));
        assert!(sessions.resolve("$2").is_err());
    }
    #[test]
    fn duplicate_and_invalid_rename_are_atomic() {
        let mut sessions = Sessions::default();
        let first = sessions.create(None).unwrap();
        sessions.create(Some("api")).unwrap();
        let before = sessions.clone();
        assert!(sessions.rename(first, Some("api")).is_err());
        assert!(sessions.rename(first, Some("bad:name")).is_err());
        assert!(sessions.create(Some("bad.name")).is_err());
        assert!(sessions.create(Some("")).is_err());
        assert_eq!(sessions, before);
        sessions.rename(first, Some("build agent")).unwrap();
        assert_eq!(sessions.resolve("build agent"), Ok(first));
        sessions.rename(first, None).unwrap();
        assert_eq!(sessions.resolve("1"), Ok(first));
    }
    #[test]
    fn snapshot_retains_ids_and_high_water_mark() {
        let mut sessions = Sessions::default();
        let id = sessions.create(Some("api")).unwrap();
        let deleted = sessions.create(None).unwrap();
        sessions.remove(deleted);
        let json = serde_json::to_string(&sessions).unwrap();
        let mut restored: Sessions = serde_json::from_str(&json).unwrap();
        restored.validate().unwrap();
        assert_eq!(restored.resolve("api"), Ok(id));
        assert_eq!(restored.create(None), Ok(SessionId(3)));
    }
    #[test]
    fn invalid_snapshot_and_exhaustion_are_rejected() {
        let mut sessions = Sessions::default();
        let id = sessions.create(None).unwrap();
        sessions.entries.get_mut(&id).unwrap().id = SessionId(8);
        assert_eq!(sessions.validate(), Err(SessionError::InvalidState));
        let mut exhausted = Sessions {
            next_id: u64::MAX,
            entries: BTreeMap::new(),
        };
        assert_eq!(exhausted.create(None), Err(SessionError::IdExhausted));
    }
}
