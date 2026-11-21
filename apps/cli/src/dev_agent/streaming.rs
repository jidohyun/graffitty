//! Word arrivals are scheduled once so repaint frequency cannot change playback.
use serde::Deserialize;
use unicode_segmentation::UnicodeSegmentation;

#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq)]
#[serde(rename_all = "snake_case")]
pub(super) enum Mode {
    #[default]
    Words,
    Characters,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub(super) struct Settings {
    pub mode: Mode,
    pub jitter_percent: u8,
    pub seed: u64,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            mode: Mode::Words,
            jitter_percent: 45,
            seed: 1,
        }
    }
}

#[derive(Debug, PartialEq)]
pub(super) struct Schedule {
    arrivals: Vec<(u64, usize)>,
}

impl Schedule {
    pub fn new(text: &str, char_ms: u64, settings: &Settings, turn: usize, step: usize) -> Self {
        if text.is_empty() || char_ms == 0 {
            return Self {
                arrivals: vec![(0, text.len())],
            };
        }
        let mut ends: Vec<usize> = if settings.mode == Mode::Words {
            text.unicode_word_indices()
                .skip(1)
                .map(|(i, _)| i)
                .collect()
        } else {
            text.grapheme_indices(true)
                .skip(1)
                .map(|(i, _)| i)
                .collect()
        };
        ends.push(text.len());
        let mut state = settings
            .seed
            .wrapping_add((turn as u64).wrapping_mul(0x9e3779b97f4a7c15))
            .wrapping_add(step as u64);
        let (mut start, mut at, mut pause) = (0, 0u64, 0u64);
        let mut arrivals = Vec::with_capacity(ends.len());
        for end in ends {
            let chunk = &text[start..end];
            // SplitMix64: stable across platforms; no wall clock or external RNG.
            state = state.wrapping_add(0x9e3779b97f4a7c15);
            let mut sample = state;
            sample = (sample ^ (sample >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
            sample = (sample ^ (sample >> 27)).wrapping_mul(0x94d049bb133111eb);
            sample ^= sample >> 31;
            let jitter = u64::from(settings.jitter_percent.min(100));
            let percent = 100 - jitter + sample % (2 * jitter + 1);
            let base = char_ms.saturating_mul(chunk.chars().count() as u64);
            let delay = base.saturating_mul(percent) / 100;
            at = at.saturating_add(delay.max(1)).saturating_add(pause);
            arrivals.push((at, end));
            pause = if settings.mode == Mode::Words
                && chunk
                    .trim_end()
                    .ends_with(['.', '!', '?', ':', ';', '。', '！', '？'])
            {
                char_ms.saturating_mul(6 + sample % 9)
            } else {
                0
            };
            start = end;
        }
        Self { arrivals }
    }

    pub fn duration(&self) -> u64 {
        self.arrivals.last().map_or(0, |&(at, _)| at)
    }

    pub fn visible<'a>(&self, text: &'a str, elapsed_ms: u64) -> &'a str {
        let count = self.arrivals.partition_point(|&(at, _)| at <= elapsed_ms);
        let end = count.checked_sub(1).map_or(0, |i| self.arrivals[i].1);
        &text[..end]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_arrive_whole_with_repeatable_jitter_and_unicode_intact() {
        let text = "One two six ten. café 한글 👩🏽‍💻!";
        let settings = Settings::default();
        let a = Schedule::new(text, 20, &settings, 1, 0);
        assert_eq!(a, Schedule::new(text, 20, &settings, 1, 0));
        assert_ne!(a, Schedule::new(text, 20, &settings, 2, 0));
        let first = a.arrivals[0].0;
        assert_eq!(a.visible(text, first - 1), "");
        assert_eq!(a.visible(text, first), "One ");
        assert_eq!(a.visible(text, a.duration()), text);
        assert!(
            a.arrivals
                .windows(2)
                .all(|w| w[0].0 < w[1].0 && text.is_char_boundary(w[1].1))
        );
        let delays: std::collections::HashSet<_> = a.arrivals[..4]
            .windows(2)
            .map(|w| w[1].0 - w[0].0)
            .collect();
        assert!(delays.len() > 1);
        assert_eq!(
            Schedule::new(text, 0, &settings, 1, 0).visible(text, 0),
            text
        );
    }

    #[test]
    fn character_mode_preserves_combining_characters_and_fixed_pacing() {
        let text = "e\u{301}한";
        let settings = Settings {
            mode: Mode::Characters,
            jitter_percent: 0,
            ..Settings::default()
        };
        let schedule = Schedule::new(text, 10, &settings, 1, 0);
        assert_eq!(schedule.visible(text, 19), "");
        assert_eq!(schedule.visible(text, 20), "e\u{301}");
        assert_eq!(schedule.visible(text, 30), text);
    }
}
