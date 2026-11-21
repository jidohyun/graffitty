use sha2::{Digest, Sha256};

// Ordered defaults extracted from installed Claude Code 2.1.296's getSpinnerVerbs.
// That version samples once when resetting a turn and retains defaultVerb across
// thinking/streaming/tool phases. Explicit status messages take precedence.
const CLAUDE_VERBS: &str = include_str!("claude_spinner_verbs.txt");

pub(super) fn claude_verb(seed: u64, turn: usize) -> &'static str {
    let hash = Sha256::digest(format!("graffitty:activity:{seed}:{turn}"));
    let sample = u64::from_be_bytes(hash[..8].try_into().expect("SHA-256 prefix")) >> 11;
    // Substitute a seeded 53-bit fraction for Math.random() in lodash's sample.
    let random = sample as f64 / (1u64 << 53) as f64;
    let index = (random * CLAUDE_VERBS.lines().count() as f64).floor() as usize;
    CLAUDE_VERBS.lines().nth(index).unwrap_or("Working")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn samples_installed_list_repeatably_without_using_the_older_checkout() {
        let words: Vec<_> = CLAUDE_VERBS.lines().collect();
        assert_eq!(words.len(), 189);
        for word in [
            "Kerfuffling",
            "Onioning",
            "Polishing",
            "Philosophizing",
            "Unraveling",
            "Transmogrifying",
        ] {
            assert!(words.contains(&word));
        }
        let sequence = |seed| {
            (1..=20)
                .map(|turn| claude_verb(seed, turn))
                .collect::<Vec<_>>()
        };
        assert_eq!(sequence(1), sequence(1));
        assert_ne!(sequence(1), sequence(2));
        assert!(sequence(1).iter().all(|word| words.contains(word)));
        assert!(
            sequence(1)
                .into_iter()
                .collect::<std::collections::HashSet<_>>()
                .len()
                > 1
        );
    }
}
