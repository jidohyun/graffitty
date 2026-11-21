use super::{Provider, palette::faint};
use ratatui::{
    style::{Color, Style},
    text::Line,
};
use serde::Deserialize;
use sha2::{Digest, Sha256};

// Claude Code 2.1.296's bundled JS uses this ordered list and its message UUID's
// signed 32-bit string hash, converted to unsigned, to select a stable verb.
const CLAUDE_VERBS: [&str; 8] = [
    "Baked",
    "Brewed",
    "Churned",
    "Cogitated",
    "Cooked",
    "Crunched",
    "Sautéed",
    "Worked",
];

fn claude_verb(message_id: &str) -> &'static str {
    // JS charCodeAt visits UTF-16 code units, including surrogate pairs.
    let hash = message_id.encode_utf16().fold(0u32, |hash, unit| {
        hash.wrapping_mul(31).wrapping_add(u32::from(unit))
    });
    CLAUDE_VERBS[hash as usize % CLAUDE_VERBS.len()]
}

pub(super) fn message_id(seed: u64, turn: usize) -> String {
    // Keep the native UUID-based selection repeatable for recordings.
    let hash = Sha256::digest(format!("graffitty:completion:{seed}:{turn}"));
    uuid::Builder::from_random_bytes(hash[..16].try_into().expect("SHA-256 prefix"))
        .into_uuid()
        .to_string()
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub(super) struct Settings {
    pub elapsed_ms: Option<u64>,
    pub completed_at: Option<String>,
    pub verb: Option<String>,
}

impl Settings {
    pub fn inherit(&self, defaults: &Self) -> Self {
        Self {
            elapsed_ms: self.elapsed_ms.or(defaults.elapsed_ms),
            completed_at: self
                .completed_at
                .clone()
                .or_else(|| defaults.completed_at.clone()),
            verb: self.verb.clone().or_else(|| defaults.verb.clone()),
        }
    }

    pub fn finish(&self, elapsed_ms: u64, message_id: &str) -> Completion {
        Completion {
            elapsed_ms: self.elapsed_ms.unwrap_or(elapsed_ms),
            completed_at: self
                .completed_at
                .clone()
                .unwrap_or_else(|| jiff::Zoned::now().strftime("%-I:%M %p").to_string()),
            verb: self
                .verb
                .clone()
                .unwrap_or_else(|| claude_verb(message_id).into()),
        }
    }
}

#[derive(Clone, Debug)]
pub(super) struct Completion {
    pub elapsed_ms: u64,
    pub completed_at: String,
    pub verb: String,
}

impl Completion {
    fn label(&self, provider: Provider) -> String {
        let seconds = if provider == Provider::Claude && self.elapsed_ms >= 60_000 {
            self.elapsed_ms.saturating_add(500) / 1000
        } else {
            self.elapsed_ms / 1000
        };
        let (days, hours, minutes, seconds) = (
            seconds / 86400,
            seconds / 3600,
            (seconds % 3600) / 60,
            seconds % 60,
        );
        let duration = if days > 0 && provider == Provider::Claude {
            format!("{days}d {}h {minutes}m", hours % 24)
        } else if hours > 0 {
            format!("{hours}h {minutes}m {seconds}s")
        } else if minutes > 0 {
            format!("{minutes}m {seconds}s")
        } else if seconds == 0 && provider == Provider::Codex {
            "<1s".into()
        } else {
            format!("{seconds}s")
        };
        // Labels are a single line even if a recording config contains newlines.
        let clean = |s: &str| {
            super::scenario::clean(s)
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ")
        };
        let time = clean(&self.completed_at);
        if provider == Provider::Codex {
            format!("Worked for {duration} • {time}")
        } else {
            format!("{} for {duration} · done {time}", clean(&self.verb))
        }
    }

    pub fn lines(&self, provider: Provider, width: u16) -> Vec<Line<'static>> {
        let style = if provider == Provider::Claude {
            // Explicit gray matches the reference, independently of ANSI dim handling.
            Style::default().fg(Color::Rgb(148, 148, 148))
        } else {
            faint()
        };
        let prefix = if provider == Provider::Codex {
            "  "
        } else {
            "✻ "
        };
        textwrap::wrap(
            &self.label(provider),
            textwrap::Options::new(usize::from(width.max(3)))
                .initial_indent(prefix)
                .subsequent_indent("  "),
        )
        .into_iter()
        .map(|s| Line::from(s.into_owned()).style(style))
        .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verb_selection_matches_installed_javascript_hash_and_order() {
        // Expected values evaluated with 2.1.296's JS hash/selector.
        for (id, expected) in [
            ("", "Baked"),
            ("00000000-0000-0001-0000-000000000001", "Churned"),
            ("00000000-0000-0001-0000-000000000002", "Cogitated"),
            ("00000000-0000-0001-0000-000000000003", "Cooked"),
            ("00000000-0000-0001-0000-000000000004", "Crunched"),
            ("00000000-0000-0001-0000-000000000005", "Sautéed"),
            ("00000000-0000-0001-0000-000000000006", "Worked"),
            ("00000000-0000-0001-0000-000000000007", "Baked"),
            ("00000000-0000-0001-0000-000000000008", "Brewed"),
            ("한글😀", "Worked"),
        ] {
            assert_eq!(claude_verb(id), expected);
        }
    }

    #[test]
    fn generated_completion_ids_repeat_per_seed_and_turn_with_optional_verb_override() {
        let first = message_id(1, 1);
        assert_eq!(first, "1480eb3b-5fda-410c-bcc1-e99a414f2ab2");
        assert_eq!(first, message_id(1, 1));
        assert_ne!(first, message_id(2, 1));
        assert_ne!(first, message_id(1, 2));
        let mut settings = Settings::default();
        assert_eq!(settings.finish(0, &first).verb, "Cooked");
        assert_eq!(settings.finish(0, &message_id(1, 2)).verb, "Churned");
        settings.verb = Some("Baked".into());
        assert_eq!(settings.finish(0, &first).verb, "Baked");
    }

    #[test]
    fn provider_labels_match_duration_boundaries_and_fixed_times() {
        let completion = Completion {
            elapsed_ms: 1_120_000,
            completed_at: "11:13 PM".into(),
            verb: "Brewed".into(),
        };
        assert_eq!(
            completion.label(Provider::Codex),
            "Worked for 18m 40s • 11:13 PM"
        );
        let completion = Completion {
            elapsed_ms: 1_080_000,
            completed_at: "3:03 PM".into(),
            ..completion
        };
        assert_eq!(
            completion.lines(Provider::Claude, 80)[0].to_string(),
            "✻ Brewed for 18m 0s · done 3:03 PM"
        );
        for (ms, codex, claude) in [
            (0, "<1s", "0s"),
            (999, "<1s", "0s"),
            (1000, "1s", "1s"),
            (60_000, "1m 0s", "1m 0s"),
            (119_999, "1m 59s", "2m 0s"),
            (3_661_000, "1h 1m 1s", "1h 1m 1s"),
        ] {
            let c = Completion {
                elapsed_ms: ms,
                ..completion.clone()
            };
            assert_eq!(
                c.label(Provider::Codex),
                format!("Worked for {codex} • 3:03 PM")
            );
            assert_eq!(
                c.label(Provider::Claude),
                format!("Brewed for {claude} · done 3:03 PM")
            );
        }
    }
}
