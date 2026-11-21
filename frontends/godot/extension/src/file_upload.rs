//! Thin Godot adapter for the shared acknowledged upload state machine.
use godot::{classes::{RefCounted, IRefCounted}, prelude::*};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct TerminalFileUpload {
    base: Base<RefCounted>,
    upload: Option<graffitty_client_core::file_transfer::Upload>,
}
#[godot_api]
impl IRefCounted for TerminalFileUpload {
    fn init(base: Base<RefCounted>) -> Self { Self { base, upload: None } }
}
#[godot_api]
impl TerminalFileUpload {
    #[func]
    fn start(&mut self, name: GString, bytes: PackedByteArray) -> GString {
        match graffitty_client_core::file_transfer::Upload::new(name.to_string(), bytes.to_vec(), true) {
            Ok(upload) => { self.upload = Some(upload); GString::new() },
            Err(error) => GString::from(&error.to_string()),
        }
    }
    #[func]
    fn next_chunk(&mut self) -> VarDictionary {
        self.upload.as_mut().and_then(|u| u.next()).map(|v| crate::graph_client::to_variant(&v).to()).unwrap_or_default()
    }
    #[func]
    fn accept(&mut self, response: VarDictionary) -> VarDictionary {
        let result = (|| -> anyhow::Result<Option<String>> {
            let response = crate::graph_client::from_variant(&response.to_variant()).map_err(anyhow::Error::msg)?;
            self.upload.as_mut().ok_or_else(|| anyhow::anyhow!("Upload was not started"))?.accept(&response)
        })();
        crate::graph_client::to_variant(&match result {
            Ok(path) => serde_json::json!({"done":path.is_some(),"path":path}),
            Err(error) => serde_json::json!({"error":error.to_string()}),
        }).to()
    }
}
