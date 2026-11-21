use std::{thread, time::Duration};

#[cfg(not(target_os = "android"))]
pub fn play(pcm: Vec<[f32; 2]>, rate: u32) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, HostTrait};
    let device = cpal::default_host().default_output_device().ok_or("No audio output device")?;
    let supported = device.default_output_config().map_err(|e| e.to_string())?;
    let config = supported.config();
    match supported.sample_format() {
        cpal::SampleFormat::F32 => desktop::<f32>(&device, &config, pcm, rate),
        cpal::SampleFormat::I16 => desktop::<i16>(&device, &config, pcm, rate),
        cpal::SampleFormat::U16 => desktop::<u16>(&device, &config, pcm, rate),
        format => Err(format!("Unsupported audio output format: {format}")),
    }
}

#[cfg(not(target_os = "android"))]
fn desktop<T: cpal::SizedSample + cpal::FromSample<f32>>(
    device: &cpal::Device, config: &cpal::StreamConfig, pcm: Vec<[f32; 2]>, rate: u32,
) -> Result<(), String> {
    use cpal::traits::{DeviceTrait, StreamTrait};
    use std::sync::mpsc;
    let duration = Duration::from_secs_f64(pcm.len() as f64 / rate as f64);
    let channels = config.channels as usize;
    let step = rate as f64 / config.sample_rate as f64;
    let (tx, rx) = mpsc::channel();
    let errors = tx.clone();
    let mut cursor: f64 = 0.0;
    let mut finished = false;
    let stream = device.build_output_stream(*config, move |out: &mut [T], _| {
        for frame in out.chunks_mut(channels) {
            let index = cursor as usize;
            let a = pcm.get(index).copied().unwrap_or([0.0; 2]);
            let b = pcm.get(index + 1).copied().unwrap_or(a);
            let fraction = cursor.fract() as f32;
            let pair = [a[0] + (b[0] - a[0]) * fraction, a[1] + (b[1] - a[1]) * fraction];
            for (channel, sample) in frame.iter_mut().enumerate() {
                *sample = T::from_sample(if channels == 1 { (pair[0] + pair[1]) * 0.5 }
                    else { pair.get(channel).copied().unwrap_or(0.0) });
            }
            cursor += step;
        }
        if cursor >= pcm.len() as f64 && !finished {
            finished = true;
            let _ = tx.send(Ok(()));
        }
    }, move |e| { let _ = errors.send(Err(e.to_string())); }, None).map_err(|e| e.to_string())?;
    stream.play().map_err(|e| e.to_string())?;
    rx.recv_timeout(duration + Duration::from_secs(3)).map_err(|e| e.to_string())??;
    // Drain the last output buffer before dropping the device.
    thread::sleep(Duration::from_millis(250));
    drop(stream);
    Ok(())
}

#[cfg(target_os = "android")]
#[allow(non_snake_case)]
pub fn play(pcm: Vec<[f32; 2]>, rate: u32) -> Result<(), String> {
    use std::{ffi::c_void, ptr};
    // AAudio is available on every supported Android version. No Activity or
    // microphone permission is needed; opening happens only on this worker.
    unsafe {
        let lib = libloading::Library::new("libaaudio.so").map_err(|e| e.to_string())?;
        macro_rules! sym {
            ($name:ident, $ty:ty) => {
                let $name = *lib.get::<$ty>(concat!(stringify!($name), "\0").as_bytes()).map_err(|e| e.to_string())?;
            };
        }
        sym!(AAudio_createStreamBuilder, unsafe extern "C" fn(*mut *mut c_void) -> i32);
        sym!(AAudioStreamBuilder_delete, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStreamBuilder_setFormat, unsafe extern "C" fn(*mut c_void, i32));
        sym!(AAudioStreamBuilder_setChannelCount, unsafe extern "C" fn(*mut c_void, i32));
        sym!(AAudioStreamBuilder_setSampleRate, unsafe extern "C" fn(*mut c_void, i32));
        sym!(AAudioStreamBuilder_openStream, unsafe extern "C" fn(*mut c_void, *mut *mut c_void) -> i32);
        sym!(AAudioStream_requestStart, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_requestStop, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_close, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_write, unsafe extern "C" fn(*mut c_void, *const c_void, i32, i64) -> i32);
        sym!(AAudioStream_getBufferSizeInFrames, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_getSampleRate, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_getChannelCount, unsafe extern "C" fn(*mut c_void) -> i32);
        sym!(AAudioStream_getFormat, unsafe extern "C" fn(*mut c_void) -> i32);
        let mut builder = ptr::null_mut();
        if AAudio_createStreamBuilder(&mut builder) != 0 { return Err("Cannot create audio output".into()); }
        // Defaults: output, shared mode, media usage. Match decoded stereo PCM.
        AAudioStreamBuilder_setFormat(builder, 2); // PCM_FLOAT
        AAudioStreamBuilder_setChannelCount(builder, 2);
        AAudioStreamBuilder_setSampleRate(builder, rate as i32);
        let mut stream = ptr::null_mut();
        let opened = AAudioStreamBuilder_openStream(builder, &mut stream);
        AAudioStreamBuilder_delete(builder);
        if opened != 0 || stream.is_null() { return Err(format!("Cannot open audio output: {opened}")); }
        let result = (|| {
            if AAudioStream_getSampleRate(stream) != rate as i32
                || AAudioStream_getChannelCount(stream) != 2 || AAudioStream_getFormat(stream) != 2 {
                return Err("Audio output did not provide the requested stereo PCM format".into());
            }
            let started = AAudioStream_requestStart(stream);
            if started != 0 { return Err(format!("Cannot start audio output: {started}")); }
            let mut position = 0;
            while position < pcm.len() {
                let count = AAudioStream_write(stream, pcm[position..].as_ptr().cast(),
                    (pcm.len() - position).min(4096) as i32, 1_000_000_000);
                if count <= 0 { return Err(format!("Audio output write failed: {count}")); }
                position += count as usize;
            }
            let drain = AAudioStream_getBufferSizeInFrames(stream).max(0) as f64 / rate as f64;
            thread::sleep(Duration::from_secs_f64(drain + 0.05));
            Ok(())
        })();
        AAudioStream_requestStop(stream);
        AAudioStream_close(stream);
        result
    }
}
