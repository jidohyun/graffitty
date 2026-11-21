//! Optional real subprocesses for scripted tool steps. No shell is implicit.
use std::{
    io::{self, Read, Seek, SeekFrom},
    process::{Child, Command, Stdio},
};

pub(super) struct Execution {
    child: Option<Child>,
    log: Option<tempfile::NamedTempFile>,
    pub output: String,
    pub exit_code: Option<i32>,
}
impl Execution {
    pub fn start(argv: &[String]) -> Self {
        let mut execution = Self {
            child: None,
            log: None,
            output: String::new(),
            exit_code: None,
        };
        if let Err(error) = execution.spawn(argv) {
            execution.output = error.to_string();
            execution.exit_code = Some(127);
        }
        execution
    }
    fn spawn(&mut self, argv: &[String]) -> io::Result<()> {
        let program = argv
            .first()
            .ok_or_else(|| io::Error::other("Missing tool command"))?;
        let log = tempfile::NamedTempFile::new()?;
        let out = log.reopen()?;
        let mut command = Command::new(program);
        command
            .args(&argv[1..])
            .stdin(Stdio::null())
            .stderr(out.try_clone()?)
            .stdout(out);
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        self.child = Some(command.spawn()?);
        self.log = Some(log);
        Ok(())
    }
    pub fn poll(&mut self) {
        if self.exit_code.is_some() {
            return;
        }
        if let Some(child) = &mut self.child {
            match child.try_wait() {
                Ok(Some(status)) => self.exit_code = Some(status.code().unwrap_or(1)),
                Ok(None) => (),
                Err(error) => {
                    self.output = error.to_string();
                    self.exit_code = Some(1);
                    return;
                }
            }
        }
        if let Some(log) = &mut self.log {
            // Keep the live tail bounded without blocking on a pipe or changing
            // the writer's offset. Both stdout and stderr share that writer.
            let result = (|| -> io::Result<String> {
                let length = log.as_file().metadata()?.len();
                log.as_file_mut()
                    .seek(SeekFrom::Start(length.saturating_sub(1024 * 1024)))?;
                let mut bytes = Vec::new();
                log.as_file_mut()
                    .take(1024 * 1024)
                    .read_to_end(&mut bytes)?;
                Ok(super::scenario::clean(&String::from_utf8_lossy(&bytes)))
            })();
            match result {
                Ok(output) => self.output = output,
                Err(error) => {
                    self.output = error.to_string();
                    self.exit_code = Some(1);
                }
            }
        }
    }
}
impl Drop for Execution {
    fn drop(&mut self) {
        if let Some(child) = &mut self.child {
            if child.try_wait().ok().flatten().is_none() {
                #[cfg(unix)]
                unsafe {
                    libc::kill(-(child.id() as i32), libc::SIGKILL);
                }
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}
