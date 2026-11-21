use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use graffitty_fuzzy_rank::Tier;

/// Completion ranking for GDScript; see `graffitty_fuzzy_rank::rank`.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct FuzzyRanker {
    base: Base<RefCounted>,
    items: Vec<String>,
}

#[godot_api]
impl IRefCounted for FuzzyRanker {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, items: Vec::new() }
    }
}

#[godot_api]
impl FuzzyRanker {
    #[func]
    fn set_items(&mut self, items: PackedStringArray) {
        self.items = items.as_slice().iter().map(GString::to_string).collect();
    }

    /// Matches as `{index, tier, score, indices}`, best first. Tiers: 0 exact,
    /// 1 prefix, 2 substring, 3 fuzzy, 4 unfiltered (empty query). `indices`
    /// are ascending character positions for highlighting.
    #[func]
    fn rank(&self, query: GString, typos: bool) -> Array<VarDictionary> {
        let mut result = Array::new();
        for found in graffitty_fuzzy_rank::rank(&query.to_string(), &self.items, typos) {
            let tier = match found.tier {
                Tier::Exact => 0,
                Tier::Prefix => 1,
                Tier::Substring => 2,
                Tier::Fuzzy => 3,
                Tier::Unfiltered => 4,
            };
            let indices: Vec<i32> = found
                .indices
                .iter()
                .map(|&position| i32::try_from(position).unwrap_or(i32::MAX))
                .collect();
            let mut entry = VarDictionary::new();
            entry.set("index", i64::try_from(found.index).unwrap_or(i64::MAX));
            entry.set("tier", tier);
            entry.set("score", i64::from(found.score));
            entry.set("indices", &PackedInt32Array::from(indices.as_slice()));
            result.push(&entry);
        }
        result
    }
}
