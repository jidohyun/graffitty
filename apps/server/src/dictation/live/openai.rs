//! Port of Polyglot Android's AudioModels.setup, TranscriptBuffer and
//! LiveAudioSocket source-transcription path. One microphone interaction is
//! one manual turn; no local silence gate, denoising or artificial audio tail.
use super::*;

fn setup(config: &Provider, language: &str) -> Value {
    let mut transcription = json!({"model":config.model});
    let current = config.model.starts_with("gpt-live-transcribe")
        || config.model.starts_with("gpt-transcribe");
    if config.model.starts_with("gpt-live-transcribe") {
        transcription["delay"] = json!("minimal");
    }
    if !language.is_empty() && language != "auto" {
        let language = language.to_lowercase();
        let language = if matches!(language.as_str(), "zh-cn" | "zh-tw" | "zh-hk") {
            language.as_str()
        } else {
            language.split('-').next().unwrap_or(&language)
        };
        if current {
            transcription["languages"] = json!([language]);
        } else {
            transcription["language"] = json!(language);
        }
    }
    json!({"type":"session.update", "session":{"type":"transcription", "audio":{"input":{
        "format":{"type":"audio/pcm","rate":24000},
        "transcription":transcription, "turn_detection":null, "noise_reduction":null
    }}}})
}

#[derive(Default)]
struct Item {
    text: String,
    complete: bool,
}

/// Completions replace deltas by item ID and late deltas cannot reopen an item.
#[derive(Default)]
struct TranscriptBuffer {
    order: Vec<String>,
    items: BTreeMap<String, Item>,
}
impl TranscriptBuffer {
    fn receive(&mut self, event: &Value) -> Result<bool, String> {
        let kind = event["type"].as_str().unwrap_or("");
        if !matches!(
            kind,
            "input_audio_buffer.committed"
                | "conversation.item.input_audio_transcription.delta"
                | "conversation.item.input_audio_transcription.completed"
        ) {
            return Ok(false);
        }
        let id = event["item_id"]
            .as_str()
            .filter(|id| !id.is_empty() && id.len() <= 256)
            .ok_or("Invalid live transcription item")?;
        if !self.items.contains_key(id) && self.items.len() >= 1024 {
            return Err("Too many transcription items".into());
        }
        let item = self.items.entry(id.to_owned()).or_default();
        if !self.order.iter().any(|item| item == id) {
            self.order.push(id.to_owned());
        }
        let mut completed = false;
        match kind {
            "input_audio_buffer.committed" => {
                self.order.retain(|item| item != id);
                let previous = event["previous_item_id"].as_str().unwrap_or("");
                let at = self
                    .order
                    .iter()
                    .position(|item| item == previous)
                    .map_or(self.order.len(), |at| at + 1);
                self.order.insert(at, id.to_owned());
            }
            "conversation.item.input_audio_transcription.delta" if !item.complete => {
                item.text.push_str(
                    event["delta"]
                        .as_str()
                        .ok_or("Invalid transcription delta")?,
                );
            }
            "conversation.item.input_audio_transcription.completed" => {
                completed = !item.complete;
                item.text = event["transcript"]
                    .as_str()
                    .ok_or("Invalid final transcript")?
                    .to_owned();
                item.complete = true;
            }
            _ => (),
        }
        if self
            .items
            .values()
            .map(|item| item.text.len())
            .sum::<usize>()
            > MAX_TEXT
        {
            return Err("Transcript is too long.".into());
        }
        Ok(completed)
    }
    fn text(&self) -> String {
        self.order
            .iter()
            .filter_map(|id| self.items.get(id))
            .map(|item| item.text.trim())
            .filter(|text| !text.is_empty())
            .collect::<Vec<_>>()
            .join(" ")
    }
}

pub(super) fn stream(
    config: &Provider,
    key: &str,
    language: &str,
    rate: usize,
    input: mpsc::Receiver<Input>,
    state: &Mutex<Transcript>,
    canceled: &AtomicBool,
) -> Result<(), String> {
    if canceled.load(Ordering::Acquire) {
        return Ok(());
    }
    let mut socket = socket(config, key, true)?;
    send(&mut socket, setup(config, language))?;
    let started = Instant::now();
    let mut ready = false;
    let mut sent_bytes = 0;
    let mut ending: Option<Instant> = None;
    let mut transcript = TranscriptBuffer::default();
    let mut resampler = Resampler::to_rate(rate, 24000);
    loop {
        if canceled.load(Ordering::Acquire) {
            return Ok(());
        }
        if !ready && started.elapsed() >= SETUP_TIMEOUT {
            return Err("Live transcription setup timed out. Check the server's provider URL, model and network connection, then retry.".into());
        }
        if ending.is_some_and(|at| at.elapsed() >= FINAL_TIMEOUT) {
            return Err("Final transcription timed out. The preview is preserved.".into());
        }
        if started.elapsed() >= Duration::from_secs(615) {
            return Err(
                "Live transcription reached its time limit. The preview is preserved.".into(),
            );
        }
        if ready && ending.is_none() {
            for _ in 0..8 {
                match input.try_recv() {
                    Ok(Input::Audio(raw)) => {
                        let pcm = resampler.convert(&raw);
                        if !pcm.is_empty() {
                            sent_bytes += pcm.len();
                            send(
                                &mut socket,
                                json!({"type":"input_audio_buffer.append", "audio":STANDARD.encode(pcm)}),
                            )?;
                        }
                    }
                    Ok(Input::Finish) => {
                        // Like Polyglot, do not commit an uncommittable <100 ms
                        // buffer or pad it with silence. Keep any received text.
                        if sent_bytes < 4800 {
                            return Ok(());
                        }
                        send(&mut socket, json!({"type":"input_audio_buffer.commit"}))?;
                        ending = Some(Instant::now());
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
                }
            }
        }
        if let Some(event) = receive(&mut socket)? {
            if !event["error"].is_null() {
                if event["error"]["code"] == "input_audio_buffer_commit_empty" && ending.is_some() {
                    return Ok(());
                }
                return Err(provider::response_error(&event));
            }
            match event["type"].as_str().unwrap_or("") {
                "session.updated" | "transcription_session.updated" => ready = true,
                "conversation.item.input_audio_transcription.failed" => {
                    return Err("Speech transcription failed. Try recording again. The preview is preserved.".into());
                }
                "session.closed" => {
                    return Err("Live transcription closed before the final result. Try recording again. The preview is preserved.".into());
                }
                _ => (),
            }
            let completed = transcript.receive(&event)?;
            let mut state = state.lock().unwrap();
            state.interim = transcript.text();
            if completed && ending.is_some() && transcript.items.values().all(|item| item.complete)
            {
                state.committed = std::mem::take(&mut state.interim);
                return Ok(());
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_recording_stopped_before_setup_is_sent_without_padding_or_commit() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let provider = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            let mut ws = tungstenite::accept(tcp).unwrap();
            let setup: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(setup["type"], "session.update");
            ws.send(Message::Text(
                json!({"type":"transcription_session.updated"})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            let audio: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(audio["type"], "input_audio_buffer.append");
            let bytes = STANDARD.decode(audio["audio"].as_str().unwrap()).unwrap();
            assert_eq!(bytes.len(), 18); // All 17 captured samples, resampled 48 -> 24 kHz.
            assert!(ws.read().is_err(), "No empty or sub-100 ms commit is sent");
        });
        let config = Provider {
            model: "gpt-live-transcribe".into(),
            base_url: format!("http://{address}/v1"),
            ..Provider::default()
        };
        let (tx, rx) = mpsc::sync_channel(2);
        tx.send(Input::Audio(vec![0; 34])).unwrap();
        tx.send(Input::Finish).unwrap();
        let state = Mutex::new(Transcript::default());
        stream(
            &config,
            "fixture-key",
            "auto",
            48000,
            rx,
            &state,
            &AtomicBool::new(false),
        )
        .unwrap();
        provider.join().unwrap();
        assert!(state.lock().unwrap().text().is_empty());
    }

    #[test]
    fn setup_uses_polyglot_manual_turns_and_current_language_schema() {
        for model in ["gpt-live-transcribe", "gpt-transcribe"] {
            let config = Provider {
                model: model.into(),
                ..Provider::default()
            };
            let value = setup(&config, "ko-KR");
            let input = &value["session"]["audio"]["input"];
            assert_eq!(input["format"], json!({"type":"audio/pcm","rate":24000}));
            assert!(input["turn_detection"].is_null());
            assert!(input["noise_reduction"].is_null());
            assert_eq!(input["transcription"]["languages"], json!(["ko"]));
            assert_eq!(
                input["transcription"]["delay"] == "minimal",
                model == "gpt-live-transcribe"
            );
            assert!(
                setup(&config, "auto")["session"]["audio"]["input"]["transcription"]
                    .get("languages")
                    .is_none()
            );
        }
    }

    #[test]
    fn transcript_orders_items_replaces_deltas_and_ignores_late_deltas() {
        let mut buffer = TranscriptBuffer::default();
        for event in [
            json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"b","delta":"wor"}),
            json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"Hello"}),
            json!({"type":"input_audio_buffer.committed","item_id":"b","previous_item_id":"a"}),
            json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"world!"}),
            json!({"type":"conversation.item.input_audio_transcription.delta","item_id":"b","delta":"duplicate"}),
        ] {
            buffer.receive(&event).unwrap();
        }
        assert_eq!(buffer.text(), "Hello world!");
        assert!(!buffer.receive(&json!({"type":"conversation.item.input_audio_transcription.completed","item_id":"b","transcript":"world!"})).unwrap());
    }

    #[test]
    fn pcm24_keeps_packet_boundaries_and_partial_final_frame() {
        for rate in [16000, 24000, 44100, 48000] {
            let input: Vec<u8> = (0..4817i16).flat_map(i16::to_le_bytes).collect();
            let expected = Resampler::to_rate(rate, 24000).convert(&input);
            let mut stream = Resampler::to_rate(rate, 24000);
            let actual: Vec<u8> = input
                .chunks(34)
                .flat_map(|chunk| stream.convert(chunk))
                .collect();
            assert_eq!(actual, expected);
            assert_eq!(actual.len(), (4817usize * 24000).div_ceil(rate) * 2);
        }
    }
}
