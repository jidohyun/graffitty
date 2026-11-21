//! Stateful mono 48 kHz Opus transport, 32 kbps and 20 ms frames.
//!
//! Each append is one batch: flags (bit 0 first, bit 1 final), LE u16
//! pre-skip, LE u16 end-trim, then repeated LE u16 packet length + Opus
//! packet.
//!
//! Pre-skip is only allowed on the first batch, end-trim only on the final
//! one. At most seven packets (140 ms, including codec flush) fit in a batch.
//!
//! Offsets count encoded bytes; duration limits count decoded samples, not
//! wire bytes.
use super::{FRAME, RATE, Result, codec_error};
use opus::{Application, Bitrate, Channels, Decoder, Encoder, Signal};

pub const MAX_BATCH_BYTES: usize = 5 + 7 * (2 + 1275);
pub const MAX_INPUT_SAMPLES: usize = RATE / 10;

pub struct LiveEncoder {
    codec: Encoder,
    pending: Vec<f32>,
    skip: usize,
    first: bool,
    finished: bool,
}

impl LiveEncoder {
    pub fn new() -> Result<Self> {
        let mut codec =
            Encoder::new(RATE as u32, Channels::Mono, Application::Audio).map_err(codec_error)?;
        codec
            .set_bitrate(Bitrate::Bits(32_000))
            .map_err(codec_error)?;
        codec.set_signal(Signal::Voice).map_err(codec_error)?;
        codec.set_complexity(5).map_err(codec_error)?;
        let skip = codec.get_lookahead().map_err(codec_error)? as usize;
        Ok(Self {
            codec,
            pending: Vec::new(),
            skip,
            first: true,
            finished: false,
        })
    }

    /// Input chunks need not align to codec frames. Finish flushes delayed speech
    /// and pads the last frame; the decoder trims both delay and padding exactly.
    pub fn encode(&mut self, samples: &[f32], finish: bool) -> Result<Vec<u8>> {
        if self.finished
            || samples.len() > MAX_INPUT_SAMPLES
            || samples.iter().any(|s| !s.is_finite())
        {
            return Err("Invalid live microphone chunk or already finished stream".into());
        }
        self.pending
            .extend(samples.iter().map(|s| s.clamp(-1.0, 1.0)));
        let trim = if finish {
            self.pending.resize(self.pending.len() + self.skip, 0.0);
            let padded = self.pending.len().div_ceil(FRAME) * FRAME;
            let trim = padded - self.pending.len();
            self.pending.resize(padded, 0.0);
            trim
        } else {
            0
        };
        let count = self.pending.len() / FRAME;
        if count == 0 {
            return Ok(Vec::new());
        }
        let mut bytes = vec![u8::from(self.first) | (u8::from(finish) << 1)];
        bytes.extend_from_slice(&(if self.first { self.skip as u16 } else { 0 }).to_le_bytes());
        bytes.extend_from_slice(&(trim as u16).to_le_bytes());
        let mut packet = [0; 1275];
        for frame in self.pending[..count * FRAME].chunks_exact(FRAME) {
            let size = self
                .codec
                .encode_float(frame, &mut packet)
                .map_err(codec_error)?;
            bytes.extend_from_slice(&(size as u16).to_le_bytes());
            bytes.extend_from_slice(&packet[..size]);
        }
        self.pending.drain(..count * FRAME);
        self.first = false;
        self.finished = finish;
        Ok(bytes)
    }
}

pub struct LiveDecoder {
    codec: Decoder,
    first: bool,
    finished: bool,
    failed: bool,
}

impl LiveDecoder {
    pub fn new() -> Result<Self> {
        Ok(Self {
            codec: Decoder::new(RATE as u32, Channels::Mono).map_err(codec_error)?,
            first: true,
            finished: false,
            failed: false,
        })
    }

    pub fn finished(&self) -> bool {
        self.finished
    }

    /// Validate the whole batch before touching decoder state. No PLC, stereo,
    /// variable-duration packets, trailing garbage, or unbounded allocations.
    pub fn decode(&mut self, bytes: &[u8]) -> Result<Vec<u8>> {
        let invalid = || "Invalid or out-of-order live Opus batch".to_owned();
        if self.failed || self.finished || bytes.len() < 8 || bytes.len() > MAX_BATCH_BYTES {
            return Err(invalid());
        }
        let flags = bytes[0];
        let skip = u16::from_le_bytes([bytes[1], bytes[2]]) as usize;
        let trim = u16::from_le_bytes([bytes[3], bytes[4]]) as usize;
        let final_batch = flags & 2 != 0;
        if flags & !3 != 0
            || (flags & 1 != 0) != self.first
            || skip > FRAME
            || (!self.first && skip != 0)
            || trim >= FRAME
            || (!final_batch && trim != 0)
        {
            return Err(invalid());
        }
        let mut packets = Vec::new();
        let mut rest = &bytes[5..];
        while !rest.is_empty() {
            if rest.len() < 2 || packets.len() == 7 {
                return Err(invalid());
            }
            let size = u16::from_le_bytes([rest[0], rest[1]]) as usize;
            rest = &rest[2..];
            if size == 0 || size > 1275 || size > rest.len() {
                return Err(invalid());
            }
            let packet = &rest[..size];
            if opus::packet::get_nb_samples(packet, RATE as u32).map_err(codec_error)? != FRAME
                || opus::packet::get_nb_channels(packet).map_err(codec_error)? != Channels::Mono
            {
                return Err(invalid());
            }
            packets.push(packet);
            rest = &rest[size..];
        }
        if skip + trim > packets.len() * FRAME {
            return Err(invalid());
        }
        // A codec failure may have advanced state; never resume that stream.
        self.failed = true;
        let mut samples = Vec::with_capacity(packets.len() * FRAME);
        for packet in packets {
            let mut frame = [0i16; FRAME];
            let count = self
                .codec
                .decode(packet, &mut frame, false)
                .map_err(codec_error)?;
            if count != FRAME {
                return Err(invalid());
            }
            samples.extend_from_slice(&frame);
        }
        self.failed = false;
        self.first = false;
        self.finished = final_batch;
        Ok(samples[skip..samples.len() - trim]
            .iter()
            .flat_map(|s| s.to_le_bytes())
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn roundtrip(length: usize, chunk: usize) -> (Vec<u8>, usize) {
        let samples: Vec<f32> = (0..length)
            .map(|i| (i as f32 * 0.0576).sin() * 0.25)
            .collect();
        let mut encoder = LiveEncoder::new().unwrap();
        let mut decoder = LiveDecoder::new().unwrap();
        let mut output = Vec::new();
        let mut wire = 0;
        for input in samples.chunks(chunk) {
            let bytes = encoder.encode(input, false).unwrap();
            if !bytes.is_empty() {
                wire += bytes.len();
                output.extend(decoder.decode(&bytes).unwrap());
            }
        }
        let bytes = encoder.encode(&[], true).unwrap();
        wire += bytes.len();
        output.extend(decoder.decode(&bytes).unwrap());
        assert!(decoder.finished());
        assert!(decoder.decode(&bytes).is_err());
        assert!(encoder.encode(&[], true).is_err());
        assert_eq!(output.len(), length * 2);
        (output, wire)
    }

    #[test]
    fn streaming_keeps_short_words_tail_and_delay_exactly() {
        for length in [0, 1, 17, 480, 960, 4817, 48000] {
            let expected = roundtrip(length, 4800).0;
            for chunk in [1, 17, 960, 3000] {
                assert_eq!(roundtrip(length, chunk).0, expected);
            }
        }
        let (pcm, wire) = roundtrip(RATE * 2, 4800);
        assert!(wire < pcm.len() / 15, "wire={wire}, pcm={}", pcm.len());
    }

    #[test]
    fn rejects_malformed_batches_and_wrong_stream_boundaries() {
        let mut encoder = LiveEncoder::new().unwrap();
        let first = encoder.encode(&[0.1; 4800], false).unwrap();
        let final_batch = encoder.encode(&[0.1; 17], true).unwrap();
        for bytes in [
            vec![],
            vec![0; 8],
            vec![0; MAX_BATCH_BYTES + 1],
            first[..first.len() - 1].to_vec(),
        ] {
            assert!(LiveDecoder::new().unwrap().decode(&bytes).is_err());
        }
        let mut decoder = LiveDecoder::new().unwrap();
        assert!(decoder.decode(&final_batch).is_err());
        decoder.decode(&first).unwrap();
        assert!(decoder.decode(&first).is_err());
        decoder.decode(&final_batch).unwrap();
        assert!(decoder.finished());
        assert!(
            LiveEncoder::new()
                .unwrap()
                .encode(&[f32::NAN], false)
                .is_err()
        );
        assert!(
            LiveEncoder::new()
                .unwrap()
                .encode(&vec![0.0; 4801], false)
                .is_err()
        );
    }
}
