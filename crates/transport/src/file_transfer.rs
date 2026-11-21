//! Acknowledged upload state shared by every frontend. Never retry a mutation:
//! a lost final receipt can mean the attachment was already pasted.
use anyhow::{Result, bail, ensure};
use base64::{Engine as _, engine::general_purpose::STANDARD};
use graffitty_protocol::file_transfer::{CHUNK_BYTES, Chunk, MAX_BYTES, Receipt};
use serde_json::{Value, json};

pub struct Upload {
    id: String,
    name: String,
    bytes: Vec<u8>,
    paste: bool,
    offset: usize,
    awaiting: Option<usize>,
    pane: Option<String>,
    complete: bool,
}
impl Upload {
    pub fn new(name: String, bytes: Vec<u8>, paste: bool) -> Result<Self> {
        ensure!(bytes.len() <= MAX_BYTES, "File exceeds the 32 MiB upload limit");
        ensure!(!name.is_empty() && name.len() <= 255 && !name.chars().any(char::is_control), "Invalid attachment name");
        Ok(Self { id: uuid::Uuid::new_v4().to_string(), name, bytes, paste,
            offset: 0, awaiting: None, pane: None, complete: false })
    }
    pub fn next(&mut self) -> Option<Value> {
        if self.complete || self.awaiting.is_some() { return None; }
        let end = self.bytes.len().min(self.offset + CHUNK_BYTES);
        let chunk = Chunk { id: self.id.clone(), name: self.name.clone(), size: self.bytes.len(),
            offset: self.offset, data: STANDARD.encode(&self.bytes[self.offset..end]), paste: self.paste };
        self.awaiting = Some(end);
        let mut params = json!({"upload":chunk});
        if let Some(pane) = &self.pane { params["target"] = json!(pane); }
        Some(params)
    }
    pub fn accept(&mut self, response: &Value) -> Result<Option<String>> {
        if let Some(error) = response.get("error") { bail!("{}", error["message"].as_str().unwrap_or("File upload failed")); }
        let receipt: Receipt = serde_json::from_value(response["result"].clone())?;
        ensure!(receipt.id == self.id && self.awaiting == Some(receipt.received)
            && receipt.pane.starts_with('%') && receipt.pane[1..].parse::<u64>().is_ok()
            && self.pane.as_ref().is_none_or(|p| p == &receipt.pane), "Invalid file upload acknowledgment");
        ensure!(receipt.path.is_some() == (receipt.received == self.bytes.len()), "Incomplete file upload acknowledgment");
        self.offset = receipt.received;
        self.awaiting = None;
        self.pane = Some(receipt.pane);
        self.complete = receipt.path.is_some();
        Ok(receipt.path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn chunks_fit_the_wire_and_pin_the_resolved_pane() {
        let bytes = vec![0xa5; CHUNK_BYTES + 1];
        let mut upload = Upload::new("image.png".into(), bytes.clone(), true).unwrap();
        let first = upload.next().unwrap();
        assert!(upload.next().is_none());
        let packet = graffitty_protocol::pack(&json!({"type":"rpc","method":"terminal.put","params":first}), &[]).unwrap();
        assert!(packet.len() < graffitty_protocol::MAX_COMMAND_PACKET);
        assert_eq!(STANDARD.decode(first["upload"]["data"].as_str().unwrap()).unwrap(), bytes[..CHUNK_BYTES]);
        let receipt = |received, path: Option<&str>| json!({"result":{"id":first["upload"]["id"],"pane":"%7","received":received,"path":path}});
        assert!(upload.accept(&receipt(CHUNK_BYTES-1, None)).is_err());
        assert!(upload.accept(&receipt(CHUNK_BYTES, None)).unwrap().is_none());
        let last = upload.next().unwrap();
        assert_eq!(last["target"], "%7");
        assert_eq!(last["upload"]["offset"], CHUNK_BYTES);
        assert_eq!(upload.accept(&receipt(bytes.len(), Some("/fixture/image.png"))).unwrap().as_deref(), Some("/fixture/image.png"));
        assert!(upload.next().is_none());
    }
}
