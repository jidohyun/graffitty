//! Reuse the desktop's native provider discovery/delivery helper off the actor.
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    time::{Duration, Instant},
};
struct Job {
    child: Child,
    input: PathBuf,
    output: PathBuf,
    started: Instant,
    context: Value,
}
pub struct Workers {
    settings: crate::settings::Workers,
    directory: PathBuf,
    jobs: HashMap<String, Job>,
}
impl Workers {
    pub fn new(parent: &Path, settings: crate::settings::Workers) -> std::io::Result<Self> {
        let directory = parent.join(format!("workers-{}", uuid::Uuid::new_v4().simple()));
        fs::create_dir_all(&directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        }
        Ok(Self {
            settings,
            directory,
            jobs: HashMap::new(),
        })
    }
    pub fn busy(&self, key: &str) -> bool {
        self.jobs.contains_key(key)
    }
    pub fn start(&mut self, cli: &str, key: String, request: Value, context: Value) -> bool {
        if self.jobs.len() >= self.settings.concurrency || self.busy(&key) || !Path::new(cli).is_file() {
            return false;
        }
        let run = (|| -> std::io::Result<Job> {
            let input = self
                .directory
                .join(format!("{}.json", uuid::Uuid::new_v4().simple()));
            let output = input.with_extension("out");
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            options
                .open(&input)?
                .write_all(request.to_string().as_bytes())?;
            let child = Command::new(cli)
                .args(["internal", "agent-worker", "--request"])
                .arg(&input)
                .stdin(Stdio::null())
                .stdout(options.open(&output)?)
                .stderr(Stdio::null())
                .spawn()?;
            Ok(Job {
                child,
                input,
                output,
                started: Instant::now(),
                context,
            })
        })();
        match run {
            Ok(job) => {
                self.jobs.insert(key, job);
                true
            }
            Err(_) => false,
        }
    }
    pub fn poll(&mut self) -> Vec<(String, Value, Value)> {
        let keys: Vec<_> = self.jobs.keys().cloned().collect();
        let mut replies = vec![];
        for key in keys {
            let job = self.jobs.get_mut(&key).unwrap();
            let finished = job.child.try_wait().ok().flatten().is_some();
            let timed_out = job.started.elapsed() > Duration::from_secs(self.settings.timeout_seconds);
            if !finished && !timed_out {
                continue;
            }
            if timed_out {
                let _ = job.child.kill();
                let _ = job.child.wait();
            }
            let job = self.jobs.remove(&key).unwrap();
            let value = (|| -> Option<Value> {
                let mut bytes = vec![];
                fs::File::open(&job.output)
                    .ok()?
                    .take(self.settings.output_bytes as u64 + 1)
                    .read_to_end(&mut bytes)
                    .ok()?;
                if bytes.len() > self.settings.output_bytes {
                    return None;
                }
                serde_json::from_slice(&bytes).ok()
            })();
            replies.push((
                key,
                job.context,
                value.unwrap_or(json!({"error":{"message":"Agent helper failed or timed out"}})),
            ));
            let _ = fs::remove_file(job.input);
            let _ = fs::remove_file(job.output);
        }
        replies
    }
}
impl Drop for Workers {
    fn drop(&mut self) {
        for job in self.jobs.values_mut() {
            let _ = job.child.kill();
            let _ = job.child.wait();
        }
        let _ = fs::remove_dir_all(&self.directory);
    }
}
