//! Godot adapter; the state machine is shared with alternative frontends.
pub use crate::binding_core::{Binding, Decision, Table};
use crate::options::value;
use godot::prelude::*;
use std::time::Duration;
#[derive(Default)]
pub struct Keyboard(crate::binding_core::Keyboard);
impl Keyboard {
    pub fn configure(&mut self, d: &VarDictionary) {
        fn bindings(entries: Array<VarDictionary>) -> Vec<Binding> {
            entries
                .iter_shared()
                .map(|e| Binding {
                    keys: value(&e, "keys", PackedInt64Array::new()).to_vec(),
                    action: value(&e, "action", GString::new()).to_string(),
                })
                .filter(|b| !b.keys.is_empty())
                .collect()
        }
        let sequences = bindings(value(d, "key_sequences", Array::new()));
        let mut compiled_tables = std::collections::HashMap::new();
        let tables: VarDictionary = value(d, "key_tables", VarDictionary::new());
        for (name, table) in tables.iter_shared() {
            if let (Ok(name), Ok(table)) =
                (name.try_to::<GString>(), table.try_to::<VarDictionary>())
            {
                compiled_tables.insert(
                    name.to_string(),
                    Table {
                        bindings: bindings(value(&table, "bindings", Array::new())),
                        one_shot: value(&table, "one_shot", true),
                        timeout: Duration::from_millis(
                            value(&table, "timeout_ms", 1000i64).max(1) as u64
                        ),
                    },
                );
            }
        }
        let leader = d
            .get("leader")
            .and_then(|v| v.try_to::<i64>().ok())
            .filter(|v| *v != 0);
        let timeout = Duration::from_millis(value(d, "sequence_timeout_ms", 1000i64).max(1) as u64);
        self.0
            .configure(sequences, compiled_tables, leader, timeout);
    }
    pub fn reset(&mut self) {
        self.0.reset();
    }
    pub fn release(&mut self, key: i32) -> bool {
        self.0.release(key)
    }
    pub fn action(&mut self, action: &str) -> bool {
        self.0.action(action)
    }
    pub fn press(&mut self, code: i64, physical: i32, echo: bool) -> Decision {
        self.0.press(code, physical, echo)
    }
}
