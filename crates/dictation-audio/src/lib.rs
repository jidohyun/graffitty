//! Bounded uploads use mono Ogg Opus, 48 kHz, 20 ms packets. Live dictation
//! uses the stateful Opus batches defined in [`live`].
//!
//! Codec delay and the final partial frame are trimmed using Ogg granule
//! positions. Verified providers receive the original Opus; custom routes use
//! PCM16 WAV.
#[cfg(target_os = "android")]
pub mod android;
pub mod capture;
pub mod live;
#[cfg(all(
    feature = "device-capture",
    any(target_os = "macos", target_os = "windows", target_os = "linux", target_os = "ios")
))]
pub mod device;
// Its ownership/permission policy is host-testable; only the bridge needs iOS.
#[cfg(all(feature = "device-capture", any(target_os = "ios", test)))]
mod ios;

use ogg::{PacketReader, PacketWriteEndInfo, PacketWriter};
use opus::{Application, Bitrate, Channels, Decoder, Encoder, Signal};
use std::io::Cursor;

pub const RATE: usize = 48_000;
pub const FRAME: usize = 960;
pub const MAX_SAMPLES: usize = RATE * 10;
pub const MAX_OPUS_BYTES: usize = 256 * 1024;
pub type Result<T> = std::result::Result<T, String>;

/// Encode one bounded speech segment. Upsample other device rates to 48 kHz.
pub fn encode(samples: &[f32], rate: u32) -> Result<Vec<u8>> {
    if !(8000..=48000).contains(&rate)
        || samples.is_empty()
        || samples.len() > rate as usize * 10
        || samples.iter().any(|s| !s.is_finite())
    {
        return Err("Expected at most ten seconds of finite mono audio at 8–48 kHz".into());
    }
    let length = (samples.len() * RATE).div_ceil(rate as usize);
    let mut encoder =
        Encoder::new(RATE as u32, Channels::Mono, Application::Audio).map_err(codec_error)?;
    encoder
        .set_bitrate(Bitrate::Bits(32_000))
        .map_err(codec_error)?;
    encoder.set_signal(Signal::Voice).map_err(codec_error)?;
    encoder.set_complexity(5).map_err(codec_error)?;
    let skip = encoder.get_lookahead().map_err(codec_error)? as usize;
    let mut writer = PacketWriter::new(Vec::new());
    let mut head = b"OpusHead\x01\x01".to_vec();
    head.extend_from_slice(&(skip as u16).to_le_bytes());
    head.extend_from_slice(&(RATE as u32).to_le_bytes());
    head.extend_from_slice(&[0, 0, 0]); // zero gain, mono mapping family 0
    writer
        .write_packet(head, 1, PacketWriteEndInfo::EndPage, 0)
        .map_err(container_error)?;
    let mut tags = b"OpusTags".to_vec();
    tags.extend_from_slice(&9u32.to_le_bytes());
    tags.extend_from_slice(b"Graffitty");
    tags.extend_from_slice(&0u32.to_le_bytes());
    writer
        .write_packet(tags, 1, PacketWriteEndInfo::EndPage, 0)
        .map_err(container_error)?;
    let packet_count = (length + skip).div_ceil(FRAME);
    let mut frame = [0.0f32; FRAME];
    let mut packet = [0u8; 1275];
    for n in 0..packet_count {
        for (j, value) in frame.iter_mut().enumerate() {
            let i = n * FRAME + j;
            *value = if i >= length {
                0.0
            } else {
                let position = i as u64 * rate as u64;
                let index = (position / RATE as u64) as usize;
                let fraction = (position % RATE as u64) as f32 / RATE as f32;
                let a = samples[index.min(samples.len() - 1)];
                let b = samples[(index + 1).min(samples.len() - 1)];
                (a + (b - a) * fraction).clamp(-1.0, 1.0)
            };
        }
        let size = encoder
            .encode_float(&frame, &mut packet)
            .map_err(codec_error)?;
        let last = n + 1 == packet_count;
        // Padding only flushes the codec. Neither it nor pre-skip becomes decoded speech.
        let granule = if last { length + skip } else { (n + 1) * FRAME };
        writer
            .write_packet(
                packet[..size].to_vec(),
                1,
                if last {
                    PacketWriteEndInfo::EndStream
                } else {
                    PacketWriteEndInfo::NormalPacket
                },
                granule as u64,
            )
            .map_err(container_error)?;
    }
    Ok(writer.into_inner())
}

/// Accept our bounded mono Opus format; reject truncation, multiplexing, and oversized decode.
pub fn decode(bytes: &[u8]) -> Result<Vec<i16>> {
    let invalid = || "Invalid or incomplete mono Ogg Opus segment".to_owned();
    if bytes.len() > MAX_OPUS_BYTES {
        return Err(invalid());
    }
    let mut reader = PacketReader::new(Cursor::new(bytes));
    let head = reader
        .read_packet()
        .map_err(container_error)?
        .ok_or_else(invalid)?;
    if head.data.len() != 19
        || &head.data[..10] != b"OpusHead\x01\x01"
        || head.data[16..19] != [0, 0, 0]
        || !head.first_in_stream()
        || head.last_in_stream()
    {
        return Err(invalid());
    }
    let serial = head.stream_serial();
    let skip = u16::from_le_bytes(head.data[10..12].try_into().unwrap()) as usize;
    if skip > FRAME {
        return Err(invalid());
    }
    let tags = reader
        .read_packet()
        .map_err(container_error)?
        .ok_or_else(invalid)?;
    if tags.stream_serial() != serial
        || !tags.data.starts_with(b"OpusTags")
        || tags.data.len() > 4096
        || tags.last_in_stream()
        || tags.first_in_stream()
    {
        return Err(invalid());
    }
    let mut decoder = Decoder::new(RATE as u32, Channels::Mono).map_err(codec_error)?;
    let mut output = Vec::new();
    let mut frame = [0i16; FRAME];
    let mut end = None;
    while let Some(packet) = reader.read_packet().map_err(container_error)? {
        if end.is_some()
            || packet.stream_serial() != serial
            || packet.first_in_stream()
            || packet.data.is_empty()
            || packet.data.len() > 1275
            || output.len() >= MAX_SAMPLES + skip + FRAME
        {
            return Err(invalid());
        }
        let count = decoder
            .decode(&packet.data, &mut frame, false)
            .map_err(codec_error)?;
        if count != FRAME {
            return Err(invalid());
        }
        output.extend_from_slice(&frame);
        if packet.last_in_stream() {
            let granule = usize::try_from(packet.absgp_page()).map_err(|_| invalid())?;
            if granule <= skip
                || granule > output.len()
                || output.len() - granule >= FRAME
                || granule - skip > MAX_SAMPLES
            {
                return Err(invalid());
            }
            end = Some(granule);
        } else if packet.last_in_page() && packet.absgp_page() != output.len() as u64 {
            return Err(invalid());
        }
    }
    let end = end.ok_or_else(invalid)?;
    Ok(output[skip..end].to_vec())
}

pub struct ProviderAudio {
    pub bytes: Vec<u8>,
    pub format: &'static str,
    pub mime: &'static str,
}

impl ProviderAudio {
    /// Build an OpenAI-compatible audio transcription upload.
    pub fn multipart(&self, model: &str, language: &str) -> (String, Vec<u8>) {
        let boundary = format!("Graffitty{}", uuid::Uuid::new_v4().simple());
        let mut body = Vec::new();
        let mut field = |name: &str, value: &str| {
            let header = format!(
                "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
            );
            body.extend_from_slice(header.as_bytes());
        };
        field("model", model);
        field("response_format", "json");
        if !language.is_empty() {
            field(
                if model == "gpt-transcribe" {
                    "languages[]"
                } else {
                    "language"
                },
                language,
            );
        }
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"dictation.{}\"\r\nContent-Type: {}\r\n\r\n", self.format, self.mime).as_bytes());
        body.extend_from_slice(&self.bytes);
        body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
        (format!("multipart/form-data; boundary={boundary}"), body)
    }
}

/// Keep the capability decision identical in the server and direct-device paths.
/// Only the tested presets at their official endpoints opt into Opus passthrough.
pub fn provider_audio(
    bytes: &[u8],
    provider: &str,
    model: &str,
    base_url: &str,
) -> Result<ProviderAudio> {
    // Passthrough must still reject corrupt, truncated, or overlong recordings.
    let pcm = decode(bytes)?;
    let opus = match (provider, base_url.trim_end_matches('/')) {
        ("openai", "https://api.openai.com/v1") => model == "gpt-transcribe",
        ("gemini", "https://generativelanguage.googleapis.com/v1beta") => {
            model == "gemini-3.5-transcribe"
        }
        _ => false,
    };
    Ok(if opus {
        ProviderAudio {
            bytes: bytes.to_vec(),
            format: "ogg",
            mime: "audio/ogg",
        }
    } else {
        ProviderAudio {
            bytes: wave(&pcm),
            format: "wav",
            mime: "audio/wav",
        }
    })
}

/// PCM16 WAV compatibility for providers without verified Opus support.
pub fn provider_wave(bytes: &[u8]) -> Result<Vec<u8>> {
    Ok(wave(&decode(bytes)?))
}

fn wave(pcm: &[i16]) -> Vec<u8> {
    let data_size = (pcm.len() * 2) as u32;
    let mut out = Vec::with_capacity(44 + data_size as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + data_size).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&(RATE as u32).to_le_bytes());
    out.extend_from_slice(&(RATE as u32 * 2).to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&data_size.to_le_bytes());
    for sample in pcm {
        out.extend_from_slice(&sample.to_le_bytes());
    }
    out
}

fn codec_error(error: opus::Error) -> String {
    format!("Opus codec: {error}")
}
fn container_error(error: impl std::fmt::Display) -> String {
    format!("Ogg container: {error}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(length: usize) -> Vec<f32> {
        (0..length)
            .map(|i| (i as f32 * 0.0576).sin() * 0.4)
            .collect()
    }

    #[test]
    fn verified_presets_pass_through_and_custom_routes_use_wave() {
        let opus = encode(&tone(4817), 48000).unwrap();
        let wav = provider_wave(&opus).unwrap();
        for (provider, model, base) in [
            ("openai", "gpt-transcribe", "https://api.openai.com/v1"),
            (
                "gemini",
                "gemini-3.5-transcribe",
                "https://generativelanguage.googleapis.com/v1beta",
            ),
        ] {
            let audio = provider_audio(&opus, provider, model, &format!("{base}/")).unwrap();
            assert_eq!((audio.format, audio.mime), ("ogg", "audio/ogg"));
            assert_eq!(audio.bytes, opus);
            for (p, m, b) in [
                (provider, "custom-model", base),
                (provider, model, "https://custom.example/v1"),
                ("openai-compatible", model, base),
            ] {
                let audio = provider_audio(&opus, p, m, b).unwrap();
                assert_eq!((audio.format, audio.mime), ("wav", "audio/wav"));
                assert_eq!(audio.bytes, wav);
            }
            assert!(provider_audio(&opus[..opus.len() - 1], provider, model, base).is_err());
            assert!(
                provider_audio(
                    &[opus.clone(), opus.clone()].concat(),
                    provider,
                    model,
                    base
                )
                .is_err()
            );
        }
    }

    #[test]
    fn partial_last_frames_and_encoder_lookahead_preserve_duration_and_tail() {
        for length in [1, 480, 960, 961, 4800, 4817, MAX_SAMPLES] {
            let pcm = tone(length);
            let encoded = encode(&pcm, 48000).unwrap();
            assert!(encoded.starts_with(b"OggS"));
            let decoded = decode(&encoded).unwrap();
            assert_eq!(decoded.len(), length);
            if length > 480 {
                let tail = &decoded[length - 240..];
                assert!(
                    tail.iter().map(|&s| (s as f64).powi(2)).sum::<f64>() / 240.0 > 1_000_000.0,
                    "The last 5 ms must contain the signal, not lost codec delay"
                );
            }
            if length == MAX_SAMPLES {
                assert!(encoded.len() < length * 2 / 10);
            }
        }
    }

    #[test]
    fn resampling_and_provider_conversion_have_exact_lengths() {
        for rate in [8000, 16000, 24000, 44100, 48000] {
            let encoded = encode(&tone(rate as usize / 10), rate).unwrap();
            let wave = provider_wave(&encoded).unwrap();
            assert_eq!(wave.len(), 44 + 4800 * 2);
            assert_eq!(&wave[..4], b"RIFF");
            assert_eq!(u32::from_le_bytes(wave[24..28].try_into().unwrap()), 48000);
        }
    }

    #[test]
    fn reject_corruption_truncation_concatenation_and_resource_abuse() {
        let good = encode(&tone(4800), 48000).unwrap();
        for end in [0, 20, good.len() - 1, good.len() - 30] {
            assert!(decode(&good[..end]).is_err());
        }
        let mut corrupt = good.clone();
        let last = corrupt.len() - 1;
        corrupt[last] ^= 1;
        assert!(decode(&corrupt).is_err());
        assert!(decode(&[good.clone(), good].concat()).is_err());
        assert!(decode(&vec![0; MAX_OPUS_BYTES + 1]).is_err());
        assert!(encode(&tone(MAX_SAMPLES + 1), 48000).is_err());
        assert!(encode(&[f32::NAN], 48000).is_err());
    }
}
