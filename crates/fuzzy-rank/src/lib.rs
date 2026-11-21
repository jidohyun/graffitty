//! Tiered candidate ranking for completion lists.
//!
//! Each candidate takes the first tier its query reaches: exact, prefix,
//! substring, then fuzzy.
//!
//! A fuzzy result therefore implies that no candidate in the list matched the
//! query exactly, as a prefix or as a substring.

use frizbee::{CaseMatching, Config, Matcher, Matching};

/// How a candidate matched. Earlier tiers always sort first.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Tier {
    Exact,
    Prefix,
    Substring,
    Fuzzy,
    /// The query was empty, so every candidate is listed in input order.
    Unfiltered,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ranked {
    /// Position in the input list.
    pub index: usize,
    pub tier: Tier,
    pub score: u16,
    /// Ascending character (not byte) positions of the matched characters.
    pub indices: Vec<usize>,
}

/// Ranks `items` against `query`, case-insensitively. Within a tier, higher
/// scores come first and ties keep input order. With `typos`, the fuzzy tier
/// tolerates one missing character per four typed; short queries get none.
pub fn rank<S: AsRef<str>>(query: &str, items: &[S], typos: bool) -> Vec<Ranked> {
    if query.is_empty() {
        return (0..items.len())
            .map(|index| Ranked {
                index,
                tier: Tier::Unfiltered,
                score: 0,
                indices: Vec::new(),
            })
            .collect();
    }
    let allowed = if typos { query.chars().count() / 4 } else { 0 };
    let mut taken = vec![false; items.len()];
    let mut ranked = Vec::new();
    for (tier, matching) in [
        (Tier::Exact, Matching::Exact),
        (Tier::Prefix, Matching::Prefix),
        (Tier::Substring, Matching::Substring),
        (Tier::Fuzzy, Matching::Fuzzy),
    ] {
        let config = Config::default()
            .matching(matching)
            .casing(CaseMatching::Ignore)
            .max_typos(Some(u16::try_from(allowed).unwrap_or(u16::MAX)));
        // The default sort is descending score, then ascending input index.
        for found in Matcher::new(query, &config).match_list_indices(items) {
            let index = found.index as usize;
            if std::mem::replace(&mut taken[index], true) {
                continue;
            }
            ranked.push(Ranked {
                index,
                tier,
                score: found.score,
                indices: char_positions(items[index].as_ref(), &found.indices),
            });
        }
    }
    ranked
}

/// frizbee reports UTF-8 byte offsets; highlighting needs character positions.
fn char_positions(text: &str, bytes: &[u32]) -> Vec<usize> {
    let starts: Vec<usize> = text.char_indices().map(|(start, _)| start).collect();
    let mut positions: Vec<usize> = bytes
        .iter()
        .map(|&byte| byte as usize)
        .filter(|&byte| byte < text.len())
        .map(|byte| starts.partition_point(|&start| start <= byte) - 1)
        .collect();
    positions.sort_unstable();
    positions.dedup();
    positions
}

#[cfg(test)]
mod tests {
    use super::*;

    fn order<'a>(query: &str, items: &[&'a str], typos: bool) -> Vec<(&'a str, Tier)> {
        rank(query, items, typos)
            .into_iter()
            .map(|found| (items[found.index], found.tier))
            .collect()
    }

    #[test]
    fn tiers_sort_exact_prefix_substring_then_fuzzy() {
        let items = ["n-e-w", "renew", "pane", "new-pane-right", "new"];
        assert_eq!(
            order("new", &items, false),
            [
                ("new", Tier::Exact),
                ("new-pane-right", Tier::Prefix),
                ("renew", Tier::Substring),
                ("n-e-w", Tier::Fuzzy),
            ]
        );
    }

    #[test]
    fn each_item_appears_once_in_its_first_tier() {
        let ranked = rank("tab", &["tab", "tab"], false);
        assert_eq!(ranked.len(), 2);
        assert!(ranked.iter().all(|found| found.tier == Tier::Exact));
    }

    #[test]
    fn matching_ignores_case() {
        assert_eq!(
            order("New", &["new-terminal"], false),
            [("new-terminal", Tier::Prefix)]
        );
        assert_eq!(order("TAB", &["tab"], false), [("tab", Tier::Exact)]);
    }

    #[test]
    fn empty_query_lists_everything_in_input_order() {
        let ranked = rank("", &["b", "a"], false);
        assert_eq!(
            ranked.iter().map(|found| found.index).collect::<Vec<_>>(),
            [0, 1]
        );
        assert!(ranked.iter().all(|found| found.tier == Tier::Unfiltered));
    }

    #[test]
    fn equal_scores_keep_input_order() {
        let ranked = rank("ab", &["ab3", "ab1", "ab2"], false);
        assert_eq!(
            ranked.iter().map(|found| found.index).collect::<Vec<_>>(),
            [0, 1, 2]
        );
    }

    #[test]
    fn numbers_never_match_other_numbers() {
        assert_eq!(
            order("12", &["13", "1.2", "120", "12", "21"], false),
            [("12", Tier::Exact), ("120", Tier::Prefix), ("1.2", Tier::Fuzzy)]
        );
    }

    #[test]
    fn typos_need_a_long_enough_query() {
        assert!(rank("terminal", &["termnal"], false).is_empty());
        assert_eq!(
            order("terminal", &["termnal"], true),
            [("termnal", Tier::Fuzzy)]
        );
        assert!(rank("abc", &["abd"], true).is_empty());
    }

    #[test]
    fn highlight_positions_count_characters_not_bytes() {
        let title = "😀 nvim · 프로젝트";
        let found = &rank("vim", &[title], false)[0];
        assert_eq!(found.tier, Tier::Substring);
        assert_eq!(found.indices, [3, 4, 5]);
        let found = &rank("프로", &[title], false)[0];
        assert_eq!(found.tier, Tier::Substring);
        assert_eq!(found.indices, [9, 10]);
        let found = &rank("nvm", &[title], false)[0];
        assert_eq!(found.tier, Tier::Fuzzy);
        assert_eq!(found.indices, [2, 3, 5]);
    }
}
