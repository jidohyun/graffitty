//! Delivery inspection is metadata-only and never takes or acknowledges work.
use crate::localization::text;
use anyhow::{Context, Result, bail, ensure};
use serde::Serialize;
use serde_json::{Value, json};

#[derive(Default)]
pub struct Inspector {
    pub open: bool,
    pub edge: String,
    pub pending_only: bool,
    pub selected: String,
    pub new_runs: bool,
    pub limit: String,
    dirty: bool,
    budget_run: String,
    pub stop: crate::graph_stop::Editor,
}

#[derive(Clone, PartialEq, Serialize)]
pub struct Row {
    pub id: String,
    pub status: String,
    pub queued: String,
    pub updated: String,
    pub kind: String,
    pub pending: bool,
    pub failed: bool,
    pub sent: bool,
}

#[derive(Serialize)]
pub struct Snapshot {
    pub open: bool,
    pub edge: String,
    pub summary: String,
    pub pending_only: bool,
    pub selected: String,
    pub rows: Vec<Row>,
    pub details: String,
    pub run: String,
    pub new_runs: bool,
    pub limit: String,
    pub count: u64,
    pub available: bool,
    pub can_apply: bool,
    pub can_reset: bool,
    pub budget_note: String,
    pub note: String,
    pub stop: crate::graph_stop::Snapshot,
}

fn string<'a>(value: &'a Value, key: &str) -> &'a str {
    value[key].as_str().unwrap_or("")
}

pub fn limit(text: &str) -> Option<u64> {
    text.trim().strip_prefix('+').unwrap_or(text.trim()).parse::<u64>().ok()
        .filter(|n| *n > 0 && *n <= i64::MAX as u64)
}

fn clock(value: &Value, full: bool) -> String {
    value.as_f64().filter(|v| v.is_finite() && *v >= 0. && *v < 253402300800.)
        .and_then(|seconds| chrono::DateTime::from_timestamp(seconds as i64, 0))
        .map(|time| time.format(if full {"%Y-%m-%d %H:%M:%S UTC"} else {"%H:%M:%S UTC"}).to_string())
        .unwrap_or_else(|| "—".into())
}

fn status(language: &str, source: &str) -> String {
    for prefix in ["failed: ", "cancel failed: ", "cancelled: "] {
        if let Some(reason) = source.strip_prefix(prefix) {
            return text(language, &format!("{prefix}%s")).replace("%s", &text(language, reason));
        }
    }
    text(language, source).into_owned()
}

/// Reference graph hover text: connection and delivery metadata only. Reading
/// a tooltip must never take queued work or expand transcript/message payloads.
pub fn edge_hint(graph:&Value,key:&str,language:&str)->String {
    let Some(edge)=graph["edges"].as_array().into_iter().flatten().find(|edge|
        format!("{}/{}>{}/{}",string(edge,"from"),string(edge,"from_port"),string(edge,"to"),string(edge,"to_port"))==key) else {return String::new();};
    let tr=|source:&str|text(language,source).into_owned();
    let endpoint=|output:bool| {
        let id=string(edge,if output {"from"} else {"to"});
        let node=graph["nodes"].as_array().into_iter().flatten().find(|node|node["node"]==id);
        let port=string(edge,if output {"from_port"} else {"to_port"});
        let title=node.map_or(id,|node|node["title"].as_str().filter(|title|!title.is_empty())
            .or_else(||node["manifest"]["name"].as_str()).unwrap_or(id));
        let name=node.and_then(|node|node["manifest"][if output {"outputs"} else {"inputs"}].as_array())
            .and_then(|ports|ports.iter().find(|entry|entry["id"]==port))
            .and_then(|port|port["name"].as_str()).filter(|name|!name.is_empty()).unwrap_or(port);
        if name.is_empty() {title.to_owned()} else {format!("{title} · {name}")}
    };
    let counts=&graph["journal"]["by_edge"][key];
    let pending=counts["pending"].as_u64().unwrap_or(0);
    let total=counts["total"].as_u64().unwrap_or_else(||graph["journal"]["events"].as_array().into_iter().flatten().filter(|row|row["edge"]==key).count() as u64);
    let mut lines=vec![endpoint(true),format!("→ {}",endpoint(false)),
        tr("%d pending · %d recorded deliveries").replacen("%d",&pending.to_string(),1).replacen("%d",&total.to_string(),1),
        tr("Click this wire for delivery history · Double-click to add a reroute.")];
    if edge["muted"]==true {lines.push(tr("Paused"));}
    if let Some(stop)=edge["stop_at"].as_f64().filter(|at|*at>0.) {
        if stop<=crate::graph_stop::now() {lines.push(tr("Stopped: stop time reached"));}
        else if let Some(date)=chrono::DateTime::from_timestamp(stop as i64,0) {
            lines.push(tr("Stops at %s (local time)").replace("%s",&date.with_timezone(&chrono::Local).format("%Y-%m-%d %H:%M:%S").to_string()));
        }
    }
    for (field,label) in [("contains","Contains: %s"),("outcome","Outcome: %s")] {
        let value=string(edge,field);
        if !value.is_empty() {lines.push(tr(label).replace("%s",&if field=="outcome" {tr(value)}else{value.to_owned()}));}
    }
    if let Some(receipt)=graph["receipts"].as_array().into_iter().flatten().rev().find(|row|row["edge"]==key) {
        lines.push(tr("Last delivery: %s").replace("%s",&status(language,string(receipt,"status"))));
        let message=string(receipt,"message");
        if !message.is_empty() {lines.push(message.into());}
    }
    lines.join("\n")
}

impl Inspector {
    pub fn inspect(&mut self, edge: String) {
        *self = Self {open: true, edge, ..Default::default()};
    }

    fn rows<'a>(&self, graph: &'a Value) -> Vec<&'a Value> {
        graph["journal"]["events"].as_array().into_iter().flatten()
            .filter(|row| row["edge"] == self.edge && (!self.pending_only || row["pending"] == true))
            .collect()
    }

    fn selected_run<'a>(&self, graph: &'a Value) -> &'a str {
        self.rows(graph).iter().find(|row| row["event_id"] == self.selected)
            .map_or("", |row| string(row, "run_id"))
    }

    pub fn connection<'a>(&self, graph: &'a Value) -> Option<&'a Value> {
        graph["edges"].as_array().into_iter().flatten().find(|edge|
            format!("{}/{}>{}/{}",string(edge,"from"),string(edge,"from_port"),string(edge,"to"),string(edge,"to_port")) == self.edge)
    }

    pub fn refresh(&mut self, graph: &Value) {
        if !self.open {return;}
        let connection=self.connection(graph);
        self.stop.refresh(connection);
        let rows = self.rows(graph);
        if !rows.iter().any(|row| row["event_id"] == self.selected) {
            self.selected = rows.first().map_or("", |row| string(row, "event_id")).into();
        }
        let run = if self.new_runs {""} else {self.selected_run(graph)};
        let available = run.is_empty() || graph["runs"][run]["available"] == true;
        if !self.dirty || self.budget_run != run || !available {
            self.limit = if run.is_empty() {&graph["limits"]["run_messages"]} else {&graph["runs"][run]["limit"]}
                .as_u64().unwrap_or(0).to_string();
            self.dirty = false;
        }
        self.budget_run = run.into();
    }

    /// Returns an optional owner RPC, keeping all validation and scope rules
    /// identical in both UI toolkits. Owner errors leave the user's draft intact.
    pub fn command(&mut self, graph: &Value, command: &str, value: &str) -> Result<Option<(&'static str, Value)>> {
        self.refresh(graph);
        if command.starts_with("stop-") {
            let connection=self.connection(graph);
            return Ok(self.stop.command(connection,command,value,crate::graph_stop::now()).map(|request|("graph.connect",request)));
        }
        let run = self.selected_run(graph).to_owned();
        match command {
            "close" => self.open = false,
            "pending" => self.pending_only = value == "true",
            "select" => {
                ensure!(self.rows(graph).iter().any(|row| row["event_id"] == value), "Delivery is no longer available");
                self.selected = value.into();
            }
            "scope" => {self.new_runs = value == "new"; self.dirty = false;}
            "limit" => {
                // The first delivery must not silently retarget an in-flight
                // edit of the default to the newly selected run.
                if run.is_empty() {self.new_runs = true;}
                self.limit = value.into(); self.dirty = true;
            }
            "apply" => {
                let limit = limit(&self.limit).context("Enter a positive whole-number limit.")?;
                return Ok(Some(if self.new_runs || run.is_empty() {
                    ("graph.run.default", json!({"limit":limit}))
                } else {("graph.run.limit", json!({"run_id":run,"limit":limit}))}));
            }
            "reset" => {
                ensure!(!self.new_runs && !run.is_empty(), "Select a run first");
                return Ok(Some(("graph.run.reset", json!({"run_id":run}))));
            }
            _ => bail!("Unknown queue inspector command"),
        }
        self.refresh(graph);
        Ok(None)
    }

    pub fn applied(&mut self, graph: &Value) {self.dirty = false; self.refresh(graph);}

    pub fn snapshot(&self, graph: &Value, language: &str) -> Snapshot {
        let tr = |source: &str| text(language, source).into_owned();
        let rows = self.rows(graph);
        let selected = rows.iter().find(|row| row["event_id"] == self.selected);
        let run = selected.map_or("", |row| string(row, "run_id"));
        let defaults = self.new_runs || run.is_empty();
        let usage = &graph["runs"][run];
        let available = if defaults {graph["limits"]["run_messages"].as_u64().is_some()} else {usage["available"] == true};
        let count = if defaults {0} else {usage["count"].as_u64().unwrap_or(0)};
        let connected = graph["edges"].as_array().into_iter().flatten().any(|edge|
            format!("{}/{}>{}/{}",string(edge,"from"),string(edge,"from_port"),string(edge,"to"),string(edge,"to_port")) == self.edge);
        let counts = &graph["journal"]["by_edge"][&self.edge];
        let pending = counts["pending"].as_u64().unwrap_or(0);
        let total = counts["total"].as_u64().unwrap_or(rows.len() as u64);
        let removed = if connected {String::new()} else {tr(" · connection removed")};
        let visible = graph["journal"]["events"].as_array().into_iter().flatten().filter(|row|row["edge"]==self.edge).count() as u64;
        let omitted = if total>visible {tr(" · %d omitted").replace("%d",&(total-visible).to_string())} else {String::new()};
        let summary = format!("{}\n{}{}{}", self.edge,
            tr("%d pending · %d recorded").replacen("%d", &pending.to_string(),1).replacen("%d", &total.to_string(),1),removed,omitted);
        let mut details = tr("Select a delivery to see its timestamped history.");
        if let Some(row) = selected {
            details = format!("{}\n\n{}\n", status(language,string(row,"status")), tr("Timeline"));
            for change in row["transitions"].as_array().into_iter().flatten() {
                details += &format!("{}  {}\n",clock(&change["at"],true),status(language,string(change,"status")));
            }
            details += &format!("\n{}: {}\n{}: {}\n{}: {}\n{}: {}",tr("Run"),run,tr("Event"),self.selected,tr("Queued"),clock(&row["queued_at"],true),tr("Updated"),clock(&row["updated_at"],true));
        }
        let budget_note = if !available {
            tr("This run is no longer available. Choose New runs to set the default.")
        } else if limit(&self.limit).is_none() {tr("Enter a positive whole-number limit.")}
        else if defaults {tr("Default for new runs across all connections. Existing runs keep their limits.")}
        else {tr("Run %s spans connections. Reset preserves queued messages and history.").replace("%s",run)};
        Snapshot {
            open:self.open,edge:self.edge.clone(),summary,pending_only:self.pending_only,selected:self.selected.clone(),
            rows:rows.iter().map(|row| {
                let source=string(row,"status");
                let failed=source.starts_with("failed") || source.starts_with("cancel failed");
                let sent=matches!(source,"sent to receiver" | "submitted" | "delivered");
                let icon=if failed {"[!]"}else if source.starts_with("cancelled"){"[-]"}
                    else if row["pending"]==true {if source=="queued in Graffitty" {"[ ]"}else{"[~]"}}
                    else if sent {"[x]"}else{"[?]"};
                Row {
                id:string(row,"event_id").into(),status:format!("{icon} {}",status(language,source)),
                queued:clock(&row["queued_at"],false),updated:clock(&row["updated_at"],false),kind:tr(string(row,"kind")),
                pending:row["pending"]==true,failed,sent,
            }}).collect(),details,run:run.into(),new_runs:defaults,limit:self.limit.clone(),count,available,
            can_apply:available && limit(&self.limit).is_some(),can_reset:available && !defaults && count>0,budget_note,
            note:tr("Sent means handed to the receiver, not model completion. History keeps the latest 200 finished deliveries."),
            stop:self.stop.snapshot(self.connection(graph),language,crate::graph_stop::now()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn hover_uses_authoritative_metadata_without_expanding_queued_content() {
        let mut graph=json!({"nodes":[{"node":"%1","title":"Source","manifest":{"outputs":[{"id":"out","name":"Answer"}]}},
            {"node":"%2","manifest":{"name":"Reviewer","inputs":[{"id":"in","name":"Prompt"}]}}],
            "edges":[{"from":"%1","from_port":"out","to":"%2","to_port":"in","muted":true,"stop_at":1,"contains":"APPROVED"}],
            "journal":{"by_edge":{"%1/out>%2/in":{"pending":2,"total":7}},"events":[{"edge":"%1/out>%2/in","text":"PRIVATE_MESSAGE"}]},
            "queues":{"%2":[{"text":"PRIVATE_MESSAGE"}]},"receipts":[{"edge":"%1/out>%2/in","status":"submitted","message":"Native transport accepted"}]});
        let before=graph.clone();let hint=edge_hint(&graph,"%1/out>%2/in","en-US");
        for expected in ["Source · Answer","→ Reviewer · Prompt","2 pending · 7 recorded deliveries","Paused","Stopped: stop time reached","Contains: APPROVED","Last delivery: submitted","Native transport accepted"] {
            assert!(hint.contains(expected),"Missing {expected}: {hint}");
        }
        assert!(!hint.contains("PRIVATE_MESSAGE"));assert_eq!(graph,before);
        assert!(edge_hint(&graph,"%1/out>%2/in","ko").contains("대기"));
        graph["edges"]=json!([]);assert!(edge_hint(&graph,"%1/out>%2/in","en-US").is_empty());
    }
    fn graph() -> Value {json!({"limits":{"run_messages":100},"runs":{"r":{"count":3,"limit":10,"available":true}},
        "journal":{"events":[{"event_id":"a","edge":"wire","run_id":"r","pending":true,"queued_at":0,"status":"queued in Graffitty"},
                             {"event_id":"b","edge":"other","run_id":"s","pending":true}]}})}
    #[test]
    fn scopes_preserve_drafts_and_exact_integer_limits() {
        let mut model=Inspector::default();model.inspect("wire".into());let mut graph=graph();
        let entries=graph["journal"]["events"].take();graph["journal"]["events"]=json!([]);
        model.command(&graph,"limit","9223372036854775807").unwrap();
        graph["journal"]["events"]=entries;model.refresh(&graph);
        assert_eq!(model.command(&graph,"apply","").unwrap(),Some(("graph.run.default",json!({"limit":i64::MAX}))));
        model.command(&graph,"scope","selected").unwrap();assert_eq!(model.limit,"10");
        model.command(&graph,"limit","9223372036854775808").unwrap();assert!(model.command(&graph,"apply","").is_err());
        assert!(!model.snapshot(&graph,"en-US").can_apply);
        assert_eq!(model.command(&graph,"reset","").unwrap(),Some(("graph.run.reset",json!({"run_id":"r"}))));
        for invalid in ["0","-1","NaN","1.5","1e3",""] {assert!(limit(invalid).is_none());}
        assert_eq!(limit(" +00012 "),Some(12));
    }
    #[test]
    fn filter_and_retired_run_keep_metadata_without_consuming_work() {
        let mut graph=graph();let before=graph.clone();let mut model=Inspector::default();model.inspect("wire".into());model.refresh(&graph);
        assert_eq!(model.snapshot(&graph,"en-US").rows.len(),1);assert_eq!(model.selected,"a");
        model.command(&graph,"pending","true").unwrap();assert_eq!(graph,before);
        graph["runs"]=json!({});model.refresh(&graph);assert!(!model.snapshot(&graph,"en-US").available);
        graph["journal"]["events"][0]["pending"]=json!(false);model.refresh(&graph);
        assert!(model.snapshot(&graph,"en-US").rows.is_empty());
        assert_eq!(clock(&json!(0),true),"1970-01-01 00:00:00 UTC");
    }
}
