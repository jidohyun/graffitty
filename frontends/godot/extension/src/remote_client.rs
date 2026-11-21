//! Godot transport/scene boundary for shared remote-client policy.
use godot::{
    classes::{IRefCounted, RefCounted},
    prelude::*,
};
use graffitty_client_core::remote_state::{
    CloseAction, Field, LocalId, Namespace, PollAction, SocketState, WireId,
};
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct RemoteClientCore {
    base: Base<RefCounted>,
    namespace: Namespace,
    controller: Option<graffitty_client_core::controller::Bridge>,
    // One current converted value per large, independently changing topology
    // section. Title animation must not rebuild thousands of Godot Variants.
    decoded_parts: std::collections::BTreeMap<String, (serde_json::Value, VarDictionary)>,
}
#[godot_api]
impl IRefCounted for RemoteClientCore {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            namespace: Namespace::default(),
            controller: None,
            decoded_parts: Default::default(),
        }
    }
}
impl RemoteClientCore {
    fn map_id(&mut self, id: i64, incoming: bool, allocate: &Callable) -> i64 {
        if id < 0 {
            return id;
        }
        if !incoming {
            return self.namespace.wire(LocalId(id)).0;
        }
        if let Some(id) = self.namespace.local(WireId(id)) {
            return id.0;
        }
        let local = allocate.call(&[]).to::<i64>();
        self.namespace.bind(WireId(id), LocalId(local));
        local
    }
    fn mapped(
        &mut self,
        value: Variant,
        incoming: bool,
        field: Field,
        allocate: &Callable,
    ) -> Variant {
        match crate::graph_client::from_variant(&value) {
            Ok(value) => crate::graph_client::to_variant(&graffitty_client_core::remote_state::map_value(
                &value, field, &mut |id| self.map_id(id,incoming,allocate))),
            Err(error) => {godot_error!("{error}"); Variant::nil()}
        }
    }

}
#[godot_api]
impl RemoteClientCore {
    #[func]
    fn controller_start(&mut self, state: GString, alias: GString, identity: GString) -> GString {
        self.controller = None;
        if alias.is_empty() { return GString::new(); }
        match graffitty_client_core::controller::Bridge::new(
            std::path::Path::new(&state.to_string()), &alias.to_string(), &identity.to_string(),
        ) {
            Ok(bridge) => { self.controller = Some(bridge); GString::new() },
            Err(error) => GString::from(&error.to_string()),
        }
    }
    #[func]
    fn controller_stop(&mut self) { self.controller = None; }
    #[func]
    fn controller_poll(&mut self) -> VarArray {
        let messages = self.controller.as_mut().map(|c| c.poll()).unwrap_or_default();
        let mut result = VarArray::new();
        for message in messages { result.push(&crate::graph_client::to_variant(&message)); }
        result
    }
    #[func]
    fn controller_complete(&mut self, message: VarDictionary) -> bool {
        let Ok(value) = crate::graph_client::from_variant(&message.to_variant()) else { return false };
        self.controller.as_mut().is_some_and(|c| c.complete(&value))
    }
    #[func]
    fn bind_id(&mut self, wire: i64, local: i64) {
        self.namespace.bind(WireId(wire), LocalId(local));
    }
    #[func]
    fn local_id(&self, wire: i64) -> i64 {
        self.namespace.local(WireId(wire)).map_or(-1, |id| id.0)
    }
    #[func]
    fn wire_id(&self, local: i64) -> i64 {
        self.namespace.wire(LocalId(local)).0
    }
    #[func]
    fn seed_ids(&mut self, ids: Dictionary<i64, i64>) {
        self.namespace = Namespace::default();
        for (wire, local) in ids.iter_shared() {
            self.namespace.bind(WireId(wire), LocalId(local));
        }
    }
    #[func]
    fn local_ids(&self) -> Dictionary<i64, i64> {
        let mut d = Dictionary::new();
        for (w, l) in self.namespace.pairs() {
            d.set(w.0, l.0);
        }
        d
    }
    #[func]
    fn map_graph(
        &mut self,
        value: Variant,
        incoming: bool,
        field: GString,
        allocate: Callable,
    ) -> Variant {
        self.mapped(
            value,
            incoming,
            Field::from_key(&field.to_string()),
            &allocate,
        )
    }
    #[func]
    fn poll_action(
        &self,
        enabled: bool,
        state: i64,
        buffered: bool,
        now: i64,
        deadline: i64,
        retry: i64,
    ) -> i64 {
        let state = match state {
            -1 => SocketState::Absent,
            0 => SocketState::Connecting,
            1 => SocketState::Open,
            2 => SocketState::Closing,
            _ => SocketState::Closed,
        };
        match graffitty_client_core::remote_state::poll_action(
            enabled,
            state,
            buffered,
            now.max(0) as u64,
            deadline.max(0) as u64,
            retry.max(0) as u64,
        ) {
            PollAction::Wait => 0,
            PollAction::Connect => 1,
            PollAction::Read => 2,
            PollAction::Closed => 3,
            PollAction::Timeout => 4,
        }
    }
    #[func]
    fn close_action(&self, code: i64, password_verified: bool) -> i64 {
        match graffitty_client_core::remote_state::close_action(code, password_verified) {
            CloseAction::Retry => 0,
            CloseAction::Authentication => 1,
            CloseAction::Protocol => 2,
        }
    }
    #[func]
    fn restore_session(&self, sessions: VarArray, preferred: GString) -> GString {
        let value = crate::graph_client::from_variant(&sessions.to_variant()).unwrap_or_default();
        GString::from(graffitty_client_core::remote_state::restore_session(&value, &preferred.to_string()).unwrap_or_default().as_str())
    }
    /// The session a window shows after its own session `closed` ends, or ""
    /// when every remaining session is `shown` by another window.
    #[func]
    fn fallback_session(&self, sessions: VarArray, closed: GString, last: GString, shown: PackedStringArray) -> GString {
        let value = crate::graph_client::from_variant(&sessions.to_variant()).unwrap_or_default();
        let shown: Vec<String> = shown.as_slice().iter().map(GString::to_string).collect();
        let target = graffitty_client_core::remote_state::fallback_session(&value, &closed.to_string(), &last.to_string(), &shown);
        GString::from(target.unwrap_or_default().as_str())
    }
    /// Resolve next, previous, last viewed, or a numbered position. Empty
    /// when there is nowhere to go.
    #[func]
    fn session_target(&self, sessions: VarArray, current: GString, last: GString, which: GString) -> GString {
        use graffitty_client_core::remote_state::{adjacent_session, last_session, numbered_session};
        let value = crate::graph_client::from_variant(&sessions.to_variant()).unwrap_or_default();
        let current = current.to_string();
        let target = match which.to_string().as_str() {
            "next" => adjacent_session(&value, &current, 1),
            "previous" => adjacent_session(&value, &current, -1),
            "last" => last_session(&value, &last.to_string(), &current),
            digit => digit.parse().ok().and_then(|number| numbered_session(&value, number)),
        };
        GString::from(target.unwrap_or_default().as_str())
    }
    #[func]
    fn decode_message(&mut self, bytes: PackedByteArray) -> VarDictionary {
        let mut result = VarDictionary::new();
        // Validate every wire message before consulting the conversion cache.
        match graffitty_client_core::graph_state::decode_message(bytes.as_slice()) {
            Ok(message) => {
                let topology = message["type"] == "topology";
                if topology {
                    self.decoded_parts.retain(|key, _| message.get(key).is_some_and(serde_json::Value::is_object));
                }
                let mut converted = VarDictionary::new();
                for (key, value) in message.as_object().expect("validated object") {
                    if topology && matches!(key.as_str(), "graph" | "workspace_state" | "terminal_font") && value.is_object() {
                        let cached = self.decoded_parts.entry(key.clone()).or_insert_with(||
                            (serde_json::Value::Null, VarDictionary::new()));
                        if cached.0 != *value {
                            *cached = (value.clone(), crate::graph_client::to_read_only_variant(value).to());
                        }
                        // Immutable owner data is safe to share. Consumers that
                        // edit a snapshot explicitly duplicate it at that boundary.
                        converted.set(key.as_str(), &cached.1);
                    } else {
                        converted.set(key.as_str(), &crate::graph_client::to_variant(value));
                    }
                }
                result.set("message", &converted);
            }
            Err(error) => { result.set("error", error); }
        }
        result
    }
    #[func]
    fn pack(&self, header: GString, payload: PackedByteArray) -> PackedByteArray {
        match serde_json::from_str(&header.to_string())
            .ok()
            .and_then(|h| graffitty_protocol::pack(&h, payload.as_slice()).ok())
        {
            Some(data) => PackedByteArray::from(data.as_slice()),
            None => {
                godot_error!("Invalid remote packet header");
                PackedByteArray::new()
            }
        }
    }
    #[func]
    fn unpack(&self, packet: PackedByteArray) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Ok((header, payload)) = graffitty_protocol::unpack(packet.as_slice(), 8388608) {
            // Forward original JSON bytes: no float conversion or normalization.
            let length = u32::from_le_bytes(packet.as_slice()[4..8].try_into().unwrap()) as usize;
            d.set("header", &crate::graph_client::to_variant(&header));
            let header =
                std::str::from_utf8(&packet.as_slice()[8..8 + length]).expect("validated JSON");
            d.set("header_json", header);
            d.set("payload", &PackedByteArray::from(payload));
        }
        d
    }
}
