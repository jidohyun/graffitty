//! Shared action identities and keyboard bindings.
//!
//! Menus, prefix sequences, direct shortcuts, and the command line all consume
//! the resolved bindings from this module; none maintain a separate key map.
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

macro_rules! actions {
    ($($name:ident),* $(,)?) => {
        /// Public command identities, independent of menu labels and localization.
        /// Serde accepts only these PascalCase names, without aliases.
        #[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
        pub enum Action { $($name),* }

        impl Action {
            pub const ALL: &'static [Action] = &[$(Action::$name),*];

            /// Actions the focused terminal runs from its own key table. Only
            /// these direct shortcuts can carry a `when` condition.
            pub fn is_terminal(self) -> bool {
                use Action::*;
                matches!(
                    self,
                    Copy | Paste | Find | QuickSelect | CopyMode | CopyLastOutput
                        | PreviousPrompt | NextPrompt | ScrollPageUp | ScrollPageDown
                        | ScrollTop | ScrollBottom | IncreaseFontSize | DecreaseFontSize
                        | ResetFontSize | SendText | Ignore
                )
            }

            pub fn name(self) -> &'static str {
                match self { $(Action::$name => stringify!($name)),* }
            }

            pub fn from_name(name: &str) -> Option<Self> {
                match name { $(stringify!($name) => Some(Action::$name),)* _ => None }
            }
        }
    };
}

actions! {
    // Tabs, windows and panes.
    NewTab, NewChromium, NewWindow, NextTab, PreviousTab, ShowAllTabs,
    SelectTab1, SelectTab2, SelectTab3, SelectTab4, SelectTab5,
    SelectTab6, SelectTab7, SelectTab8, SelectTab9,
    NewPaneLeft, NewPaneRight, NewPaneAbove, NewPaneBelow,
    FocusLeft, FocusRight, FocusUp, FocusDown,
    RenamePane, ClosePane, CloseTab, CloseWindow,
    NewSession, NextSession, PreviousSession, LastSession, CloseSession,
    SelectSession1, SelectSession2, SelectSession3, SelectSession4, SelectSession5,
    SelectSession6, SelectSession7, SelectSession8, SelectSession9,
    NextAgent, PreviousAgent,
    ResizeToFitMain, FitToPane, FitToMainArea, Overview,
    ToggleTiling, ToggleSidePanels, ToggleFiletree, ToggleFiletreeFocus,
    SendPrefix, TogglePrefix, SendLiteral, SettleEffects, ReleaseEffectHolds, SetEffectsProfile, ToggleEffect,
    PaneStatus, ResourceMonitor, StatusLine, OpenPanel, Messages, Notifications, Info, Agents, AllSessions,
    SaveCheckpoint, SaveCheckpointAndQuit,
    // Terminal pane actions.
    Copy, Paste, Find, QuickSelect, CopyMode, CopyLastOutput,
    PreviousPrompt, NextPrompt, ScrollPageUp, ScrollPageDown, ScrollTop, ScrollBottom,
    IncreaseFontSize, DecreaseFontSize, ResetFontSize,
    // Terminal key routing: SendText writes its entry's text; Ignore swallows the key.
    SendText, Ignore,
}

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Macos,
    Windows,
    Linux,
    Android,
    Ios,
}

impl Platform {
    pub const ALL: [Self; 5] = [Self::Macos, Self::Windows, Self::Linux, Self::Android, Self::Ios];

    /// The Apple group: Command is the application modifier and both
    /// platforms get the same default shortcuts.
    pub fn is_apple(self) -> bool {
        matches!(self, Self::Macos | Self::Ios)
    }

    pub fn from_name(name: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|platform| platform.name() == name)
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Macos => "macos",
            Self::Windows => "windows",
            Self::Linux => "linux",
            Self::Android => "android",
            Self::Ios => "ios",
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
pub enum PerOs<T> {
    Platforms(BTreeMap<Platform, T>),
    All(T),
}

impl<T> PerOs<T> {
    pub fn get(&self, platform: Platform) -> Option<&T> {
        match self {
            Self::All(value) => Some(value),
            Self::Platforms(values) => values.get(&platform),
        }
    }
}

/// One binding: a shortcut, or a table with the shortcut and its options:
/// `text` (SendText only) and `when` (a terminal state the key requires).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
pub enum Entry {
    Key(String),
    /// `{ key = "…", text = "…", when = "…" }`. A map, never a positional array.
    Text(BTreeMap<String, String>),
}

struct EntryParts<'a> {
    key: &'a str,
    text: Option<&'a str>,
    when: Option<&'a str>,
}

impl Entry {
    fn parts(&self) -> Result<EntryParts<'_>, String> {
        match self {
            Self::Key(key) => Ok(EntryParts {
                key,
                text: None,
                when: None,
            }),
            Self::Text(table) => {
                let known = table
                    .keys()
                    .all(|name| matches!(name.as_str(), "key" | "text" | "when"));
                match table.get("key") {
                    Some(key) if known => Ok(EntryParts {
                        key,
                        text: table.get("text").map(String::as_str),
                        when: table.get("when").map(String::as_str),
                    }),
                    _ => Err(
                        "expected a shortcut, an array, a table keyed by macos/windows/linux/android/ios, \
                         { key = \"…\", when = \"…\" }, or for SendText { key = \"…\", text = \"…\" }"
                            .into(),
                    ),
                }
            }
        }
    }
}

/// Terminal states a direct shortcut can require with `when`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub enum TerminalState {
    /// The shell is at its prompt or input line (OSC 133 semantic prompts).
    ///
    /// False while a command runs, including inline TUIs that keep the main
    /// screen, and when the shell does not mark its prompt.
    Prompt,
    /// A full-screen program switched to the alternate screen.
    AltScreen,
}

/// `when = "prompt"`, or negated with `!`: `when = "!alt_screen"`. While the
/// condition does not hold, the key reaches the program in the pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct Condition {
    pub state: TerminalState,
    pub negated: bool,
}

impl Condition {
    pub const PROMPT: Self = Self {
        state: TerminalState::Prompt,
        negated: false,
    };

    pub fn parse(text: &str) -> Result<Self, String> {
        let (negated, name) = match text.strip_prefix('!') {
            Some(rest) => (true, rest),
            None => (false, text),
        };
        let state = match name {
            "prompt" => TerminalState::Prompt,
            "alt_screen" => TerminalState::AltScreen,
            _ => {
                return Err(format!(
                    "unknown when {text:?}; expected prompt or alt_screen, optionally prefixed with !"
                ));
            }
        };
        Ok(Self { state, negated })
    }

    /// The canonical text form, as accepted by `parse`.
    pub fn name(self) -> String {
        let state = match self.state {
            TerminalState::Prompt => "prompt",
            TerminalState::AltScreen => "alt_screen",
        };
        if self.negated {
            format!("!{state}")
        } else {
            state.into()
        }
    }
}

/// Conditions on built-in shortcuts. Prompt jumps act only at a shell prompt,
/// so inline TUIs (agent CLIs, prompt pickers) receive Shift+Up/Down.
fn default_condition(action: Action) -> Option<Condition> {
    matches!(action, Action::PreviousPrompt | Action::NextPrompt).then_some(Condition::PROMPT)
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(untagged)]
pub enum Shortcuts {
    One(Entry),
    Many(Vec<Entry>),
}

impl Shortcuts {
    fn iter(&self) -> impl Iterator<Item = &Entry> {
        match self {
            Self::One(value) => std::slice::from_ref(value).iter(),
            Self::Many(values) => values.iter(),
        }
    }
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct PrefixConfig {
    pub key: PerOs<String>,
}

impl Default for PrefixConfig {
    fn default() -> Self {
        Self {
            key: PerOs::All(DEFAULT_PREFIX.into()),
        }
    }
}

pub const DEFAULT_PREFIX: &str = "Ctrl+A";

/// The input portion of client.toml. Empty arrays explicitly unbind an action.
/// A missing action (or OS entry) leaves that action's defaults unchanged.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq)]
#[serde(default, deny_unknown_fields)]
pub struct InputConfig {
    pub prefix: PrefixConfig,
    pub bindings: BTreeMap<Action, PerOs<Shortcuts>>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct Modifiers {
    pub ctrl: bool,
    pub alt: bool,
    pub shift: bool,
    pub meta: bool,
}

/// Match prefix punctuation against text from the active keyboard layout.
/// Typing it may require Shift, Option, or AltGr.
///
/// Treat plain Control or Command chords as shortcuts.
pub fn prefix_punctuation(text: &str, modifiers: Modifiers) -> Option<char> {
    if modifiers.meta || (modifiers.ctrl && !modifiers.alt) { return None; }
    match text { "\\" => Some('\\'), "|" => Some('|'), "-" => Some('-'), "_" => Some('_'), _ => None }
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct Chord {
    pub modifiers: Modifiers,
    /// Uppercase ASCII letter, digit, F1–F35, or a canonical named key.
    pub key: String,
}

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
pub struct Shortcut {
    /// Prefix is a sequence marker, not a physical modifier.
    pub prefix: bool,
    pub chord: Chord,
}

/// Canonical key names besides letters, digits and F1–F35. Punctuation is
/// named so `+` remains an unambiguous separator.
pub const NAMED_KEYS: &[&str] = &[
    "Space",
    "Tab",
    "Enter",
    "Escape",
    "Backspace",
    "Delete",
    "Insert",
    "Left",
    "Right",
    "Up",
    "Down",
    "Home",
    "End",
    "PageUp",
    "PageDown",
    "Backslash",
    "Slash",
    "Minus",
    "Equal",
    "Plus",
    "Comma",
    "Period",
    "Semicolon",
    "Colon",
    "Apostrophe",
    "QuoteLeft",
    "BracketLeft",
    "BracketRight",
    "Bar",
    "Underscore",
    "Percent",
    "Dollar",
    "At",
];

impl Shortcut {
    pub fn parse(text: &str, platform: Platform) -> Result<Self, String> {
        let mut parts: Vec<_> = text.split('+').collect();
        let key = parts.pop().unwrap_or_default();
        if !valid_key(key) {
            return Err(format!("invalid key {key:?} in {text:?}"));
        }
        let mut result = Self {
            prefix: false,
            chord: Chord {
                modifiers: Modifiers::default(),
                key: key.into(),
            },
        };
        for part in parts {
            if part == "CmdOrCtrlShift" && !platform.is_apple() {
                let modifiers = &mut result.chord.modifiers;
                if modifiers.ctrl || modifiers.shift {
                    return Err(format!("duplicate modifier in {text:?}"));
                }
                modifiers.ctrl = true;
                modifiers.shift = true;
                continue;
            }
            let flag = match part {
                "Prefix" => &mut result.prefix,
                "Ctrl" => &mut result.chord.modifiers.ctrl,
                "Cmd" => &mut result.chord.modifiers.meta,
                "Alt" => &mut result.chord.modifiers.alt,
                "Shift" => &mut result.chord.modifiers.shift,
                "CmdOrCtrlShift" => &mut result.chord.modifiers.meta,
                "CmdOrCtrl" if platform.is_apple() => &mut result.chord.modifiers.meta,
                "CmdOrCtrl" => &mut result.chord.modifiers.ctrl,
                _ => return Err(format!("unknown modifier {part:?} in {text:?}")),
            };
            if *flag {
                return Err(format!("duplicate modifier in {text:?}"));
            }
            *flag = true;
        }
        Ok(result)
    }
}

fn valid_key(key: &str) -> bool {
    (key.len() == 1
        && key
            .bytes()
            .all(|c| c.is_ascii_uppercase() || c.is_ascii_digit()))
        || NAMED_KEYS.contains(&key)
        || key
            .strip_prefix('F')
            .and_then(|n| n.parse::<u8>().ok())
            .is_some_and(|n| (1..=35).contains(&n) && key == format!("F{n}"))
}

/// One resolved source for dispatch and menu/command-line hints.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ResolvedBindings {
    pub prefix: Chord,
    pub actions: BTreeMap<Action, Vec<Shortcut>>,
    /// The text each `SendText` shortcut writes.
    pub texts: BTreeMap<Shortcut, String>,
    /// Direct shortcuts that act only in a terminal state (`when`).
    pub conditions: BTreeMap<Shortcut, Condition>,
}

impl ResolvedBindings {
    pub fn action_for(&self, shortcut: &Shortcut) -> Option<Action> {
        self.actions
            .iter()
            .find_map(|(action, keys)| keys.contains(shortcut).then_some(*action))
    }

    pub fn shortcuts_for(&self, action: Action) -> &[Shortcut] {
        self.actions
            .get(&action)
            .map(Vec::as_slice)
            .unwrap_or_default()
    }
}

/// Built-in shortcuts. Application commands use Command on Apple platforms and
/// Ctrl+Shift elsewhere, where plain Ctrl belongs to the terminal.
pub fn default_bindings(platform: Platform) -> BTreeMap<Action, Vec<Shortcut>> {
    use Action::*;
    let app = "CmdOrCtrlShift";
    let app_alt = "CmdOrCtrlShift+Alt";
    let mut table: Vec<(Action, Vec<String>)> = vec![
        (NewTab, vec![format!("{app}+T"), "Prefix+C".into()]),
        (ToggleSidePanels, vec![format!("{app}+B")]),
        (NewWindow, vec![format!("{app}+N")]),
        (ClosePane, vec![format!("{app}+W")]),
        (NextTab, vec!["Ctrl+Tab".into(), "Prefix+N".into()]),
        (
            PreviousTab,
            vec!["Ctrl+Shift+Tab".into(), "Prefix+P".into()],
        ),
        (ShowAllTabs, vec!["Prefix+V".into()]),
        (NewSession, vec!["Prefix+Shift+C".into()]),
        // LastSession has no default.
        (NextSession, vec![format!("{app_alt}+BracketRight")]),
        (PreviousSession, vec![format!("{app_alt}+BracketLeft")]),
        // Step the focus through the agents in the Agents panel's order.
        (NextAgent, vec![format!("{app}+BracketRight")]),
        (PreviousAgent, vec![format!("{app}+BracketLeft")]),
        // Repeating the prefix key (bare or with its modifiers) also sends it.
        (SendPrefix, vec!["Prefix+A".into()]),
        (ResizeToFitMain, vec!["Prefix+E".into()]),
        (SettleEffects, vec!["Prefix+R".into()]),
        (ToggleFiletree, vec!["Prefix+Tab".into()]),
        (ToggleFiletreeFocus, vec!["Prefix+Backspace".into()]),
        (NewPaneRight, vec!["Prefix+Backslash".into()]),
        (NewPaneLeft, vec!["Prefix+Bar".into()]),
        (NewPaneBelow, vec!["Prefix+Minus".into()]),
        (NewPaneAbove, vec!["Prefix+Underscore".into()]),
        (FocusLeft, vec!["Prefix+H".into(), "Prefix+Left".into()]),
        (FocusDown, vec!["Prefix+J".into(), "Prefix+Down".into()]),
        (FocusUp, vec!["Prefix+K".into(), "Prefix+Up".into()]),
        (FocusRight, vec!["Prefix+L".into(), "Prefix+Right".into()]),
        (FitToPane, vec![format!("{app}+Enter")]),
        (FitToMainArea, vec![format!("{app_alt}+Enter")]),
        (Copy, vec![format!("{app}+C")]),
        (Paste, vec![format!("{app}+V")]),
        (Find, vec![format!("{app}+F")]),
        (QuickSelect, vec!["Ctrl+Shift+Space".into()]),
        (CopyMode, vec!["Ctrl+Shift+X".into()]),
        (CopyLastOutput, vec!["Ctrl+Shift+O".into()]),
        (PreviousPrompt, vec!["Shift+Up".into()]),
        (NextPrompt, vec!["Shift+Down".into()]),
        (ScrollPageUp, vec!["Shift+PageUp".into()]),
        (ScrollPageDown, vec!["Shift+PageDown".into()]),
        (ScrollTop, vec!["Shift+Home".into()]),
        (ScrollBottom, vec!["Shift+End".into()]),
        (
            IncreaseFontSize,
            ["Equal", "Shift+Equal", "Plus", "Shift+Plus"]
                .map(|key| format!("CmdOrCtrl+{key}"))
                .to_vec(),
        ),
        (DecreaseFontSize, vec!["CmdOrCtrl+Minus".into()]),
        (ResetFontSize, vec!["CmdOrCtrl+0".into()]),
    ];
    for (index, action) in [
        SelectTab1, SelectTab2, SelectTab3, SelectTab4, SelectTab5, SelectTab6, SelectTab7,
        SelectTab8, SelectTab9,
    ]
    .into_iter()
    .enumerate()
    {
        table.push((action, vec![format!("{app}+{}", index + 1)]));
    }
    for (index, action) in [
        SelectSession1, SelectSession2, SelectSession3, SelectSession4, SelectSession5,
        SelectSession6, SelectSession7, SelectSession8, SelectSession9,
    ].into_iter().enumerate() {
        table.push((action, vec![format!("{app_alt}+{}", index + 1)]));
    }
    if platform.is_apple() {
        table.push((CloseWindow, vec!["Cmd+Shift+W".into()]));
        table.push((CloseTab, vec!["Cmd+Alt+W".into()]));
    }
    table
        .into_iter()
        .map(|(action, keys)| {
            let keys = keys
                .iter()
                .map(|key| Shortcut::parse(key, platform).expect("valid default binding"))
                .collect();
            (action, keys)
        })
        .collect()
}

impl InputConfig {
    /// Resolve after all file overlays have been applied. Defaults are supplied
    /// by the shared registry, never by individual menus or input handlers.
    pub fn resolve(
        &self,
        platform: Platform,
        defaults: &BTreeMap<Action, Vec<Shortcut>>,
    ) -> Result<ResolvedBindings, String> {
        let prefix_text = self
            .prefix
            .key
            .get(platform)
            .map(String::as_str)
            .unwrap_or(DEFAULT_PREFIX);
        let prefix = Shortcut::parse(prefix_text, platform)
            .map_err(|error| format!("prefix.key: {error}"))?;
        if prefix.prefix {
            return Err("prefix.key cannot contain Prefix".into());
        }
        let mut actions = defaults.clone();
        let mut texts = BTreeMap::new();
        let mut conditions = BTreeMap::new();
        for (action, shortcuts) in defaults {
            let configured = self
                .bindings
                .get(action)
                .is_some_and(|values| values.get(platform).is_some());
            if let Some(condition) = default_condition(*action).filter(|_| !configured) {
                for shortcut in shortcuts.iter().filter(|shortcut| !shortcut.prefix) {
                    conditions.insert(shortcut.clone(), condition);
                }
            }
        }
        for (action, values) in &self.bindings {
            let Some(values) = values.get(platform) else {
                continue;
            };
            let name = action.name();
            let mut shortcuts = Vec::new();
            for entry in values.iter() {
                let EntryParts { key, text, when } = entry
                    .parts()
                    .map_err(|error| format!("bindings.{name}: {error}"))?;
                if (*action == Action::SendText) != text.is_some() {
                    return Err(format!(
                        "bindings.{name}: SendText entries are {{ key = \"…\", text = \"…\" }} tables, and only SendText has text"
                    ));
                }
                let shortcut = Shortcut::parse(key, platform)
                    .map_err(|error| format!("bindings.{name}: {error}"))?;
                if shortcut.prefix && matches!(action, Action::SendText | Action::Ignore) {
                    return Err(format!(
                        "bindings.{name}: terminal key routing uses direct shortcuts, not Prefix+"
                    ));
                }
                if let Some(text) = text {
                    if text.is_empty() {
                        return Err("bindings.SendText: text must not be empty".into());
                    }
                    texts.insert(shortcut.clone(), text.to_owned());
                }
                if let Some(when) = when {
                    if !action.is_terminal() {
                        return Err(format!(
                            "bindings.{name}: when applies only to terminal actions"
                        ));
                    }
                    if shortcut.prefix {
                        return Err(format!(
                            "bindings.{name}: when applies to direct shortcuts, not Prefix+"
                        ));
                    }
                    let condition = Condition::parse(when)
                        .map_err(|error| format!("bindings.{name}: {error}"))?;
                    conditions.insert(shortcut.clone(), condition);
                }
                shortcuts.push(shortcut);
            }
            actions.insert(*action, shortcuts);
        }
        actions.retain(|_, shortcuts| !shortcuts.is_empty());
        conditions.retain(|shortcut, _| actions.values().any(|keys| keys.contains(shortcut)));
        let mut seen = BTreeMap::new();
        for (action, shortcuts) in &actions {
            let mut own = BTreeSet::new();
            for shortcut in shortcuts {
                let action = action.name();
                if !own.insert(shortcut) {
                    return Err(format!(
                        "duplicate binding for {action} on {}",
                        platform.name()
                    ));
                }
                if let Some(other) = seen.insert(shortcut, action) {
                    return Err(format!(
                        "binding conflict between {other} and {action} on {}",
                        platform.name()
                    ));
                }
                if !shortcut.prefix && shortcut.chord == prefix.chord {
                    return Err(format!(
                        "{action} conflicts with prefix.key on {}",
                        platform.name()
                    ));
                }
                // SendPrefix may name the prefix key: it does what repeating it does.
                if shortcut.prefix
                    && action != "SendPrefix"
                    && reserved_prefix_key(&shortcut.chord, &prefix.chord)
                {
                    return Err(format!(
                        "{action} uses a reserved prefix key on {}",
                        platform.name()
                    ));
                }
            }
        }
        Ok(ResolvedBindings {
            prefix: prefix.chord,
            actions,
            texts,
            conditions,
        })
    }

    /// Validate every OS branch, not only the machine reading the file.
    pub fn validate(&self) -> Result<(), String> {
        for platform in Platform::ALL {
            self.resolve(platform, &default_bindings(platform))?;
        }
        Ok(())
    }
}

/// Keys the prefix itself handles: repeating the prefix, cancelling, and
/// opening the command line with a target selector or `:`.
fn reserved_prefix_key(chord: &Chord, prefix: &Chord) -> bool {
    if chord == prefix {
        return true;
    }
    if chord.modifiers.ctrl || chord.modifiers.alt || chord.modifiers.meta {
        return false;
    }
    if chord.key == "Escape" {
        return true;
    }
    if !chord.modifiers.shift
        && (chord.key == prefix.key || chord.key.bytes().all(|c| c.is_ascii_digit()))
    {
        return true;
    }
    matches!(chord.key.as_str(), "Colon" | "Percent" | "Dollar" | "At")
        || (chord.modifiers.shift && matches!(chord.key.as_str(), "Semicolon" | "5" | "4" | "2"))
}
