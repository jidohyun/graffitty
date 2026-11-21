use std::path::PathBuf;

/// Run a headless session owner. Clients detach without ending their shells.
#[derive(usage_rs::Args, Default)]
pub struct Options {
    /// Read server settings from this TOML file.
    #[usage(long)]
    pub config: Option<PathBuf>,
    /// Listen for remote connections at this address (for example 127.0.0.1:7183).
    #[usage(long)]
    pub listen: Option<String>,
    /// Write the connection descriptor and hold its server lock here (default: server.json in the
    /// state directory, where the app looks for a running server).
    #[usage(long)]
    pub connection: Option<PathBuf>,
    /// Default shell for new terminal sessions.
    #[usage(long)]
    pub shell: Option<String>,
    /// Store authentication settings here (default: auth.json beside the connection descriptor).
    #[usage(long)]
    pub auth_file: Option<PathBuf>,
    /// Set the remote password interactively, then exit.
    #[usage(long)]
    pub set_password: bool,
    /// Clear the stored remote password, then exit.
    #[usage(long)]
    pub clear_password: bool,
    /// Select the Telegram 2FA credential; off disables it. Then exit.
    #[usage(long)]
    pub telegram_credential: Option<String>,
    /// Set the non-secret Telegram 2FA destination chat ID, then exit.
    #[usage(long)]
    pub telegram_chat_id: Option<String>,
    /// Set temporary password length to 6, 8 or 10, then exit.
    #[usage(long)]
    pub temporary_password_length: Option<usize>,
    /// Print the connection descriptor if its server is running, then exit.
    #[usage(long)]
    pub status: bool,
    /// Print the server version and protocol, then exit.
    #[usage(long)]
    pub version: bool,
}
