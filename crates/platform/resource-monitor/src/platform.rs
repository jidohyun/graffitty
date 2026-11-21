use super::Reading;
pub(super) struct Backend;
impl Backend {
    pub const NAME: &'static str = "unavailable";
    pub const MEMORY: &'static str = "Memory";
    pub fn new(_pid: u32) -> Result<Self, String> {
        Err(
            "Native accounting boundary must be established before PTY launch on this platform"
                .into(),
        )
    }
    pub fn sample(&mut self) -> Result<Reading, String> {
        Err("No accounting boundary".into())
    }
}
