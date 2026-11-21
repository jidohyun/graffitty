use graffitty_transport::file_transfer::Upload;
use serde_json::json;
use std::{io::Read, path::PathBuf};
use usage_rs::Args;

#[derive(Args)]
pub struct Options {
    /// Pane target; server-alias/%ID selects an attached remote server.
    /// Omit for the calling terminal; explicit local targets use the local server capability.
    #[usage(short = 't', long)]
    target: Option<String>,
    /// Paste the uploaded path as an attachment, without pressing Enter.
    #[usage(long)]
    paste: bool,
    /// Print the destination and byte count as JSON.
    #[usage(long)]
    json: bool,
    file: PathBuf,
}

pub fn run(options: Options) -> Result<(), Box<dyn std::error::Error>> {
    let mut open = std::fs::OpenOptions::new();
    open.read(true);
    #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; open.custom_flags(libc::O_NONBLOCK); }
    let file = open.open(&options.file)?;
    if !file.metadata()?.is_file() { return Err("Expected a regular file".into()); }
    let mut bytes = Vec::new();
    file.take(graffitty_protocol::file_transfer::MAX_BYTES as u64 + 1).read_to_end(&mut bytes)?;
    let size = bytes.len();
    let name = options.file.file_name().and_then(|s| s.to_str()).ok_or("Invalid filename")?;
    let mut upload = Upload::new(name.into(), bytes, options.paste)?;
    let alias = options.target.as_deref().map(graffitty_protocol::controller::split_target)
        .transpose()?.flatten().map(|(alias, _)| alias.to_owned());
    let local = if options.target.is_some() && alias.is_none() {
        Some(crate::live_sessions::context()?)
    } else { None };
    while let Some(mut params) = upload.next() {
        if let Some(pane) = params["target"].as_str() {
            if let Some(alias) = &alias { params["target"] = json!(format!("{alias}/{pane}")); }
        } else if let Some(target) = &options.target { params["target"] = json!(target); }
        let response = if let Some((endpoint, token)) = &local {
            use graffitty_graph_protocol::Rpc;
            match graffitty_graph_protocol::Client::new(endpoint.clone(), token.clone()).call("terminal.put", params) {
                Ok(result) => json!({"result":result}),
                Err(error) => return Err(error),
            }
        } else { crate::call("terminal.put", params) };
        if let Some(path) = upload.accept(&response)? {
            if options.json { println!("{}", json!({"path":path,"bytes":size})); }
            else { println!("{path}"); }
        }
    }
    Ok(())
}
