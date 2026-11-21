//! PTY output wakes the session actor; it is never gated by a rendering timer.
use std::sync::OnceLock;
#[cfg(unix)]
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
};
static WAKE: OnceLock<Wake> = OnceLock::new();
struct Wake {
    #[cfg(unix)]
    reader: UnixStream,
    #[cfg(unix)]
    writer: UnixStream,
    #[cfg(windows)]
    thread: std::thread::Thread,
}
pub fn init() -> std::io::Result<()> {
    #[cfg(unix)]
    {
        let (reader, writer) = UnixStream::pair()?;
        reader.set_nonblocking(true)?;
        writer.set_nonblocking(true)?;
        let _ = WAKE.set(Wake { reader, writer });
    }
    #[cfg(windows)]
    let _ = WAKE.set(Wake {
        thread: std::thread::current(),
    });
    Ok(())
}
pub fn notify() {
    if let Some(wake) = WAKE.get() {
        #[cfg(unix)]
        {
            let mut stream = &wake.writer;
            let _ = stream.write(&[1]);
        }
        #[cfg(windows)]
        wake.thread.unpark();
    }
}
#[cfg(unix)]
pub fn wait(mut descriptors: Vec<libc::pollfd>, timeout_ms: i32) {
    use std::os::fd::AsRawFd;
    let Some(wake) = WAKE.get() else {
        return;
    };
    descriptors.push(libc::pollfd {
        fd: wake.reader.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    });
    unsafe {
        libc::poll(
            descriptors.as_mut_ptr(),
            descriptors.len() as libc::nfds_t,
            timeout_ms,
        );
    }
    let mut stream = &wake.reader;
    let mut bytes = [0; 1024];
    while stream.read(&mut bytes).is_ok_and(|n| n > 0) {}
}
/// Windows rounds this process's timed waits up to its own timer resolution,
/// 15.6 ms unless the process asks for less.
///
/// The loop's 1 ms wait and the encoder's short idle waits then each added
/// most of a frame to every video round trip.
///
/// Ask for 1 ms only while a client streams or presents shared GPU frames, as
/// media players do; an idle server keeps the default resolution and its
/// power use.
#[cfg(windows)]
pub fn precise_timers(active: bool) {
    use std::sync::atomic::{AtomicBool, Ordering};
    #[link(name = "winmm")]
    unsafe extern "system" {
        fn timeBeginPeriod(period: u32) -> u32;
        fn timeEndPeriod(period: u32) -> u32;
    }
    static ACTIVE: AtomicBool = AtomicBool::new(false);
    if ACTIVE.swap(active, Ordering::Relaxed) != active {
        unsafe {
            if active {
                timeBeginPeriod(1);
            } else {
                timeEndPeriod(1);
            }
        }
    }
}
