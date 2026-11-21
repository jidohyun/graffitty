//! Connection stop-time editor shared by the native frontends.
use crate::localization::text;
use chrono::{DateTime, NaiveDate};
use serde::Serialize;
use serde_json::{Value, json};

const DURATION_ERROR: &str = "Duration must be from 100ms to 365d, e.g. 30s, 5m, or 1h.";
const TIME_ERROR: &str = "Use HH:MM or YYYY-MM-DD HH:MM, optionally with :SS.";
const DATE_ERROR: &str = "Enter a valid date and time (year 1970 or later).";

pub fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_secs_f64()
}

pub fn parse_duration(source: &str) -> Result<f64, &'static str> {
    let source=source.trim();
    for (suffix,scale) in [("ms",0.001),("s",1.),("m",60.),("h",3600.),("d",86400.)] {
        if let Some(number)=source.strip_suffix(suffix) {
            let seconds=number.trim().parse::<f64>().map_err(|_|DURATION_ERROR)?*scale;
            return if seconds.is_finite() && (0.1..=31_536_000.).contains(&seconds) {
                Ok((seconds*1000.).round()/1000.)
            } else {Err(DURATION_ERROR)};
        }
    }
    Err(DURATION_ERROR)
}

pub fn format_time(timestamp: f64, offset: i32) -> String {
    DateTime::from_timestamp(timestamp as i64 + offset as i64*60,0)
        .map(|time|time.format("%Y-%m-%d %H:%M:%S").to_string()).unwrap_or_default()
}

pub fn parse_time(source: &str, offset: i32, now: f64) -> Result<f64, &'static str> {
    let source=source.trim();
    let clock_only=matches!(source.len(),5|8);
    let full=if clock_only {format!("{} {source}",&format_time(now,offset)[..10])}else{source.into()};
    let bytes=full.as_bytes();
    if !matches!(bytes.len(),16|19) || bytes.iter().enumerate().any(|(i,b)|match i {
        4|7=>*b!=b'-',10=>!matches!(b,b' '|b'T'),13|16=>*b!=b':',_=>!b.is_ascii_digit(),
    }) {return Err(TIME_ERROR);}
    let year=full[..4].parse::<i32>().map_err(|_|DATE_ERROR)?;
    let number=|start:usize|full[start..start+2].parse::<u32>().unwrap();
    let date=NaiveDate::from_ymd_opt(year,number(5),number(8)).filter(|_|year>=1970).ok_or(DATE_ERROR)?;
    let date=date.and_hms_opt(number(11),number(14),if bytes.len()==19 {number(17)}else{0}).ok_or(DATE_ERROR)?;
    let mut timestamp=(date.and_utc().timestamp()-offset as i64*60) as f64;
    if clock_only && timestamp<=now {timestamp+=86400.;}
    if timestamp<=0. {return Err("Stop time must be after the Unix epoch.");}
    Ok(timestamp)
}

pub struct Editor {
    mode: String,
    duration: String,
    date_time: String,
    offset: i32,
    saved: Option<f64>,
    dirty: bool,
    error: String,
}

impl Default for Editor {
    fn default() -> Self {Self {
        mode:"never".into(),duration:"30m".into(),date_time:String::new(),
        offset:chrono::Local::now().offset().local_minus_utc()/60,
        saved:None,dirty:false,error:String::new(),
    }}
}

#[derive(Serialize)]
pub struct Snapshot {
    pub mode: String,
    pub duration: String,
    pub date_time: String,
    pub zone: String,
    pub offset_minutes: i32,
    pub available: bool,
    pub can_apply: bool,
    pub status: String,
}

impl Editor {
    pub fn refresh(&mut self, edge: Option<&Value>) {
        let Some(edge)=edge else{return;};
        let deadline=edge["stop_at"].as_f64().unwrap_or(0.);
        if self.saved!=Some(deadline) {
            self.saved=Some(deadline);self.dirty=false;self.error.clear();
            self.mode=if deadline>0. {"at"}else{"never"}.into();
            self.date_time=if deadline>0. {format_time(deadline,self.offset)}else{String::new()};
        }
    }

    pub fn command(&mut self, edge: Option<&Value>, command: &str, value: &str, now: f64) -> Option<Value> {
        self.refresh(edge);
        let Some(edge)=edge else{return None;};
        self.error.clear();
        match command {
            "stop-mode" if matches!(value,"never"|"after"|"at") => {
                self.mode=value.into();self.dirty=true;
                if value=="at" && self.date_time.is_empty() {self.date_time=format_time(now+3600.,self.offset);}
            }
            "stop-duration" => {self.duration=value.into();self.dirty=true;}
            "stop-time" => {self.date_time=value.into();self.dirty=true;}
            "stop-apply" => {
                let parsed=match self.mode.as_str() {
                    "after"=>parse_duration(&self.duration).map(|duration|now+duration),
                    "at"=>parse_time(&self.date_time,self.offset,now).and_then(|deadline|
                        if deadline>now {Ok(deadline)}else{Err("Choose a stop time in the future.")}),
                    _=>Ok(0.),
                };
                match parsed {
                    Ok(deadline)=>{let mut request=edge.clone();request["stop_at"]=json!(deadline);return Some(request);}
                    Err(error)=>self.error=error.into(),
                }
            }
            _=>{},
        }
        None
    }

    pub fn applied(&mut self, edge: Option<&Value>) {
        let mode=self.mode.clone();self.refresh(edge);self.mode=mode;self.dirty=false;self.error.clear();
    }

    pub fn failed(&mut self, message: String) {self.error=message;}

    pub fn snapshot(&self, edge: Option<&Value>, language: &str, now: f64) -> Snapshot {
        let tr=|source:&str|text(language,source).into_owned();
        let zone=format!("UTC{}{:02}:{:02}",if self.offset>=0 {'+'}else{'-'},self.offset.abs()/60,self.offset.abs()%60);
        let deadline=edge.and_then(|edge|edge["stop_at"].as_f64()).unwrap_or(0.);
        let status=if edge.is_none() {tr("Connection is no longer available.")}
            else if !self.error.is_empty() {tr(&self.error)}
            else if self.dirty {tr(if self.mode=="after" {"After counts from when you apply. Apply again to restart the duration."}else{"Apply to save this connection's stop time."})}
            else if deadline<=0. {tr("No stop time.")}
            else if deadline<=now {tr("Stop time reached. Clear it or choose a later time.")}
            else {tr("Connection stops at %s %s.").replacen("%s",&format_time(deadline,self.offset),1).replacen("%s",&zone,1)};
        Snapshot {mode:self.mode.clone(),duration:self.duration.clone(),date_time:self.date_time.clone(),zone,
            offset_minutes:self.offset,available:edge.is_some(),can_apply:edge.is_some() && (self.dirty || self.mode=="after"),status}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn duration_bounds_units_and_millisecond_rounding() {
        for (source,expected) in [("100ms",0.1),(" 5 m ",300.),("1.5h",5400.),("365d",31536000.),("1.2345s",1.235)] {
            assert_eq!(parse_duration(source),Ok(expected));
        }
        for source in ["99ms","366d","NaNs","infs","-1h","30","", "1ms"] {assert!(parse_duration(source).is_err(),"{source}");}
    }
    #[test]
    fn calendar_validation_and_fixed_offset_clock_rollover() {
        let now=1791658800.; // 2026-10-10 19:00 UTC / Oct 11 04:00 UTC+09
        assert_eq!(format_time(now,540),"2026-10-11 04:00:00");
        assert_eq!(parse_time("04:00",540,now),Ok(now+86400.));
        assert_eq!(parse_time("04:01:02",540,now),Ok(now+62.));
        assert_eq!(parse_time("2026-10-11T04:01:02",540,now),Ok(now+62.));
        assert!(parse_time("2028-02-29 01:00",-330,now).is_ok());
        for source in ["2026-02-29 01:00","2100-02-29 01:00","2026-13-01 01:00","2026-01-01 24:00","2026-01-01 01:60","1969-01-01 01:00","1:00","٠٤:٠٠","2026-1-01 01:00"] {
            assert!(parse_time(source,540,now).is_err(),"{source}");
        }
    }
    #[test]
    fn owner_refresh_and_reapply_preserve_edge_flags_and_drafts() {
        let mut model=Editor {offset:0,..Default::default()};
        let mut edge=json!({"from":"%1","to":"%2","muted":true,"read":true,"events":["answer"],"revision":7,"stop_at":0.});
        model.refresh(Some(&edge));model.command(Some(&edge),"stop-mode","after",100.);
        model.command(Some(&edge),"stop-duration","5m",100.);
        model.refresh(Some(&edge));let request=model.command(Some(&edge),"stop-apply","",100.).unwrap();
        assert_eq!(request["stop_at"],400.);edge["stop_at"]=json!(400.);assert_eq!(request,edge);
        model.applied(Some(&edge));assert_eq!(model.mode,"after");assert!(model.snapshot(Some(&edge),"en-US",101.).can_apply);
        assert_eq!(model.command(Some(&edge),"stop-apply","",110.).unwrap()["stop_at"],410.);
        model.command(Some(&edge),"stop-duration","99ms",100.);assert!(model.command(Some(&edge),"stop-apply","",100.).is_none());
        assert_eq!(model.snapshot(Some(&edge),"en-US",100.).status,DURATION_ERROR);
        edge["stop_at"]=json!(500.);model.refresh(Some(&edge));assert_eq!(model.mode,"at");
        assert!(!model.snapshot(None,"en-US",100.).available);
    }
}
