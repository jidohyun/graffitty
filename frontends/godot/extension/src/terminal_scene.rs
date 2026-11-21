//! Native handles keep terminal/image payloads out of GDScript serialization.
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_client_core::{
    scene::{Commit, Pixels},
    scene_worker::{Job, Prepared, Worker},
};

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct TerminalSceneUpdate {
    base: Base<RefCounted>,
    pub commit: Option<Commit>,
    pub pixels: Option<Pixels>,
}
#[godot_api]
impl IRefCounted for TerminalSceneUpdate {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            commit: None,
            pixels: None,
        }
    }
}
impl TerminalSceneUpdate {
    pub fn packet(session: u64, commit: Option<Commit>, pixels: Option<Pixels>) -> VarDictionary {
        let mut packet = VarDictionary::new();
        packet.set("session", session as i64);
        if let Some(commit) = &commit {
            packet.set("columns", i64::from(commit.update.columns));
            packet.set("rows", i64::from(commit.update.rows));
            packet.set("exited", commit.update.exited);
            packet.set("revision", commit.revision as i64);
        }
        let value = Gd::from_init_fn(|base| Self {
            base,
            commit,
            pixels,
        });
        packet.set("native", &value);
        packet
    }
}

/// WebSocket adapters submit binary packets here once. The same background
/// assembler is used by native IPC and by the other frontends.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct TerminalSceneDecoder {
    base: Base<RefCounted>,
    worker: Worker,
}
#[godot_api]
impl IRefCounted for TerminalSceneDecoder {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            worker: Default::default(),
        }
    }
}
#[godot_api]
impl TerminalSceneDecoder {
    #[func]
    fn idle(&self) -> bool { self.worker.idle() }
    #[func]
    fn ready_for_packet(&mut self) -> bool {
        self.worker.flush()
    }
    #[func]
    fn submit(&mut self, header: GString, data: PackedByteArray) -> bool {
        let result = (|| -> anyhow::Result<Job> {
            let value: serde_json::Value = serde_json::from_str(&header.to_string())?;
            let id = graffitty_protocol::SessionId(
                value["session"]
                    .as_u64()
                    .ok_or_else(|| anyhow::anyhow!("Missing terminal session"))?,
            );
            Ok(if value["type"] == "terminal_asset" {
                Job::Asset(
                    id,
                    serde_json::from_value(value["asset"].clone())?,
                    data.to_vec(),
                )
            } else {
                Job::Terminal(
                    id,
                    serde_json::from_value(value.clone())?,
                    serde_json::from_value(value["scene"].clone())?,
                    data.to_vec(),
                )
            })
        })();
        match result {
            Ok(job) => {
                self.worker.submit(job);
                true
            }
            Err(error) => {
                godot_error!("Terminal scene: {error}");
                false
            }
        }
    }
    #[func]
    fn poll(&mut self) -> Array<VarDictionary> {
        let mut out = Array::new();
        // Bound framework handle creation per UI tick. The native mailbox
        // retains only the newest unconsumed snapshots while we are drawing.
        let started = std::time::Instant::now();
        for _ in 0..8 {
            if started.elapsed() >= std::time::Duration::from_millis(2) { break; }
            let Ok(prepared) = self.worker.output.try_recv() else { break; };
            let item = match prepared {
                Prepared::Terminal(id, commit) => {
                    TerminalSceneUpdate::packet(id.0, Some(commit), None)
                }
                Prepared::Asset(id, pixels) => {
                    TerminalSceneUpdate::packet(id.0, None, Some(pixels))
                }
                Prepared::Error(id, error) => {
                    let mut item = VarDictionary::new();
                    item.set("session", id.0 as i64);
                    item.set("error", error.as_str());
                    item
                }
            };
            out.push(&item);
        }
        out
    }
}
