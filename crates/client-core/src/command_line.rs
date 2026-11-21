//! Completion semantics shared with the reference prefix command line.
//! Selection follows stable identity, never a tab's changing ordinal.
use graffitty_fuzzy_rank::{Tier, rank};
use serde::Serialize;
use serde_json::Value;

#[derive(Clone, Debug, Serialize)]
pub struct Candidate {
    pub identity: String,
    pub label: String,
    pub title: String,
    pub action: Value,
    pub hidden: bool,
    pub alias: bool,
    /// Shortcut hint shown beside the title (CommandLineModel._shortcut_text).
    pub detail: String,
    /// Checked menu state, shown as "✓ " before the title.
    pub checked: bool,
}

#[derive(Clone, Debug, Serialize)]
pub struct Row {
    pub candidate: Candidate,
    pub tier: usize,
    pub indices: Vec<usize>,
}

#[derive(Clone, Default, Debug, Serialize)]
pub struct Model {
    pub open: bool,
    pub text: String,
    pub query: String,
    pub rows: Vec<Row>,
    pub selected: Option<usize>,
    pub status: String,
    #[serde(skip)]
    chosen: Option<(String, usize)>,
    #[serde(skip)]
    chosen_lost: bool,
    #[serde(skip)]
    cycling: bool,
}

pub fn number_mode(query: &str) -> bool {
    query.starts_with(['%', '@']) || query.as_bytes().first().is_some_and(u8::is_ascii_digit)
}

impl Model {
    pub fn set_text(&mut self, text: String) {
        self.text = text.clone();
        self.query = text;
        self.selected = None;
        self.chosen = None;
        self.chosen_lost = false;
        self.cycling = false;
    }

    pub fn refresh(&mut self, candidates: Vec<Candidate>) {
        let candidates: Vec<_> = candidates.into_iter()
            .filter(|candidate| !self.query.is_empty() || !candidate.alias).collect();
        let labels: Vec<_> = candidates.iter().map(|c| c.label.as_str()).collect();
        let targets = number_mode(&self.query) || self.query.starts_with('$');
        let needle = if targets {self.query.clone()} else {self.query.replace([' ', '_'], "-")};
        let previous = self.selected.unwrap_or(0);
        self.rows = rank(&needle, &labels, !targets).into_iter().map(|found| Row {
            candidate: candidates[found.index].clone(), tier: found.tier as usize, indices: found.indices,
        }).collect();
        self.selected = None;
        if let Some((identity, tier)) = self.chosen.as_ref() {
            self.selected = self.rows.iter().position(|row| &row.candidate.identity == identity);
            if self.selected.is_none() {
                if let Some(candidate) = candidates.iter().find(|candidate| &candidate.identity == identity) {
                    let position = previous.min(self.rows.len());
                    self.rows.insert(position, Row {candidate: candidate.clone(), tier: *tier, indices: vec![]});
                    self.selected = Some(position);
                }
            }
            if self.selected.is_none() {
                self.chosen = None;
                self.chosen_lost = true;
            } else if self.cycling {
                self.text = self.rows[self.selected.unwrap()].candidate.label.clone();
            }
        }
        self.update_status();
    }

    pub fn select(&mut self, index: usize) {
        if let Some(row) = self.rows.get(index) {
            self.selected = Some(index);
            self.chosen = Some((row.candidate.identity.clone(), row.tier));
            self.chosen_lost = false;
            self.update_status();
        }
    }

    pub fn move_selection(&mut self, step: i32, cycle: bool) {
        if self.rows.is_empty() {return;}
        let length = self.rows.len() as i64;
        let index = self.selected.map_or(if step >= 0 {0} else {length - 1},
            |index| (index as i64 + step as i64).rem_euclid(length));
        self.select(index as usize);
        if cycle {
            self.cycling = true;
            self.text = self.rows[index as usize].candidate.label.clone();
        }
    }

    pub fn accepted(&self) -> Option<&Candidate> {
        if self.chosen_lost {return None;}
        if let Some(index) = self.selected {return self.rows.get(index).map(|row| &row.candidate);}
        self.rows.first().filter(|row| !self.query.is_empty() && row.tier <= Tier::Substring as usize)
            .map(|row| &row.candidate)
    }

    fn update_status(&mut self) {
        self.status = if self.chosen_lost {"The chosen row closed: choose again"}
            else if self.query.is_empty() {""}
            else if self.rows.is_empty() {"No matches"}
            else if self.accepted().is_none() {"Only fuzzy matches: Tab to choose"}
            else {""}.into();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn candidate(id: &str, label: &str) -> Candidate {
        Candidate {identity:id.into(),label:label.into(),title:label.into(),action:json!({"id":id}),hidden:false,alias:false,detail:String::new(),checked:false}
    }
    #[test]
    fn fuzzy_commands_require_explicit_choice_and_cycle_keeps_the_query() {
        let mut model=Model::default();
        model.set_text("npr".into());
        model.refresh(vec![candidate("split", "new-pane-right"),candidate("tab", "new-terminal")]);
        assert!(model.accepted().is_none());
        model.move_selection(1,true);
        assert_eq!(model.text,"new-pane-right");
        assert_eq!(model.query,"npr");
        assert_eq!(model.accepted().unwrap().identity,"split");
        model.set_text("new-pane-r".into());
        model.refresh(vec![candidate("split", "new-pane-right")]);
        assert_eq!(model.accepted().unwrap().identity,"split");
    }
    #[test]
    fn renumbering_keeps_identity_and_a_closed_selection_never_falls_through() {
        let mut model=Model::default();
        model.set_text("2".into());
        model.refresh(vec![candidate("tab:8","2"),candidate("tab:9","3")]);
        model.move_selection(1,true);
        model.refresh(vec![candidate("tab:9","2"),candidate("tab:8","3")]);
        assert_eq!(model.text,"3");
        assert_eq!(model.accepted().unwrap().identity,"tab:8");
        model.refresh(vec![candidate("tab:9","2")]);
        assert!(model.accepted().is_none());
        assert!(model.status.contains("closed"));
        model.move_selection(1,false);
        assert_eq!(model.accepted().unwrap().identity,"tab:9");
    }
    #[test]
    fn empty_query_does_not_execute_and_hides_aliases() {
        let mut model=Model::default();
        let mut alias=candidate("split","split-right");alias.alias=true;
        model.refresh(vec![candidate("split","new-pane-right"),alias]);
        assert_eq!(model.rows.len(),1);
        assert!(model.accepted().is_none());
        assert!(number_mode("%18"));assert!(number_mode("@7.2"));assert!(number_mode("2.1"));
        assert!(!number_mode("$work"));
    }
}
