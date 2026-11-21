//! Wall-clock schedules shared with Filter's time window.
use crate::node_rpc as rpc;
use crate::{
    agent_bridge::Result,
    node_form::{Action, Form},
    options::TimeTrigger,
};
use jiff::{Timestamp, civil::DateTime, tz::TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    collections::VecDeque,
    io::IsTerminal,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration},
};

pub(crate) fn now_ms() -> i64 {
    Timestamp::now().as_millisecond()
}

/// Time-only values mean today, resolved once when configuration is applied.
pub(crate) fn parse_time(value: &str, now: i64) -> Result<i64> {
    if let Ok(stamp) = value.trim().parse::<Timestamp>() {
        return Ok(stamp.as_millisecond());
    }
    parse_in_zone(value, now, TimeZone::try_system()?)
}
fn parse_in_zone(value: &str, now: i64, zone: TimeZone) -> Result<i64> {
    let value = value.trim();
    if let Ok(stamp) = value.parse::<Timestamp>() {
        return Ok(stamp.as_millisecond());
    }
    let mut text = value.to_owned();
    if !text.contains(['T', 't', ' ']) && text.contains(':') {
        text = format!(
            "{}T{text}",
            Timestamp::from_millisecond(now)?
                .to_zoned(zone.clone())
                .date()
        );
    }
    let civil = text.parse::<DateTime>().map_err(|_| format!("Invalid time '{value}'; use HH:MM[:SS], YYYY-MM-DD HH:MM[:SS], or a timestamp with timezone offset"))?;
    // Do not silently move a nonexistent/ambiguous daylight-saving time.
    Ok(zone
        .to_ambiguous_timestamp(civil)
        .unambiguous()?
        .as_millisecond())
}
/// A one-time clock value targets its next occurrence in the local calendar.
fn parse_at_in_zone(value: &str, now: i64, zone: TimeZone) -> Result<i64> {
    let at = parse_in_zone(value, now, zone.clone())?;
    if at < now {
        let clock_only = value
            .trim()
            .bytes()
            .all(|b| b.is_ascii_digit() || b == b':' || b == b'.');
        if let Some(time) = clock_only
            .then(|| value.trim().parse::<jiff::civil::Time>().ok())
            .flatten()
        {
            let tomorrow = Timestamp::from_millisecond(now)?
                .to_zoned(zone.clone())
                .date()
                .checked_add(jiff::Span::new().days(1))?;
            return Ok(zone
                .to_ambiguous_timestamp(tomorrow.to_datetime(time))
                .unambiguous()?
                .as_millisecond());
        }
        return Err("At is in the past; choose a future date or a time without a date".into());
    }
    Ok(at)
}
fn interval(value: &str) -> Result<i64> {
    let text = value.trim();
    for (unit, multiplier) in [
        ("ms", 1.0),
        ("s", 1000.0),
        ("m", 60_000.0),
        ("h", 3_600_000.0),
        ("d", 86_400_000.0),
    ] {
        if let Some(number) = text.strip_suffix(unit) {
            let ms = number.trim().parse::<f64>()? * multiplier;
            if ms.is_finite() && (100.0..=31_536_000_000.0).contains(&ms) {
                return Ok(ms.round() as i64);
            }
            break;
        }
    }
    Err("Duration must be from 100ms to 365d, e.g. 30s, 5m, or 1h".into())
}
fn display(ms: i64) -> String {
    Timestamp::from_millisecond(ms)
        .map(|t| t.to_zoned(TimeZone::system()).to_string())
        .unwrap_or_else(|_| ms.to_string())
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Settings {
    name: String,
    mode: String,
    at: String,
    every: String,
    from: String,
    until: String,
    text: String,
    #[serde(default)]
    when: String,
    #[serde(default)]
    delay: String,
    #[serde(default)]
    start: String,
    #[serde(default)]
    start_delay: String,
    #[serde(default)]
    end: String,
    #[serde(default)]
    duration: String,
}
impl Default for Settings {
    fn default() -> Self {
        Self {
            name: "Scheduled Trigger".into(),
            mode: "at".into(),
            at: String::new(),
            every: "1m".into(),
            from: String::new(),
            until: String::new(),
            text: "Time trigger".into(),
            when: "at".into(),
            delay: "30m".into(),
            start: String::new(),
            start_delay: "30m".into(),
            end: String::new(),
            duration: "30m".into(),
        }
    }
}
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
struct Schedule {
    start: i64,
    next: Option<i64>,
    every: Option<i64>,
    until: Option<i64>,
}
/// Resume a checkpointed trigger from its applied settings, armed
/// absolute times, and delivery history.
///
/// Reusing the original arguments could schedule an already delivered
/// time again, especially a relative value such as "in 30m".
fn trigger_state(settings: &Settings, schedule: Option<&Schedule>, count: u64, log: &VecDeque<String>) -> Value {
    let log: Vec<_> = log.iter().skip(log.len().saturating_sub(50)).collect();
    json!({"settings":settings,"schedule":schedule,"count":count,"log":log})
}
fn restored_trigger(state: &Value) -> Option<(Settings, Option<Schedule>, u64, VecDeque<String>)> {
    Some((
        serde_json::from_value(state["settings"].clone()).ok()?,
        serde_json::from_value(state["schedule"].clone()).ok()?,
        state["count"].as_u64()?,
        state["log"].as_array()?.iter().filter_map(|line| line.as_str().map(str::to_owned)).collect(),
    ))
}
impl Settings {
    fn start_kind(&self) -> &str {
        if self.start.is_empty() {
            if self.from.trim().is_empty() {
                "now"
            } else {
                "at"
            }
        } else {
            &self.start
        }
    }
    fn end_kind(&self) -> &str {
        if self.end.is_empty() {
            if self.until.trim().is_empty() {
                "never"
            } else {
                "at"
            }
        } else {
            &self.end
        }
    }
    fn rows(&self) -> Vec<(Vec<usize>, u16)> {
        let mut rows = vec![(vec![0, 1], 3)];
        if self.mode == "repeat" {
            rows.push((vec![3], 3));
            rows.push((
                match self.start_kind() {
                    "in" => vec![9, 10],
                    "at" => vec![9, 4],
                    _ => vec![9],
                },
                3,
            ));
            rows.push((
                match self.end_kind() {
                    "after" => vec![11, 12],
                    "at" => vec![11, 5],
                    _ => vec![11],
                },
                3,
            ));
        } else {
            rows.push((vec![7, if self.when == "in" { 8 } else { 2 }], 3));
        }
        rows.push((vec![6], 5));
        rows
    }
    fn from_values(v: &[String]) -> Self {
        Self {
            name: v[0].clone(),
            mode: if v[1] == "once" {
                "at".into()
            } else {
                v[1].clone()
            },
            at: v[2].clone(),
            every: v[3].clone(),
            from: v[4].clone(),
            until: v[5].clone(),
            text: v[6].clone(),
            when: v[7].clone(),
            delay: v[8].clone(),
            start: v[9].clone(),
            start_delay: v[10].clone(),
            end: v[11].clone(),
            duration: v[12].clone(),
        }
    }
    fn preview(&self, now: i64) -> String {
        let schedule = match self.schedule(now) {
            Ok(s) => s,
            Err(e) => return format!("Enter a schedule: {e}"),
        };
        if self.mode != "repeat" {
            return if self.when == "in" {
                format!("Fires once in {} after arming.", self.delay)
            } else {
                format!("Fires once at {}.", display(schedule.next.unwrap()))
            };
        }
        let start = match self.start_kind() {
            "in" => format!("Starts in {} after arming", self.start_delay),
            "at" => format!("Start at {}", self.from),
            _ => "Starts when armed".into(),
        };
        let end = match self.end_kind() {
            "after" => format!("for {} from the scheduled start", self.duration),
            "at" => format!("stopping before {}", self.until),
            _ => "with no end".into(),
        };
        let count = match (schedule.next, schedule.until) {
            (Some(next), Some(end)) => format!(
                "{} triggers scheduled. ",
                (end - next - 1) / schedule.every.unwrap() + 1
            ),
            (None, _) => "No triggers in this window. ".into(),
            _ => String::new(),
        };
        let first = if schedule.start < now {
            "Continues the original cadence; past triggers are skipped."
        } else {
            "First trigger at the start; end excluded."
        };
        format!(
            "{start}, every {}, {end}.\n{count}{first} Re-arming resets relative times.",
            self.every
        )
    }
    fn schedule(&self, now: i64) -> Result<Schedule> {
        if self.mode == "at" || self.mode == "once" {
            let at = match self.when.as_str() {
                "" | "at" => parse_at_in_zone(&self.at, now, TimeZone::try_system()?)?,
                "in" => now
                    .checked_add(interval(&self.delay)?)
                    .ok_or("Schedule exceeds supported dates")?,
                _ => return Err("When must be at or in".into()),
            };
            return Ok(Schedule {
                start: at,
                next: Some(at),
                every: None,
                until: None,
            });
        }
        if self.mode != "repeat" {
            return Err("Mode must be at or repeat".into());
        }
        let every = interval(&self.every)?;
        let from = match self.start_kind() {
            "now" => now,
            "in" => now
                .checked_add(interval(&self.start_delay)?)
                .ok_or("Schedule exceeds supported dates")?,
            "at" => parse_time(&self.from, now)?,
            _ => return Err("Start must be now, in, or at".into()),
        };
        let until = match self.end_kind() {
            "never" => None,
            "after" => Some(
                from.checked_add(interval(&self.duration)?)
                    .ok_or("Schedule exceeds supported dates")?,
            ),
            "at" => Some(parse_time(&self.until, now)?),
            _ => return Err("End must be never, after, or at".into()),
        };
        if until.is_some_and(|end| end <= from || end <= now) {
            return Err("End must be later than Start and the current time".into());
        }
        let next = if from >= now {
            from
        } else {
            from.checked_add(((now - from - 1) / every + 1) * every)
                .ok_or("Schedule exceeds supported dates")?
        };
        Ok(Schedule {
            start: from,
            next: until.map_or(Some(next), |end| (next < end).then_some(next)),
            every: Some(every),
            until,
        })
    }
}
impl Schedule {
    fn due(&mut self, now: i64) -> Option<i64> {
        if self.until.is_some_and(|end| now >= end) {
            self.next = None;
            return None;
        }
        let next = self.next?;
        if now < next {
            return None;
        }
        // Coalesce missed ticks after sleep; preserve the original cadence.
        let due = self
            .every
            .map_or(next, |step| next + (now - next) / step * step);
        self.next = self
            .every
            .and_then(|step| due.checked_add(step))
            .filter(|next| self.until.is_none_or(|end| *next < end));
        Some(due)
    }
}
static STOP: AtomicBool = AtomicBool::new(false);
extern "C" fn stop(_: libc::c_int) {
    STOP.store(true, Ordering::Relaxed);
}

fn register(graph_session: &crate::NodeSession, settings: &Settings) -> Result<()> {
    graph_session.register_raw(json!({"name":settings.name,"icon":"◷","inputs":[],"outputs":[{"id":"out","name":"Trigger","color":"#ffd47a"}]}),
    )
}
pub fn run(args: TimeTrigger) -> Result<()> {
    if args.edit && args.headless {
        return Err("Choose either --edit or --headless".into());
    }
    if args.at.is_some() && (args.every.is_some() || args.from.is_some() || args.until.is_some()) {
        return Err("Use --at once, or --every with optional --from and --until".into());
    }
    let mut value = crate::node_config::load(
        serde_json::to_value(Settings::default())?,
        args.config.as_deref(),
    )?;
    if args.at.is_some() {
        value["mode"] = json!("at");
        value["when"] = json!("at");
    }
    if args.every.is_some() || args.from.is_some() || args.until.is_some() {
        value["mode"] = json!("repeat");
    }
    if args.from.is_some() {
        value["start"] = json!("at");
    }
    if args.until.is_some() {
        value["end"] = json!("at");
    }
    for (key, item) in [
        ("name", args.name),
        ("at", args.at),
        ("every", args.every),
        ("from", args.from),
        ("until", args.until),
        ("text", args.text),
    ] {
        if let Some(item) = item {
            value[key] = json!(item);
        }
    }
    let mut settings: Settings = serde_json::from_value(value)?;
    let interactive =
        !args.headless && std::io::stdin().is_terminal() && std::io::stdout().is_terminal();
    if args.edit && !interactive {
        return Err("--edit requires an interactive terminal".into());
    }
    let (restored, restore_error) = match graffitty_graph_protocol::restored_state() {
        Ok(state) => (state.as_ref().and_then(restored_trigger), None),
        Err(error) => (None, Some(format!("Could not restore the previous schedule: {error}."))),
    };
    if let Some((saved, ..)) = &restored {
        settings = saved.clone();
    }
    // A restored trigger stays armed or paused exactly as it was.
    let mut schedule = match &restored {
        Some((_, saved, ..)) => saved.clone(),
        None if interactive => None,
        None => Some(settings.schedule(now_ms())?),
    };
    let mut form = if interactive {
        Some(Form::settings(
            "Scheduled Trigger",
            vec![
                ("Name", settings.name.clone()),
                (
                    "Mode",
                    if settings.mode == "at" {
                        "once".into()
                    } else {
                        settings.mode.clone()
                    },
                ),
                ("Date/time · YYYY-MM-DD HH:MM", settings.at.clone()),
                ("Every · e.g. 30s, 5m, 1h", settings.every.clone()),
                ("Start date/time", settings.from.clone()),
                ("End date/time · exclusive", settings.until.clone()),
                ("Text", settings.text.clone()),
                (
                    "When",
                    if settings.when.is_empty() {
                        "at".into()
                    } else {
                        settings.when.clone()
                    },
                ),
                ("Delay · e.g. 30m", settings.delay.clone()),
                ("Start", settings.start_kind().into()),
                ("Start delay · e.g. 30m", settings.start_delay.clone()),
                ("End", settings.end_kind().into()),
                ("Duration from start · e.g. 30m", settings.duration.clone()),
            ],
            vec![
                (1, vec!["once", "repeat"]),
                (7, vec!["in", "at"]),
                (9, vec!["now", "in", "at"]),
                (11, vec!["never", "after", "at"]),
            ],
            settings.rows(),
        )?)
    } else {
        None
    };
    STOP.store(false, Ordering::Relaxed);
    unsafe {
        libc::signal(libc::SIGINT, stop as *const () as libc::sighandler_t);
        libc::signal(libc::SIGTERM, stop as *const () as libc::sighandler_t);
    }
    let mut graph_session = crate::node_session(false)?;
    register(&graph_session, &settings)?;
    let was_restored = restored.is_some();
    let (mut history, mut count) = restored.map_or_else(Default::default, |(_, _, count, log)| (log, count));
    let mut status = if was_restored {
        "Restored from a checkpoint · Start or Ctrl+Enter arms a new schedule.".to_owned()
    } else {
        "Paused. Connect Trigger, enter a schedule, then Ctrl+Enter. Times without offsets use local time; At clock times mean today or tomorrow.".to_owned()
    };
    if let Some(error) = restore_error {
        if form.is_none() {
            eprintln!("{error}");
        }
        status = format!("{error} {status}");
    }
    let mut reported = Value::Null;
    while !STOP.load(Ordering::Relaxed) {
        let current = trigger_state(&settings, schedule.as_ref(), count, &history);
        if current != reported {
            graph_session.report_state(current.clone())?;
            reported = current;
        }
        graph_session.heartbeat()?;
        if let Some(form) = &mut form {
            let draft = Settings::from_values(&form.values());
            form.set_settings_rows(draft.rows());
            let summary = schedule.as_ref().map_or_else(
                || draft.preview(now_ms()),
                |s| {
                    format!(
                        "Start: {}\nEnd: {}\n{}",
                        display(s.start),
                        s.until
                            .map(|end| format!("{} (exclusive)", display(end)))
                            .unwrap_or_else(|| "none".into()),
                        s.every
                            .map(|_| format!(
                                "Every {}. Re-arming resets relative times.",
                                settings.every
                            ))
                            .unwrap_or_else(|| "One trigger.".into())
                    )
                },
            );
            form.set_settings_summary(&summary);
            form.set_log(&history.iter().cloned().collect::<Vec<String>>().join("\n"));
            form.set_running(schedule.as_ref().is_some_and(|s| s.next.is_some()));
            match form.tick(&status, "")? {
                Action::Quit => break,
                Action::Pause => {
                    schedule = None;
                    status = "Paused · Start begins a new schedule; relative times restart.".into();
                }
                Action::Edit => {
                    schedule = None;
                    status = "Paused · Ctrl+Enter to validate and arm.".into();
                }
                Action::Apply => {
                    let v = form.values();
                    settings = Settings::from_values(&v);
                    match settings.schedule(now_ms()).and_then(|s| {
                        register(&graph_session, &settings)?;
                        Ok(s)
                    }) {
                        Ok(s) => {
                            status = s.next.map_or(
                                "Complete: no ticks within the time window.".into(),
                                |at| format!("Armed · next {}", display(at)),
                            );
                            schedule = Some(s);
                        }
                        Err(error) => {
                            schedule = None;
                            status = format!("Paused · {error}");
                        }
                    }
                }
                Action::Save => {
                    let v = form.values();
                    let saved = Settings::from_values(&v);
                    status = if let Some(path) = args.config.as_deref() {
                        match serde_json::to_string_pretty(&saved)
                            .map_err(|e| e.to_string())
                            .and_then(|text| {
                                std::fs::write(path, text + "\n").map_err(|e| e.to_string())
                            }) {
                            Ok(()) => format!("Saved {path}. Ctrl+Enter to arm/apply."),
                            Err(e) => format!("Save failed: {e}"),
                        }
                    } else {
                        "Use --config <path> to choose where to save settings.".into()
                    };
                }
                _ => {}
            }
        } else {
            std::thread::sleep(Duration::from_millis(50));
        }
        let now = now_ms();
        let Some(active) = &mut schedule else {
            // Without a form, nothing can arm a schedule again.
            if form.is_none() {
                break;
            }
            continue;
        };
        if let Some(due) = active.due(now) {
            let result = rpc(
                "graph.emit",
                json!({"output":"out","text":settings.text,"kind":"time.trigger","payload":{"text":settings.text,"scheduled_at":Timestamp::from_millisecond(due)?.to_string(),"fired_at":Timestamp::from_millisecond(now)?.to_string(),"sequence":count+1}}),
            );
            if let Err(error) = result {
                if form.is_none() {
                    return Err(error);
                }
                schedule = None;
                status = format!(
                    "Paused · {error}. Check wiring, then re-arm. This tick was not retried."
                );
                continue;
            }
            count += 1;
            let line = format!("{} · sent #{count}", display(now));
            if form.is_none() {
                println!("{line}");
            }
            history.push_back(line);
            if history.len() > 200 {
                history.pop_front();
            }
        }
        status = active
            .next
            .map_or(format!("Complete · {count} triggers sent."), |next| {
                format!(
                    "Armed · next {}{} · {count} sent",
                    display(next),
                    active
                        .until
                        .map(|end| format!(" · ends {} (exclusive)", display(end)))
                        .unwrap_or_default()
                )
            });
        if active.next.is_none() && form.is_none() {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn a_relaunch_continues_the_saved_schedule_instead_of_firing_again() {
        let start = 1_800_000_000_000;
        let mut once = Settings::default();
        once.when = "in".into();
        let mut armed = once.schedule(start).unwrap();
        assert_eq!(armed.due(start + 1_800_000), Some(start + 1_800_000));
        let log = VecDeque::from(["sent #1".to_owned()]);
        let state = trigger_state(&once, Some(&armed), 1, &log);
        // Relaunching from the same arguments would fire another 30 minutes on.
        assert_eq!(once.schedule(start + 3_600_000).unwrap().next, Some(start + 5_400_000));
        let (settings, saved, count, restored_log) = restored_trigger(&state).unwrap();
        assert_eq!((serde_json::to_value(settings).unwrap(), count, restored_log), (serde_json::to_value(&once).unwrap(), 1, log));
        assert_eq!(saved.unwrap().due(start + 3_600_000), None, "a fired one-shot stays complete");
        // A repeating schedule keeps its cadence; a paused trigger stays paused.
        let mut repeat = Settings::default();
        repeat.mode = "repeat".into();
        repeat.every = "5m".into();
        let mut cadence = repeat.schedule(start).unwrap();
        assert_eq!(cadence.due(start), Some(start));
        let (_, saved, ..) = restored_trigger(&trigger_state(&repeat, Some(&cadence), 1, &VecDeque::new())).unwrap();
        assert_eq!(saved.unwrap().next, Some(start + 300_000));
        let (_, paused, ..) = restored_trigger(&trigger_state(&repeat, None, 0, &VecDeque::new())).unwrap();
        assert!(paused.is_none());
        let long: VecDeque<_> = (0..200).map(|n| n.to_string()).collect();
        assert_eq!(trigger_state(&repeat, None, 200, &long)["log"].as_array().unwrap().len(), 50);
    }
    #[test]
    fn relative_schedules_resolve_on_arm_and_exclude_the_end() {
        let now = 1_800_000_000_000;
        let mut settings = Settings {
            when: "in".into(),
            delay: "30m".into(),
            ..Settings::default()
        };
        assert_eq!(settings.schedule(now).unwrap().next, Some(now + 1_800_000));
        assert_eq!(
            settings.schedule(now + 1000).unwrap().next,
            Some(now + 1_801_000)
        );
        settings.mode = "repeat".into();
        settings.start = "in".into();
        settings.start_delay = "30m".into();
        settings.end = "after".into();
        settings.duration = "30m".into();
        let mut s = settings.schedule(now).unwrap();
        assert_eq!(s.start, now + 1_800_000);
        assert_eq!(s.until, Some(now + 3_600_000));
        assert!(settings.preview(now).contains("30 triggers"));
        assert_eq!(s.due(s.start - 1), None);
        for tick in 0..30 {
            let at = s.start + tick * 60_000;
            assert_eq!(s.due(at), Some(at));
        }
        assert_eq!(s.next, None);
        assert_eq!(s.due(now + 3_600_000), None);
        settings.duration = "90s".into();
        assert!(settings.preview(now).contains("2 triggers"));
        settings.start = "now".into();
        assert_eq!(settings.schedule(now).unwrap().start, now);
        settings.end = "never".into();
        settings.duration = "invalid but hidden".into();
        assert_eq!(settings.schedule(now).unwrap().until, None);
        settings.start = "in".into();
        for bad in ["", "-1m", "0m", "NaNm", "999999999d"] {
            settings.start_delay = bad.into();
            assert!(settings.schedule(now).is_err());
        }
    }
    #[test]
    fn legacy_settings_and_explicit_windows_keep_their_meaning() {
        let now = "2026-10-02T00:00:00Z"
            .parse::<Timestamp>()
            .unwrap()
            .as_millisecond();
        let legacy = json!({"name":"Legacy", "mode":"repeat", "at":"", "every":"1m",
            "from":"2026-10-02T00:30:00Z", "until":"2026-10-02T01:00:00Z", "text":"tick"});
        // Exercise the same defaults merge used by config loading.
        let mut value = serde_json::to_value(Settings::default()).unwrap();
        crate::node_config::merge(&mut value, legacy).unwrap();
        let mut settings: Settings = serde_json::from_value(value).unwrap();
        let s = settings.schedule(now).unwrap();
        assert_eq!(s.start, now + 1_800_000);
        assert_eq!(s.until, Some(now + 3_600_000));
        settings.end = "after".into();
        settings.duration = "30m".into();
        assert_eq!(settings.schedule(now).unwrap().until, s.until);
        settings.from = "2026-10-01T00:00:00Z".into();
        assert!(settings.schedule(now).is_err());
        let restored: Settings =
            serde_json::from_str(&serde_json::to_string(&settings).unwrap()).unwrap();
        assert_eq!(restored.end, "after");
        assert_eq!(restored.duration, "30m");
    }
    #[test]
    fn at_clock_times_roll_to_tomorrow_but_explicit_dates_do_not() {
        let stamp = |s: &str| s.parse::<Timestamp>().unwrap().as_millisecond();
        let now = stamp("2026-10-02T09:00:00+09:00");
        let zone = TimeZone::get("Asia/Seoul").unwrap();
        for (input, expected) in [
            ("10:00", "2026-10-02T10:00:00+09:00"),
            ("09:00", "2026-10-02T09:00:00+09:00"),
            (" 08:30:15 ", "2026-10-03T08:30:15+09:00"),
            ("2026-10-03 08:30", "2026-10-03T08:30:00+09:00"),
        ] {
            assert_eq!(
                parse_at_in_zone(input, now, zone.clone()).unwrap(),
                stamp(expected)
            );
        }
        for input in ["2026-10-02 08:30", "2026-10-02T08:30:00+09:00", "25:00"] {
            assert!(parse_at_in_zone(input, now, zone.clone()).is_err());
        }
        // Repeat and Filter windows retain their original today-only meaning.
        assert_eq!(
            parse_in_zone("08:30", now, zone).unwrap(),
            stamp("2026-10-02T08:30:00+09:00")
        );
        // Tomorrow is a calendar day, not necessarily 24 hours later.
        assert_eq!(
            parse_at_in_zone(
                "12:00",
                stamp("2026-03-07T18:00:00-05:00"),
                TimeZone::get("America/New_York").unwrap()
            )
            .unwrap(),
            stamp("2026-03-08T12:00:00-04:00")
        );
        assert_eq!(
            parse_at_in_zone("08:00", stamp("2026-12-31T18:00:00Z"), TimeZone::UTC).unwrap(),
            stamp("2027-01-01T08:00:00Z")
        );
    }
    #[test]
    fn schedule_boundaries_sleep_and_clock_reversal() {
        let mut s = Schedule {
            start: 1000,
            next: Some(1000),
            every: Some(1000),
            until: Some(5000),
        };
        assert_eq!(s.due(999), None);
        assert_eq!(s.due(1000), Some(1000));
        assert_eq!(s.due(1000), None);
        assert_eq!(s.due(900), None);
        assert_eq!(s.due(4500), Some(4000));
        assert_eq!(s.next, None);
        let mut s = Schedule {
            start: 1000,
            next: Some(1000),
            every: Some(1000),
            until: Some(5000),
        };
        assert_eq!(s.due(5000), None);
        let mut s = Schedule {
            start: 1000,
            next: Some(1000),
            every: None,
            until: None,
        };
        assert_eq!(s.due(1200), Some(1000));
        assert_eq!(s.due(1300), None);
    }
    #[test]
    fn timestamps_and_duration_validation() {
        let now = "2026-10-02T00:00:00Z"
            .parse::<Timestamp>()
            .unwrap()
            .as_millisecond();
        let zone = TimeZone::get("Asia/Seoul").unwrap();
        assert_eq!(
            parse_in_zone("09:30", now, zone.clone()).unwrap(),
            now + 1_800_000
        );
        assert_eq!(
            parse_in_zone("2026-10-02 09:30", now, zone.clone()).unwrap(),
            now + 1_800_000
        );
        assert_eq!(
            parse_in_zone("2026-10-02T09:30:00+09:00", now, zone).unwrap(),
            now + 1_800_000
        );
        for bad in ["", "25:00", "2026-02-30 12:00"] {
            assert!(parse_in_zone(bad, now, TimeZone::UTC).is_err());
        }
        assert_eq!(interval("5m").unwrap(), 300_000);
        assert_eq!(interval("250ms").unwrap(), 250);
        for bad in ["0s", "-2s", "NaNs", "1", "10ms", "999999999d"] {
            assert!(interval(bad).is_err());
        }
    }
}
