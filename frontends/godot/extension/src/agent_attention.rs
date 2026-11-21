//! Godot values only. Unseen-outcome evidence and counting live in client-core.
use crate::graph_client::{from_variant, to_variant};
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_client_core::agent_attention::AgentAttention;
use std::collections::HashSet;

fn keys(values: &PackedStringArray) -> HashSet<String> {
    values.as_slice().iter().map(|key| key.to_string()).collect()
}

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct AgentAttentionCore {
    base: Base<RefCounted>,
    state: AgentAttention,
}

#[godot_api]
impl IRefCounted for AgentAttentionCore {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base, state: AgentAttention::default() }
    }
}

#[godot_api]
impl AgentAttentionCore {
    /// `nodes` maps pane keys to graph nodes; `visible` panes are in front of
    /// the user; `live` lists every pane that exists. Returns whether a marker
    /// changed. Invalid input changes nothing and is reported.
    #[func]
    fn observe(&mut self, nodes: VarDictionary, visible: PackedStringArray, live: PackedStringArray) -> bool {
        match from_variant(&nodes.to_variant()) {
            Ok(nodes) => self.state.observe(&nodes, &keys(&visible), &keys(&live)),
            Err(error) => {
                godot_error!("Agent attention ignored an invalid graph view: {error}");
                false
            }
        }
    }

    /// `{state: "waiting" | "completed" | "", count}` for one tab's panes.
    #[func]
    fn marker(&self, panes: PackedStringArray) -> VarDictionary {
        let panes: Vec<String> = panes.as_slice().iter().map(|key| key.to_string()).collect();
        to_variant(&self.state.marker(panes.iter().map(String::as_str))).to()
    }
}
