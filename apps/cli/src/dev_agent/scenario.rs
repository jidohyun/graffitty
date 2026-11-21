use crate::{agent_bridge::Result, options::AgentPlayback};
use serde::Deserialize;
use std::{fs, path::Path};

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Scenario {
    pub model: String,
    pub version: String,
    pub title: String,
    pub directory: String,
    pub billing: String,
    pub think_ms: u64,
    pub char_ms: u64,
    pub real_tool_calling: bool,
    pub animation_clock: Option<std::path::PathBuf>,
    pub scenario_clock: Option<std::path::PathBuf>,
    pub palette: Option<super::palette::Palette>,
    pub stream: super::streaming::Settings,
    pub completion: super::completion::Settings,
    pub response: String,
    pub tip: String,
    /// Accepted for older scenario files; the compact footer shows model/cwd only.
    pub status: StatusLine,
    pub turns: Vec<Turn>,
}
impl Default for Scenario {
    fn default() -> Self {
        Self {
            model: String::new(),
            version: String::new(),
            title: String::new(),
            directory: String::new(),
            billing: "API Usage Billing".into(),
            think_ms: 1800,
            char_ms: 12,
            real_tool_calling: false,
            animation_clock: None,
            scenario_clock: None,
            palette: None,
            stream: super::streaming::Settings::default(),
            completion: super::completion::Settings::default(),
            response: "I've reviewed the request and completed the changes. Everything is ready."
                .into(),
            tip: "Use /title to choose what appears in your terminal’s title.".into(),
            status: StatusLine::default(),
            turns: Vec::new(),
        }
    }
}
#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct StatusLine {
    pub branch: String,
    pub context_percent: u8,
    pub context_window: String,
    pub tokens_used: String,
    pub input_tokens: String,
    pub output_tokens: String,
}
impl Default for StatusLine {
    fn default() -> Self {
        Self {
            branch: "main".into(),
            context_percent: 0,
            context_window: "258K".into(),
            tokens_used: "0".into(),
            input_tokens: "0".into(),
            output_tokens: "0".into(),
        }
    }
}
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Turn {
    /// Exact prompt match. Unmatched turns are consumed in sequence.
    pub prompt: Option<String>,
    pub contains: Option<String>,
    pub title: Option<String>,
    pub response: Option<String>,
    pub think_ms: Option<u64>,
    pub completion: super::completion::Settings,
    pub steps: Vec<Step>,
}
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case", deny_unknown_fields)]
pub enum Step {
    Think {
        ms: u64,
        #[serde(default)]
        text: String,
    },
    Wait {
        ms: u64,
    },
    Message {
        text: String,
        #[serde(default)]
        char_ms: Option<u64>,
    },
    Tool {
        name: String,
        /// Literal executable and arguments; never interpolate prompt templates.
        #[serde(default)]
        command: Vec<String>,
        #[serde(default)]
        input: String,
        #[serde(default)]
        output: String,
        #[serde(default)]
        exit_code: i32,
        #[serde(default = "preview_lines")]
        preview_lines: usize,
        #[serde(default = "tool_ms")]
        ms: u64,
    },
    Edit {
        path: String,
        before: String,
        after: String,
        #[serde(default = "first_line")]
        line: usize,
        #[serde(default = "preview_lines")]
        preview_lines: usize,
        #[serde(default = "tool_ms")]
        ms: u64,
    },
}
fn first_line() -> usize {
    1
}
fn preview_lines() -> usize {
    3
}
fn tool_ms() -> u64 {
    800
}
pub fn clean(text: &str) -> String {
    text.chars()
        .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
        .collect()
}
pub fn title(text: &str) -> String {
    let text = clean(text).split_whitespace().collect::<Vec<_>>().join(" ");
    if text.chars().count() > 64 {
        format!("{}…", text.chars().take(63).collect::<String>())
    } else {
        text
    }
}
fn expand(text: &str, prompt: &str, turn: usize) -> String {
    // Expand in one pass: a user's literal {turn} is not itself a template.
    let mut out = String::new();
    let mut rest = text;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        if let Some(tail) = rest.strip_prefix("{prompt}") {
            out.push_str(prompt);
            rest = tail;
        } else if let Some(tail) = rest.strip_prefix("{turn}") {
            out.push_str(&turn.to_string());
            rest = tail;
        } else {
            out.push('{');
            rest = &rest[1..];
        }
    }
    out.push_str(rest);
    clean(&out)
}
impl Scenario {
    pub fn load(args: &AgentPlayback, provider: super::Provider) -> Result<Self> {
        let mut settings: Self = if let Some(path) = &args.config {
            let bytes = fs::read(path)?;
            if bytes.len() > 2 * 1024 * 1024 {
                return Err("Scenario exceeds 2 MiB".into());
            }
            serde_json::from_slice(&bytes)?
        } else {
            Self::default()
        };
        if let Some(v) = &args.response {
            settings.response = v.clone();
        }
        if let Some(v) = args.think_ms {
            settings.think_ms = v;
        }
        if let Some(v) = args.char_ms {
            settings.char_ms = v;
        }
        settings.real_tool_calling |= args.real_tool_calling;
        if let Some(v) = &args.model {
            settings.model = v.clone();
        }
        if let Some(v) = &args.title {
            settings.title = v.clone();
        }
        if settings.model.is_empty() {
            settings.model = provider.model().into();
        }
        if settings.version.is_empty() {
            settings.version = provider.version().into();
        }
        if settings.directory.is_empty() {
            let cwd = std::env::current_dir()?;
            settings.directory = std::env::var_os("HOME")
                .and_then(|home| {
                    cwd.strip_prefix(Path::new(&home))
                        .ok()
                        .map(|p| format!("~/{}", p.display()))
                })
                .unwrap_or_else(|| cwd.display().to_string());
        }
        fn duration(ms: u64) -> Result<()> {
            if ms > 86_400_000 {
                Err("A delay may not exceed 24 hours".into())
            } else {
                Ok(())
            }
        }
        duration(settings.think_ms)?;
        duration(settings.char_ms)?;
        if settings.stream.jitter_percent > 100 {
            return Err("stream.jitter_percent must be between 0 and 100".into());
        }
        if settings.status.context_percent > 100 {
            return Err("status.context_percent must be between 0 and 100".into());
        }
        for turn in &settings.turns {
            if turn.prompt.is_some() && turn.contains.is_some() {
                return Err("Use prompt or contains on a turn, not both".into());
            }
            if let Some(ms) = turn.think_ms {
                duration(ms)?;
            }
            for step in &turn.steps {
                if let Step::Tool { command, .. } = step {
                    if settings.real_tool_calling && (command.is_empty() || command[0].is_empty()) {
                        return Err("Real tool calling requires a nonempty command array on every tool step".into());
                    }
                    if command.iter().any(|arg| arg.contains('\0')) {
                        return Err("Tool command arguments cannot contain NUL".into());
                    }
                }
                match step {
                    Step::Think { ms, .. }
                    | Step::Wait { ms }
                    | Step::Tool { ms, .. }
                    | Step::Edit { ms, .. } => duration(*ms)?,
                    Step::Message {
                        char_ms: Some(ms), ..
                    } => duration(*ms)?,
                    _ => (),
                }
                if let Step::Edit { path, line, .. } = step {
                    if path.trim().is_empty() || *line == 0 {
                        return Err(
                            "Edit steps require a path and a line number of at least 1".into()
                        );
                    }
                }
            }
        }
        Ok(settings)
    }
    pub fn select(
        &self,
        prompt: &str,
        turn: usize,
        sequence: &mut usize,
    ) -> (Vec<Step>, Option<String>, super::completion::Settings) {
        let matched = self.turns.iter().find(|t| {
            t.prompt.as_deref() == Some(prompt)
                || t.contains.as_ref().is_some_and(|s| prompt.contains(s))
        });
        let selected = matched.or_else(|| {
            let next = self
                .turns
                .iter()
                .filter(|t| t.prompt.is_none() && t.contains.is_none())
                .nth(*sequence);
            if next.is_some() {
                *sequence += 1;
            }
            next
        });
        let mut steps = selected.map(|t| t.steps.clone()).unwrap_or_default();
        if steps.is_empty() {
            steps.push(Step::Think {
                ms: selected.and_then(|t| t.think_ms).unwrap_or(self.think_ms),
                text: String::new(),
            });
        }
        if let Some(response) = selected.and_then(|t| t.response.as_ref()) {
            steps.push(Step::Message {
                text: response.clone(),
                char_ms: None,
            });
        } else if !steps.iter().any(|s| matches!(s, Step::Message { .. })) {
            steps.push(Step::Message {
                text: self.response.clone(),
                char_ms: None,
            });
        }
        for step in &mut steps {
            match step {
                Step::Think { text, .. } | Step::Message { text, .. } => {
                    *text = expand(text, prompt, turn)
                }
                Step::Tool {
                    name,
                    input,
                    output,
                    ..
                } => {
                    *name = clean(name);
                    *input = expand(input, prompt, turn);
                    *output = expand(output, prompt, turn);
                }
                Step::Edit {
                    path,
                    before,
                    after,
                    ..
                } => {
                    *path = expand(path, prompt, turn);
                    *before = expand(before, prompt, turn);
                    *after = expand(after, prompt, turn);
                }
                _ => (),
            }
        }
        (
            steps,
            selected
                .and_then(|t| t.title.as_ref())
                .map(|t| title(&expand(t, prompt, turn))),
            selected
                .map(|t| t.completion.inherit(&self.completion))
                .unwrap_or_else(|| self.completion.clone()),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rules_do_not_consume_sequence_and_templates_preserve_user_literals() {
        let s: Scenario = serde_json::from_str(r#"{"turns":[{"contains":"test","response":"Matched {prompt}"},{"response":"First {turn}"},{"response":"Second"}]}"#).unwrap();
        let mut sequence = 0;
        let (a, _, _) = s.select("test {turn}", 1, &mut sequence);
        assert!(matches!(&a[1], Step::Message { text, .. } if text == "Matched test {turn}"));
        assert_eq!(sequence, 0);
        let (b, _, _) = s.select("hello", 2, &mut sequence);
        assert!(matches!(&b[1], Step::Message { text, .. } if text == "First 2"));
        assert_eq!(sequence, 1);
        assert!(serde_json::from_str::<Scenario>(r#"{"thnk_ms":20}"#).is_err());
    }
    #[test]
    fn titles_are_single_line_and_unicode_safe() {
        assert_eq!(title("one\n two\x07"), "one two");
        assert_eq!(title(&"한".repeat(100)).chars().count(), 64);
    }
}
