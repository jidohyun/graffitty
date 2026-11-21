//! Recovery preserves wiring and ports, never process identities or queued work.
use super::*;

impl Graph {
    pub fn checkpoint(&self) -> Value {
        let nodes: Vec<_> = self
            .nodes
            .iter()
            .map(|(key, node)| {
                let mut inputs = ports(node, false);
                let mut outputs = ports(node, true);
                // A provider may have exited while its wiring remains in the workspace.
                // Retain the connected ports so an offline node is still restorable.
                for edge in self.edges.values() {
                    if edge["to"] == *key && !inputs.iter().any(|p| p["id"] == edge["to_port"]) {
                        inputs.push(json!({"id":edge["to_port"]}));
                    }
                    if edge["from"] == *key && !outputs.iter().any(|p| p["id"] == edge["from_port"])
                    {
                        outputs.push(json!({"id":edge["from_port"],"mode":
                        if edge["turn_completed"] == true { "turn_completed" }
                        else if edge["send"] == true { "send" } else { "read" }}));
                    }
                }
                json!({"node":key,"manifest":{"inputs":inputs,"outputs":outputs}})
            })
            .collect();
        let edges: Vec<_> = self
            .edges
            .values()
            .map(|edge| {
                let mut edge = edge.clone();
                edge.as_object_mut().unwrap().remove("revision");
                edge
            })
            .collect();
        json!({"nodes":nodes,"edges":edges,"run_messages":self.default_run_limit})
    }

    /// Validate the entire saved graph before changing any live ports or links.
    /// Only mapped nodes already belonging to this graph can receive wiring.
    pub fn restore_checkpoint(
        &mut self,
        saved: &Value,
        ids: &HashMap<String, String>,
    ) -> Result<()> {
        let nodes = saved["nodes"]
            .as_array()
            .ok_or("Invalid saved graph nodes")?;
        let edges = saved["edges"]
            .as_array()
            .ok_or("Invalid saved graph connections")?;
        let mut staged = Self::with_settings(self.settings.clone());
        let mut seen = HashSet::new();
        for node in nodes {
            let old = node["node"].as_str().ok_or("Invalid saved graph node")?;
            let key = ids
                .get(old)
                .ok_or("Saved graph node has no restored pane")?;
            let id = crate::pane_id::parse(key).ok_or("Invalid restored pane")?;
            if !seen.insert(key.clone()) || !self.nodes.contains_key(key) {
                return Err("Duplicate or foreign restored graph node".into());
            }
            staged.add(id, String::new());
            staged.nodes.get_mut(key).unwrap()["manifest"] = manifest(&node["manifest"])?;
        }
        for edge in edges {
            let mut edge = edge.clone();
            for field in ["from", "to"] {
                let old = edge[field]
                    .as_str()
                    .ok_or("Invalid saved connection endpoint")?;
                edge[field] = json!(
                    ids.get(old)
                        .ok_or("Saved connection has no restored pane")?
                );
            }
            let id =
                crate::pane_id::parse(string(&edge, "from")).ok_or("Invalid saved connection")?;
            staged.dispatch(id, "graph.connect", &edge)?;
        }
        let limit = saved
            .get("run_messages")
            .map(|v| {
                v.as_u64()
                    .filter(|v| *v > 0 && *v <= i64::MAX as u64)
                    .and_then(|v| usize::try_from(v).ok())
                    .ok_or("Invalid saved run limit")
            })
            .transpose()?;
        for (key, node) in staged.nodes {
            let live = self.nodes.get_mut(&key).unwrap();
            // Preserve active provider registration if the resumed agent beat us.
            if live["provider"] == "shell" {
                live["manifest"] = node["manifest"].clone();
            }
        }
        for (_, mut edge) in staged.edges {
            self.revision += 1;
            edge["revision"] = json!(self.revision);
            self.edges.insert(edge_key(&edge), edge);
        }
        if let Some(limit) = limit {
            self.default_run_limit = limit;
        }
        self.revoke();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn restores_ports_and_connection_options_with_new_ids_without_replaying_work() {
        let mut source = Graph::default();
        for id in [1, 2] {
            source.add(id, format!("Pane {id}"));
            source
                .dispatch(
                    id,
                    "agent.event",
                    &json!({"provider":"claude","event":"SessionStart"}),
                )
                .unwrap();
        }
        source
            .dispatch(
                1,
                "graph.connect",
                &json!({"from":"%1","to":"%2","send":true,"muted":true,
            "contains":"important","outcome":"success","stop_at":4102444800u64}),
            )
            .unwrap();
        source.nodes.get_mut("%1").unwrap()["provider"] = json!("shell");
        source.nodes.get_mut("%2").unwrap()["provider"] = json!("shell");
        let saved = source.checkpoint();
        let mut target = Graph::default();
        target.add(10, "New shell".into());
        target.add(20, "New shell".into());
        let ids = HashMap::from([("%1".into(), "%10".into()), ("%2".into(), "%20".into())]);
        target.restore_checkpoint(&saved, &ids).unwrap();
        let edge = &target.checkpoint()["edges"][0];
        assert_eq!(edge["from"], "%10");
        assert_eq!(edge["to"], "%20");
        assert_eq!(edge["muted"], true);
        assert_eq!(edge["contains"], "important");
        assert_eq!(edge["stop_at"].as_f64(), Some(4102444800.));
        assert_eq!(target.nodes["%10"]["provider"], "shell");
        assert!(target.queues.is_empty());
        let before = target.snapshot();
        let mut invalid = saved;
        invalid["edges"][0]["to"] = json!("%999");
        assert!(target.restore_checkpoint(&invalid, &ids).is_err());
        assert_eq!(target.snapshot(), before);
    }
}
