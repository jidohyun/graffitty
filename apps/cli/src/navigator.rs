//! Pane selection with tmux client context for editor boundary handoffs.
use serde_json::{Value, json};
use std::{collections::HashMap, process::Command, time::Duration};

#[derive(usage_rs::Args)]
pub struct SelectPane {
    /// Select the pane to the left.
    #[usage(short = 'L')]
    pub left: bool,
    /// Select the pane below.
    #[usage(short = 'D')]
    pub down: bool,
    /// Select the pane above.
    #[usage(short = 'U')]
    pub up: bool,
    /// Select the pane to the right.
    #[usage(short = 'R')]
    pub right: bool,
    /// Select a pane (%ID or :tab.pane); with a direction, use it as the starting pane.
    #[usage(short = 't', long)]
    pub target: Option<String>,
    /// Originating tmux client's terminal; supplied by the tmux key binding.
    #[usage(long)]
    pub client_tty: Option<String>,
}

impl SelectPane {
    pub fn params(&self) -> Result<Value, String> {
        let mut params = json!({});
        for (selected, direction) in [
            (self.left, "left"), (self.down, "down"),
            (self.up, "up"), (self.right, "right"),
        ] {
            if selected {
                if params.get("direction").is_some() {
                    return Err("Choose only one of -L, -D, -U or -R".into());
                }
                params["direction"] = json!(direction);
            }
        }
        if let Some(target) = &self.target {
            if target.is_empty() {
                return Err("Expected a pane target after -t".into());
            }
            params["target"] = json!(target);
        }
        if let Some(tty) = &self.client_tty {
            params["client_tty"] = json!(tty);
        }
        Ok(params)
    }
}

pub fn select_pane(options: SelectPane) -> Value {
    let mut params = match options.params() {
        Ok(params) => params,
        Err(message) => return super::error("invalid_params", message),
    };
    let mut env: HashMap<String, String> = std::env::vars().collect();
    let mut client_tty = options.client_tty;
    // Existing tmux servers can acquire their Graffitty context on attachment.
    // Read it only at the outer edge, never register or poll an editor adapter.
    if let (Some(tmux), Some(pane)) = (env.get("TMUX"), env.get("TMUX_PANE")) {
        let socket = tmux.split(',').next().unwrap_or("");
        let query = |args: &[&str]| {
            Command::new("tmux")
                .args(["-S", socket])
                .args(args)
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        };
        let environment = query(&["show-environment", "-t", pane]);
        if client_tty.is_none() {
            client_tty = query(&["display-message", "-p", "-t", pane, "#{client_tty}"])
                .map(|s| s.trim().to_owned())
                .filter(|s| !s.is_empty());
        }
        if let Some(environment) = environment {
            for line in environment.lines() {
                if let Some((key, value)) = line.split_once('=') {
                    if matches!(key, "GRAFFITTY_SOCKET" | "GRAFFITTY_TOKEN") {
                        env.insert(key.into(), value.into());
                    }
                } else if let Some(key) = line.strip_prefix('-') {
                    if matches!(key, "GRAFFITTY_SOCKET" | "GRAFFITTY_TOKEN") {
                        env.remove(key);
                    }
                }
            }
        }
    }
    let context = env
        .get("GRAFFITTY_SOCKET")
        .zip(env.get("GRAFFITTY_TOKEN"))
        .filter(|(socket, token)| !socket.is_empty() && !token.is_empty());
    let Some((socket, token)) = context else {
        // Standalone Neovim/tmux still navigate internally and stop at the edge.
        if params.get("direction").is_some() && options.target.is_none() {
            return json!({"result":{"outcome":"edge"}});
        }
        return super::error("missing_context", "Run gft pane select inside a Graffitty workspace");
    };
    if let Some(tty) = client_tty {
        params["client_tty"] = json!(tty);
    }
    // Navigation belongs to the terminal context, not any inherited agent ID.
    super::call_context(
        "navigator.focus",
        params,
        Duration::from_secs(2),
        Some((socket.clone(), token.clone())),
    )
}
