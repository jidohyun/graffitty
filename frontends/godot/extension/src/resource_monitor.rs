//! Godot boundary: cached snapshots only; OS calls run in the native worker.
use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;
use std::time::Duration;
use terminal_resource_monitor::Service;

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct ResourceMonitorService {
    base: Base<RefCounted>,
    service: Option<Service>,
    error: String,
}
#[godot_api]
impl IRefCounted for ResourceMonitorService {
    fn init(base: Base<RefCounted>) -> Self {
        let (service, error) = match Service::new() {
            Ok(s) => (Some(s), String::new()),
            Err(e) => (None, e.to_string()),
        };
        Self {
            base,
            service,
            error,
        }
    }
}
#[godot_api]
impl ResourceMonitorService {
    #[func]
    fn register_terminal(&self, id: i64, pid: i64, interval_seconds: f64, enabled: bool) {
        if id < 0 || pid <= 0 || pid > i32::MAX as i64 {
            return;
        }
        if let Some(s) = &self.service {
            s.register(id as u64, pid as u32, interval(interval_seconds), enabled);
        }
    }
    #[func]
    fn remove_terminal(&self, id: i64) {
        if let Some(s) = &self.service {
            s.remove(id as u64);
        }
    }
    #[func]
    fn pause_terminal(&self, id: i64) {
        if let Some(s) = &self.service {
            s.pause(id as u64);
        }
    }
    #[func]
    fn resume_terminal(&self, id: i64) {
        if let Some(s) = &self.service {
            s.resume(id as u64);
        }
    }
    #[func]
    fn reset_terminal(&self, id: i64) {
        if let Some(s) = &self.service {
            s.reset(id as u64);
        }
    }
    #[func]
    fn set_interval(&self, id: i64, seconds: f64) {
        if let Some(s) = &self.service {
            s.interval(id as u64, interval(seconds));
        }
    }
    #[func]
    fn snapshot(&self, id: i64) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(s) = self.service.as_ref().and_then(|s| s.snapshot(id as u64)) else {
            d.set(
                "status",
                if self.error.is_empty() {
                    "starting"
                } else {
                    "unavailable"
                },
            );
            d.set("error", self.error.as_str());
            return d;
        };
        d.set("revision", s.revision as i64);
        d.set("root_pid", s.root_pid as i64);
        d.set("status", s.status.as_str());
        d.set("backend", s.backend.as_str());
        d.set("memory_label", s.memory_label.as_str());
        d.set("error", s.error.as_str());
        d.set("cpu_percent", s.cpu_percent);
        d.set("cpu_valid", s.cpu_valid);
        d.set("cpu_time_user", s.cpu_user_seconds);
        d.set("cpu_time_system", s.cpu_system_seconds);
        d.set("cpu_time", s.cpu_user_seconds + s.cpu_system_seconds);
        d.set("memory_current", s.memory_current as i64);
        d.set("memory_peak_observed", s.memory_peak_observed as i64);
        d.set(
            "memory_peak_kernel",
            &s.memory_peak_kernel
                .map(|v| (v as i64).to_variant())
                .unwrap_or(Variant::nil()),
        );
        // Detailed peak bounds are phase 2, not a claimed exact kernel peak.
        d.set("memory_peak_upper_bound", &Variant::nil());
        d.set("epoch", s.epoch as i64);
        d.set("coverage_gap", s.coverage_gap);
        d.set("sample_ms", s.sample_ms);
        d.set(
            "sample_age_seconds",
            s.sampled_at
                .map(|t| t.elapsed().as_secs_f64())
                .unwrap_or(-1.0),
        );
        d.set(
            "monitoring_seconds",
            s.monitoring_since
                .map(|t| t.elapsed().as_secs_f64())
                .unwrap_or(0.0),
        );
        let mut processes: Array<VarDictionary> = Array::new();
        for p in s.processes {
            let mut row = VarDictionary::new();
            row.set("pid", p.pid as i64);
            row.set("parent_pid", p.parent as i64);
            row.set("start_identity", p.start as i64);
            row.set("name", p.name.as_str());
            row.set("memory_current", p.memory as i64);
            processes.push(&row);
        }
        d.set("processes", &processes);
        d.set("process_count", processes.len() as i64);
        d
    }
}
fn interval(value: f64) -> Duration {
    Duration::from_secs_f64(if value.is_finite() {
        value.clamp(0.1, 3600.0)
    } else {
        5.0
    })
}
