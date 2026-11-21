//! Polyglot Live's manual microphone boundaries for Gemini and OpenAI.
//! Only the server sees credentials; terminal RPC never waits on IO.
mod openai;
use super::*;
use base64::{Engine, engine::general_purpose::STANDARD};
use std::{
    io,
    net::{TcpStream, ToSocketAddrs},
    sync::Mutex,
};
use tungstenite::{Message, client::IntoClientRequest, stream::MaybeTlsStream};

const MAX_QUEUE: usize = 52; // Five seconds at 100 ms, codec tail, then Finish.
const MAX_TEXT: usize = 64 * 1024;
const SETUP_TIMEOUT: Duration = Duration::from_secs(12);
const FINAL_TIMEOUT: Duration = Duration::from_secs(12);
type Socket = tungstenite::WebSocket<MaybeTlsStream<TcpStream>>;

enum Input {
    Audio(Vec<u8>),
    Finish,
}
#[derive(Default)]
struct Transcript {
    committed: String,
    interim: String,
    done: bool,
    error: Option<String>,
}
impl Transcript {
    fn text(&self) -> String {
        if self.interim.is_empty() {
            self.committed.clone()
        } else if self.committed.is_empty() || self.interim.starts_with(&self.committed) {
            self.interim.clone()
        } else {
            format!("{} {}", self.committed, self.interim)
        }
    }
    fn receive(&mut self, event: &Value) -> Result<(), String> {
        if !event["error"].is_null() {
            return Err(provider::response_error(event));
        }
        if !event["goAway"].is_null() {
            return Err("Live transcription session expired.".into());
        }
        let content = &event["serverContent"];
        if let Some(text) = content["interimInputTranscription"]["text"].as_str() {
            self.interim = text.trim().into();
        }
        if let Some(text) = content["inputTranscription"]["text"].as_str() {
            let text = text.trim();
            if !text.is_empty() {
                if !self.committed.is_empty() {
                    self.committed.push(' ');
                }
                self.committed.push_str(text);
            }
            self.interim.clear();
        }
        if self.committed.len() + self.interim.len() > MAX_TEXT {
            return Err("Transcript is too long.".into());
        }
        Ok(())
    }
}

pub(super) struct Session {
    pub owner: u64,
    tx: mpsc::SyncSender<Input>,
    state: Arc<Mutex<Transcript>>,
    canceled: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
    offset: usize,
    decoder: graffitty_dictation_audio::live::LiveDecoder,
    samples: usize,
    finishing: bool,
    touched: Instant,
    started: Instant,
}
impl Drop for Session {
    fn drop(&mut self) {
        self.canceled.store(true, Ordering::Release);
    }
}
impl Session {
    pub fn expired(&self) -> bool {
        self.touched.elapsed() > Duration::from_secs(30)
            || self.started.elapsed() > Duration::from_secs(630)
    }
    fn snapshot(&self) -> Value {
        let state = self.state.lock().unwrap();
        json!({"text":state.text(), "done":state.done, "error":state.error, "received":self.offset})
    }
}
impl Service {
    pub(super) fn live_request(
        &mut self,
        config: &Config,
        owner: u64,
        method: &str,
        params: &Value,
        bytes: Option<&[u8]>,
    ) -> Result<api::Reply, Error> {
        let ready = |value| Ok(api::Reply::Ready(json!({"result":value})));
        if !config.enabled {
            return Err(api::error("dictation_disabled", DISABLED_MESSAGE));
        }
        if method == "dictation.live.begin" {
            if self.workers.len() >= MAX_WORKERS || self.live.len() >= MAX_UPLOADS {
                return Err(api::error("busy", "Dictation is busy; retry shortly"));
            }
            let rate = graffitty_dictation_audio::RATE;
            if params["format"] != "opus" || params["sample_rate"].as_u64() != Some(rate as u64) {
                return Err(api::error("dictation_format", "Expected mono Opus at 48 kHz"));
            }
            let decoder = graffitty_dictation_audio::live::LiveDecoder::new()
                .map_err(|e| api::error("dictation_format", &e))?;
            // All recognition choices are owned by server.toml, never the caller.
            let candidates = config.candidates("");
            let language = config.language.clone();
            let secret = self.secret;
            let (tx, rx) = mpsc::sync_channel(MAX_QUEUE);
            let state = Arc::new(Mutex::new(Transcript::default()));
            let canceled = Arc::new(AtomicBool::new(false));
            let done = Arc::new(AtomicBool::new(false));
            let session = Session {
                owner,
                tx,
                state: state.clone(),
                canceled: canceled.clone(),
                done: done.clone(),
                offset: 0,
                decoder,
                samples: 0,
                finishing: false,
                touched: Instant::now(),
                started: Instant::now(),
            };
            std::thread::Builder::new().name("dictation-live".into()).spawn(move || {
                let result = (|| {
                    let (name, provider, key) = provider::select(&candidates, secret)?;
                    match name.as_str() {
                        "gemini" if provider.model.contains("transcribe-live") =>
                            stream(&provider, &key, &language, rate, rx, &state, &canceled),
                        "openai" => openai::stream(&provider, &key, &language, rate, rx, &state, &canceled),
                        _ => Err("On the server, configure [dictation] provider = \"openai\" with a transcription model, or provider = \"gemini\" with model = \"gemini-3.5-transcribe-live\" in server.toml, then restart the server.".into()),
                    }
                })();
                let mut state = state.lock().unwrap();
                if let Err(error) = result { state.error = Some(error); }
                state.done = true;
                done.store(true, Ordering::Release);
            })?;
            let job = uuid::Uuid::new_v4().to_string();
            self.workers.insert(
                job.clone(),
                Work {
                    owner,
                    canceled: session.canceled.clone(),
                    done: session.done.clone(),
                },
            );
            self.live.insert(job.clone(), session);
            return ready(json!({"job":job}));
        }
        let job = params["job"].as_str().ok_or("Expected dictation job")?;
        let session = self
            .live
            .get_mut(job)
            .filter(|s| s.owner == owner)
            .ok_or_else(|| {
                api::error(
                    "dictation_expired",
                    "Dictation expired or belongs to another pane",
                )
            })?;
        session.touched = Instant::now();
        // Setup can fail before the client's first buffered audio arrives.
        // Keep that actionable error instead of replacing it with queue failure.
        if session.state.lock().unwrap().error.is_some() {
            return ready(session.snapshot());
        }
        match method {
            "dictation.live.append" => {
                let audio = bytes.ok_or("Expected binary Opus batch")?;
                if session.finishing
                    || params["offset"].as_u64() != Some(session.offset as u64)
                    || audio.len() > graffitty_dictation_audio::live::MAX_BATCH_BYTES
                {
                    return Err(api::error(
                        "dictation_upload",
                        "Live audio is too large, incomplete, or out of order",
                    ));
                }
                // Bounded decode (at most 140 ms); provider adapters still receive PCM.
                let pcm = session.decoder.decode(audio)
                    .map_err(|e| api::error("dictation_upload", &e))?;
                let samples = pcm.len() / 2;
                if session.samples + samples > graffitty_dictation_audio::RATE * 600 {
                    session.finishing = true;
                    session.canceled.store(true, Ordering::Release);
                    return Err(api::error("dictation_upload", "Live audio exceeds ten minutes"));
                }
                match session.tx.try_send(Input::Audio(pcm)) {
                    Ok(()) => (),
                    // The worker may still be publishing its setup error after
                    // dropping the receiver. Let polling deliver that error.
                    Err(mpsc::TrySendError::Disconnected(_)) => return ready(session.snapshot()),
                    Err(mpsc::TrySendError::Full(_)) => {
                        // Decoder state has advanced; this stream cannot be retried.
                        session.finishing = true;
                        session.canceled.store(true, Ordering::Release);
                        return Err(api::error(
                            "dictation_upload",
                            "Live audio upload could not keep up",
                        ));
                    }
                }
                session.offset += audio.len();
                session.samples += samples;
            }
            "dictation.live.finish" => {
                if params["offset"].as_u64() != Some(session.offset as u64)
                    || !session.decoder.finished()
                {
                    return Err(api::error(
                        "dictation_upload",
                        "Live audio upload is incomplete",
                    ));
                }
                if !session.finishing {
                    match session.tx.try_send(Input::Finish) {
                        Ok(()) => (),
                        Err(mpsc::TrySendError::Disconnected(_)) => {
                            return ready(session.snapshot());
                        }
                        Err(mpsc::TrySendError::Full(_)) => {
                            return Err(api::error(
                                "dictation_upload",
                                "Live audio upload could not keep up",
                            ));
                        }
                    }
                    session.finishing = true;
                }
            }
            "dictation.live.poll" => (),
            _ => {
                return Err(api::error(
                    "unknown_method",
                    "Unknown live dictation method",
                ));
            }
        }
        ready(session.snapshot())
    }
}

fn socket(config: &Provider, key: &str, openai: bool) -> Result<Socket, String> {
    provider::valid_url(&config.base_url)?;
    let base = url::Url::parse(&config.base_url).map_err(|_| "Invalid live provider URL")?;
    let mut endpoint = base.clone();
    endpoint
        .set_scheme(if base.scheme() == "https" {
            "wss"
        } else {
            "ws"
        })
        .map_err(|_| "Invalid live provider URL")?;
    if openai {
        endpoint.set_path(&format!("{}/realtime", base.path().trim_end_matches('/')));
        endpoint.set_query(Some("intent=transcription"));
    } else {
        endpoint.set_path(&format!(
            "/ws/google.ai.generativelanguage.{}.GenerativeService.BidiGenerateContent",
            base.path().trim_matches('/')
        ));
    }
    let mut request = endpoint
        .as_str()
        .into_client_request()
        .map_err(|_| "Invalid live provider URL")?;
    let (header, value) = if openai {
        ("Authorization", format!("Bearer {key}"))
    } else {
        ("x-goog-api-key", key.to_owned())
    };
    request
        .headers_mut()
        .insert(header, value.parse().map_err(|_| "Invalid provider key")?);
    let addresses = (
        base.host_str().ok_or("Invalid live provider host")?,
        base.port_or_known_default()
            .ok_or("Invalid provider port")?,
    )
        .to_socket_addrs()
        .map_err(|_| "Live transcription connection failed")?;
    let deadline = Instant::now() + SETUP_TIMEOUT;
    for address in addresses {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        let Ok(tcp) = TcpStream::connect_timeout(&address, remaining) else {
            continue;
        };
        tcp.set_read_timeout(Some(remaining))
            .map_err(|_| "Live socket timeout failed")?;
        tcp.set_write_timeout(Some(remaining))
            .map_err(|_| "Live socket timeout failed")?;
        let (mut socket, _) = tungstenite::client_tls_with_config(
            request,
            tcp,
            Some(
                tungstenite::protocol::WebSocketConfig::default()
                    .max_message_size(Some(1024 * 1024)),
            ),
            None,
        )
        .map_err(|error| match error {
            tungstenite::HandshakeError::Failure(tungstenite::Error::Http(response)) => {
                let detail = response.body().as_deref()
                    .and_then(|body| serde_json::from_slice::<Value>(body).ok())
                    .map(|value| provider::response_error(&value));
                if detail.as_deref() == Some(provider::KEY_REJECTED) {
                    provider::KEY_REJECTED.into()
                } else {
                    provider::http_error(response.status().as_u16())
                }
            },
            _ => "Live transcription connection failed. Check the server's network connection, provider URL and model in server.toml, then retry.".into(),
        })?;
        let tcp = match socket.get_mut() {
            MaybeTlsStream::Plain(tcp) => tcp,
            MaybeTlsStream::NativeTls(tls) => tls.get_mut(),
            _ => return Err("Unsupported live TLS transport".into()),
        };
        tcp.set_read_timeout(Some(Duration::from_millis(20)))
            .map_err(|_| "Live socket timeout failed")?;
        tcp.set_write_timeout(Some(Duration::from_secs(3)))
            .map_err(|_| "Live socket timeout failed")?;
        return Ok(socket);
    }
    Err("Live transcription connection timed out".into())
}
fn send(socket: &mut Socket, value: Value) -> Result<(), String> {
    socket
        .send(Message::Text(value.to_string().into()))
        .map_err(|_| "Live audio connection failed".into())
}
fn receive(socket: &mut Socket) -> Result<Option<Value>, String> {
    let message = match socket.read() {
        Ok(message) => message,
        Err(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
            ) =>
        {
            return Ok(None);
        }
        Err(_) => return Err("Live transcription disconnected before completion".into()),
    };
    match message {
        Message::Text(text) => serde_json::from_str(&text)
            .map(Some)
            .map_err(|_| "Invalid live transcription response".into()),
        Message::Binary(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| "Invalid live transcription response".into()),
        Message::Close(_) => Err("Live transcription disconnected before completion. Check the server's provider model, API key and quota, then retry. The preview is preserved.".into()),
        _ => Ok(None),
    }
}
fn stream(
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
    let mut socket = socket(config, key, false)?;
    send(
        &mut socket,
        json!({"setup":{
            "model":format!("models/{}", config.model.trim_start_matches("models/")),
            "generationConfig":{"responseModalities":["TEXT"]},
            "inputAudioTranscription":{"mode":"VERBATIM", "languageCodes":if language.is_empty() || language == "auto" { vec![] } else { vec![provider::language_code(language)] }},
            "realtimeInputConfig":{"automaticActivityDetection":{"disabled":true}}
        }}),
    )?;
    let started = Instant::now();
    let mut ready = false;
    let mut sent = false;
    let mut ending: Option<Instant> = None;
    let mut resampler = Resampler::new(rate);
    loop {
        if canceled.load(Ordering::Acquire) {
            return Ok(());
        }
        if !ready && started.elapsed() >= SETUP_TIMEOUT {
            return Err("Live transcription setup timed out".into());
        }
        if ending.is_some_and(|at| at.elapsed() >= FINAL_TIMEOUT) {
            return Err("Final transcription timed out. The preview is preserved.".into());
        }
        if started.elapsed() >= Duration::from_secs(615) {
            return Err("Live transcription reached its time limit".into());
        }
        if ready && ending.is_none() {
            // Bounded bursts leave room for receiving interim hypotheses during upload.
            for _ in 0..8 {
                match input.try_recv() {
                    Ok(Input::Audio(raw)) => {
                        if !sent {
                            send(&mut socket, json!({"realtimeInput":{"activityStart":{}}}))?;
                            sent = true;
                        }
                        let pcm = resampler.convert(&raw);
                        if !pcm.is_empty() {
                            send(
                                &mut socket,
                                json!({"realtimeInput":{"audio":{"data":STANDARD.encode(pcm),"mimeType":"audio/pcm;rate=16000"}}}),
                            )?;
                        }
                    }
                    Ok(Input::Finish) => {
                        if !sent {
                            return Ok(());
                        }
                        // Even a partial, very short word is committed. No minimum duration,
                        // local silence gate, or artificial tail on the transcription stream.
                        send(&mut socket, json!({"realtimeInput":{"activityEnd":{}}}))?;
                        ending = Some(Instant::now());
                        break;
                    }
                    Err(mpsc::TryRecvError::Empty) => break,
                    Err(mpsc::TryRecvError::Disconnected) => return Ok(()),
                }
            }
        }
        if let Some(event) = receive(&mut socket)? {
            let mut transcript = state.lock().unwrap();
            transcript.receive(&event)?;
            if !event["setupComplete"].is_null() {
                ready = true;
            }
            // Input transcription and conversational turn completion are independent.
            // Wait for source generationComplete after activityEnd, as Polyglot does.
            if ending.is_some() && event["serverContent"]["generationComplete"] == true {
                transcript.interim.clear();
                return Ok(());
            }
        }
    }
}

/// Polyglot's causal 63-tap low-pass decimator, with a rational phase for
/// desktop 44.1 kHz capture as well as Android's native 48 kHz. State survives
/// packet boundaries, including the partial final microphone frame.
struct Resampler {
    history: [f64; 63],
    weights: [f64; 63],
    index: usize,
    phase: usize,
    rate: usize,
    target: usize,
    previous: f64,
}
impl Resampler {
    fn new(rate: usize) -> Self {
        Self::to_rate(rate, 16000)
    }
    fn to_rate(rate: usize, target: usize) -> Self {
        let cutoff = 0.45 * target.min(rate) as f64 / rate as f64;
        let mut weights = std::array::from_fn(|i| {
            let x = i as f64 - 31.0;
            (if i == 31 {
                2.0 * cutoff
            } else {
                (2.0 * std::f64::consts::PI * cutoff * x).sin() / (std::f64::consts::PI * x)
            }) * (0.54 - 0.46 * (2.0 * std::f64::consts::PI * i as f64 / 62.0).cos())
        });
        let sum: f64 = weights.iter().sum();
        for weight in &mut weights {
            *weight /= sum;
        }
        Self {
            history: [0.0; 63],
            weights,
            index: 0,
            phase: if target > rate { 0 } else { rate - 1 },
            rate,
            target,
            previous: 0.0,
        }
    }
    fn convert(&mut self, pcm: &[u8]) -> Vec<u8> {
        if self.rate == self.target {
            return pcm.to_vec();
        }
        let mut output = Vec::new();
        for sample in pcm.chunks_exact(2) {
            let sample = i16::from_le_bytes([sample[0], sample[1]]) as f64;
            if self.target > self.rate {
                // Polyglot's causal linear upsampler for 16 kHz capture.
                while self.phase < self.target {
                    let fraction = self.phase as f64 / self.target as f64;
                    let value = self.previous + (sample - self.previous) * fraction;
                    output.extend_from_slice(&(value as i16).to_le_bytes());
                    self.phase += self.rate;
                }
                self.phase -= self.target;
                self.previous = sample;
                continue;
            }
            self.history[self.index] = sample;
            self.phase += self.target;
            if self.phase >= self.rate {
                self.phase -= self.rate;
                let value: f64 = self
                    .weights
                    .iter()
                    .enumerate()
                    .map(|(tap, weight)| weight * self.history[(self.index + 63 - tap) % 63])
                    .sum();
                output.extend_from_slice(
                    &(value.round().clamp(-32768.0, 32767.0) as i16).to_le_bytes(),
                );
            }
            self.index = (self.index + 1) % 63;
        }
        output
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn hypotheses_replace_instead_of_repeating_and_errors_are_not_text() {
        let mut state = Transcript::default();
        for text in ["hel", "hello", "hello world"] {
            state
                .receive(&json!({"serverContent":{"interimInputTranscription":{"text":text}}}))
                .unwrap();
            assert_eq!(state.text(), text);
        }
        state
            .receive(&json!({"serverContent":{"inputTranscription":{"text":"Hello world."}}}))
            .unwrap();
        state
            .receive(&json!({"serverContent":{"interimInputTranscription":{"text":"Next"}}}))
            .unwrap();
        assert_eq!(state.text(), "Hello world. Next");
        state.receive(&json!({"serverContent":{"interimInputTranscription":{"text":"Hello world. Next word"}}})).unwrap();
        assert_eq!(state.text(), "Hello world. Next word");
        assert!(
            state
                .receive(&json!({"error":{"message":"secret"}}))
                .is_err()
        );
        assert!(!state.text().contains("secret"));
    }

    #[test]
    fn resampling_is_independent_of_packet_boundaries_and_keeps_short_tail() {
        for rate in [16000, 24000, 44100, 48000] {
            let input: Vec<u8> = (0..4817i16).flat_map(i16::to_le_bytes).collect();
            let expected = Resampler::new(rate).convert(&input);
            let mut stream = Resampler::new(rate);
            let actual: Vec<u8> = input
                .chunks(34)
                .flat_map(|chunk| stream.convert(chunk))
                .collect();
            assert_eq!(actual, expected);
            assert_eq!(actual.len(), (4817usize * 16000).div_ceil(rate) * 2);
            assert!(!Resampler::new(rate).convert(&[1, 0]).is_empty());
        }
    }

    #[test]
    fn live_stream_shows_interim_before_stop_and_waits_for_final_short_word() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        let (heard_tx, heard_rx) = mpsc::channel();
        let provider = std::thread::spawn(move || {
            let (tcp, _) = listener.accept().unwrap();
            tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
            let mut ws = tungstenite::accept(tcp).unwrap();
            let setup: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(setup["setup"]["model"], "models/gemini-3.5-transcribe-live");
            assert_eq!(
                setup["setup"]["inputAudioTranscription"]["languageCodes"],
                json!(["ko-KR"])
            );
            assert_eq!(
                setup["setup"]["realtimeInputConfig"]["automaticActivityDetection"]["disabled"],
                true
            );
            // Audio and Stop may already be queued before the provider is ready.
            ws.send(Message::Text(
                json!({"setupComplete":{}}).to_string().into(),
            ))
            .unwrap();
            let start: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert!(start["realtimeInput"]["activityStart"].is_object());
            let audio: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            let bytes = STANDARD
                .decode(audio["realtimeInput"]["audio"]["data"].as_str().unwrap())
                .unwrap();
            assert_eq!(bytes.len(), 320); // A 10 ms word, never rejected as too short.
            ws.send(Message::Text(
                json!({"serverContent":{"interimInputTranscription":{"text":"안"}}})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            heard_tx.send(()).unwrap();
            let stop: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
            assert!(stop["realtimeInput"]["activityEnd"].is_object());
            ws.send(Message::Text(
                json!({"serverContent":{"turnComplete":true}})
                    .to_string()
                    .into(),
            ))
            .unwrap();
            std::thread::sleep(Duration::from_millis(50));
            ws.send(Message::Text(json!({"serverContent":{"inputTranscription":{"text":"안녕"},"generationComplete":true}}).to_string().into())).unwrap();
        });
        let config = Provider {
            model: "gemini-3.5-transcribe-live".into(),
            base_url: format!("http://{address}/v1beta"),
            ..Provider::default()
        };
        let (tx, rx) = mpsc::sync_channel(50);
        tx.send(Input::Audio(vec![0; 960])).unwrap();
        let state = Arc::new(Mutex::new(Transcript::default()));
        let worker_state = state.clone();
        let worker = std::thread::spawn(move || {
            stream(
                &config,
                "fixture-key",
                "ko",
                48000,
                rx,
                &worker_state,
                &AtomicBool::new(false),
            )
        });
        heard_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        while state.lock().unwrap().text().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(state.lock().unwrap().text(), "안");
        assert!(
            !worker.is_finished(),
            "Interim text must arrive while input is still open"
        );
        tx.send(Input::Finish).unwrap();
        worker.join().unwrap().unwrap();
        provider.join().unwrap();
        assert_eq!(state.lock().unwrap().text(), "안녕");
    }

    #[test]
    fn live_opus_rpc_requires_codec_tail_and_bounds_decoded_duration() {
        let config = Config { enabled: true, ..Config::default() };
        let mut service = Service::default();
        for params in [
            json!({"format":"pcm16", "sample_rate":48000}),
            json!({"format":"ogg-opus", "sample_rate":48000}),
            json!({"format":"opus", "sample_rate":16000}),
        ] {
            assert!(service.request(&config, 7, "dictation.live.begin", &params, None).is_err());
        }
        let (tx, rx) = mpsc::sync_channel(10);
        service.live.insert("fixture".into(), Session {
            owner: 7, tx,
            state: Arc::new(Mutex::new(Transcript::default())),
            canceled: Arc::new(AtomicBool::new(false)),
            done: Arc::new(AtomicBool::new(false)),
            offset: 0,
            decoder: graffitty_dictation_audio::live::LiveDecoder::new().unwrap(),
            samples: 0, finishing: false,
            touched: Instant::now(), started: Instant::now(),
        });
        let mut encoder = graffitty_dictation_audio::live::LiveEncoder::new().unwrap();
        let first = encoder.encode(&[0.1; 4800], false).unwrap();
        let tail = encoder.encode(&[0.1; 17], true).unwrap();
        service.request(&config, 7, "dictation.live.append",
            &json!({"job":"fixture", "offset":0}), Some(&first)).unwrap();
        assert!(service.request(&config, 7, "dictation.live.finish",
            &json!({"job":"fixture", "offset":first.len()}), None).is_err());
        // The tiny compressed tail must not evade the ten-minute decoded limit.
        let actual = service.live["fixture"].samples;
        service.live.get_mut("fixture").unwrap().samples = graffitty_dictation_audio::RATE * 600;
        // The duration violation must fail closed.
        assert!(service.request(&config, 7, "dictation.live.append",
            &json!({"job":"fixture", "offset":first.len()}), Some(&tail)).is_err());
        assert!(service.live["fixture"].canceled.load(Ordering::Acquire));
        // Reset the test fixture to check the normal final-tail path as well.
        let session = service.live.get_mut("fixture").unwrap();
        session.decoder = graffitty_dictation_audio::live::LiveDecoder::new().unwrap();
        session.decoder.decode(&first).unwrap();
        session.samples = actual;
        session.finishing = false;
        session.canceled.store(false, Ordering::Release);
        service.request(&config, 7, "dictation.live.append",
            &json!({"job":"fixture", "offset":first.len()}), Some(&tail)).unwrap();
        let offset = first.len() + tail.len();
        assert_eq!(service.live["fixture"].samples, 4817);
        assert!(service.request(&config, 7, "dictation.live.append",
            &json!({"job":"fixture", "offset":offset}), Some(&tail)).is_err());
        service.request(&config, 7, "dictation.live.finish",
            &json!({"job":"fixture", "offset":offset}), None).unwrap();
        let Input::Audio(first_pcm) = rx.recv().unwrap() else { panic!() };
        let Input::Audio(tail_pcm) = rx.recv().unwrap() else { panic!() };
        assert_eq!(first_pcm.len() + tail_pcm.len(), 4817 * 2);
        assert!(matches!(rx.recv().unwrap(), Input::Finish));
    }

    #[test]
    fn live_rpc_is_owned_ordered_bounded_and_cancel_drops_worker() {
        let (tx, _rx) = mpsc::sync_channel(1);
        let canceled = Arc::new(AtomicBool::new(false));
        let mut service = Service::default();
        service.live.insert(
            "fixture".into(),
            Session {
                owner: 7,
                tx,
                state: Arc::new(Mutex::new(Transcript::default())),
                canceled: canceled.clone(),
                done: Arc::new(AtomicBool::new(false)),
                offset: 0,
                decoder: graffitty_dictation_audio::live::LiveDecoder::new().unwrap(),
                samples: 0,
                finishing: false,
                touched: Instant::now(),
                started: Instant::now(),
            },
        );
        let config = Config {
            enabled: true,
            ..Config::default()
        };
        let params = json!({"job":"fixture","offset":0});
        let mut encoder = graffitty_dictation_audio::live::LiveEncoder::new().unwrap();
        let audio = encoder.encode(&[0.1; 4800], false).unwrap();
        assert!(
            service
                .request(&config, 8, "dictation.live.append", &params, Some(&[0, 0]))
                .is_err()
        );
        assert!(
            service
                .request(&config, 7, "dictation.live.append", &params, Some(&[0]))
                .is_err()
        );
        service
            .request(&config, 7, "dictation.live.append", &params, Some(&audio))
            .unwrap();
        assert!(
            service
                .request(&config, 7, "dictation.live.append", &params, Some(&[0, 0]))
                .is_err()
        );
        assert!(
            service
                .request(&config, 7, "dictation.live.finish", &params, None)
                .is_err()
        );
        service
            .request(&config, 8, "dictation.cancel", &params, None)
            .unwrap();
        assert!(!canceled.load(Ordering::Acquire));
        assert!(
            service
                .request(
                    &config,
                    7,
                    "dictation.live.append",
                    &json!({"job":"fixture","offset":audio.len()}),
                    Some(&encoder.encode(&[], true).unwrap())
                )
                .is_err()
        );
        assert!(canceled.load(Ordering::Acquire), "Queue overflow terminates the codec stream");
        service
            .request(&config, 7, "dictation.cancel", &params, None)
            .unwrap();
        assert!(canceled.load(Ordering::Acquire));
        assert!(service.live.is_empty());
    }
}
