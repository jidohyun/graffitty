//! iOS permission/session lifetime on the existing capture worker, never the UI.
//!
//! The ownership and permission policy is plain Rust so it is unit-tested on the
//! host; only the thin AVAudioSession bridge needs an iOS target.
#![cfg_attr(not(target_os = "ios"), allow(dead_code))]
use crate::{Result, capture::Control};
use std::{
    sync::atomic::{AtomicBool, Ordering},
    thread,
    time::{Duration, Instant},
};

/// Longest wait for the user to answer the system consent prompt.
const PERMISSION_WAIT: Duration = Duration::from_secs(60);
/// A canceled recording may still be disposing its stream when the next one starts.
const HANDOFF_WAIT: Duration = Duration::from_secs(3);
const STEP: Duration = Duration::from_millis(20);

const DENIED: &str = "Allow microphone access, then tap Record again.";
const UNANSWERED: &str = "Microphone permission was not answered. Tap Record again.";
const BUSY: &str = "Microphone is already active";
const INTERRUPTED: &str =
    "Microphone was interrupted by a call or another app. Recording stopped. Review the transcript.";
const IN_USE: &str = "The microphone is in use by a call or another app. Try again when it is free.";
const SESSION_FAILED: &str = "Could not start the microphone audio session.";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Permission {
    Granted,
    Denied,
    Pending,
}

/// Exclusive right to the process-wide AVAudioSession; released on drop.
pub(crate) struct Claim(&'static AtomicBool);
impl Claim {
    /// Wait for a canceled predecessor to finish disposing its stream, but give up when
    /// this recording is itself canceled or released. `Ok(None)` means nothing to record.
    pub(crate) fn acquire(
        flag: &'static AtomicBool,
        control: &Control,
        wait: Duration,
        step: Duration,
    ) -> Result<Option<Self>> {
        let deadline = Instant::now() + wait;
        loop {
            if control.is_canceled() || control.is_stopping() {
                return Ok(None);
            }
            if flag
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .is_ok()
            {
                return Ok(Some(Self(flag)));
            }
            if Instant::now() >= deadline {
                return Err(BUSY.into());
            }
            thread::sleep(step);
        }
    }
}
impl Drop for Claim {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

/// `Ok(true)` once granted; `Ok(false)` when stopped or canceled while waiting.
pub(crate) fn await_permission(
    control: &Control,
    timeout: Duration,
    step: Duration,
    mut probe: impl FnMut() -> Permission,
) -> Result<bool> {
    let deadline = Instant::now() + timeout;
    loop {
        if control.is_canceled() || control.is_stopping() {
            return Ok(false);
        }
        match probe() {
            Permission::Granted => return Ok(true),
            Permission::Denied => return Err(DENIED.into()),
            Permission::Pending if Instant::now() >= deadline => return Err(UNANSWERED.into()),
            Permission::Pending => thread::sleep(step),
        }
    }
}

/// Map an AVAudioSession activation failure (an OSStatus four-character code) to a stable,
/// localizable message. The raw code is for diagnostics only, never UI text.
fn activation_error(code: i64) -> String {
    let four = |code: &[u8; 4]| i32::from_be_bytes(*code) as i64;
    // InsufficientPriority, CannotInterruptOthers, IsBusy, CannotStartRecording,
    // SiriIsRecording, ResourceNotAvailable.
    const BUSY_CODES: [&[u8; 4]; 6] = [b"!pri", b"!int", b"!act", b"!rec", b"siri", b"!res"];
    if BUSY_CODES.iter().any(|busy| four(busy) == code) {
        IN_USE.into()
    } else {
        SESSION_FAILED.into()
    }
}

#[cfg(target_os = "ios")]
pub use native::Session;

#[cfg(target_os = "ios")]
mod native {
    use super::*;
    use std::ffi::c_void;

    unsafe extern "C" {
        fn gft_ios_microphone_permission() -> i32;
        fn gft_ios_audio_begin(failure: *mut i64) -> *mut c_void;
        fn gft_ios_audio_interrupted(session: *mut c_void) -> i32;
        fn gft_ios_audio_end(session: *mut c_void);
    }
    static ACTIVE: AtomicBool = AtomicBool::new(false);

    fn permission() -> Permission {
        // SAFETY: no arguments; the adapter only reads state and schedules the prompt.
        match unsafe { gft_ios_microphone_permission() } {
            1 => Permission::Granted,
            -1 => Permission::Denied,
            _ => Permission::Pending,
        }
    }

    /// Owns one activated AVAudioSession handle. The raw pointer keeps this on the
    /// worker thread (`!Send`); it is valid from `begin` until `drop` consumes it.
    struct Audio(*mut c_void);
    impl Audio {
        fn begin() -> Result<Self> {
            let mut failure = 0i64;
            // SAFETY: `failure` outlives the call; a non-null result is an owned handle.
            let raw = unsafe { gft_ios_audio_begin(&mut failure) };
            if raw.is_null() {
                eprintln!("graffitty-dictation-audio: AVAudioSession activation failed (OSStatus {failure})");
                Err(activation_error(failure))
            } else {
                Ok(Self(raw))
            }
        }
    }
    impl Drop for Audio {
        fn drop(&mut self) {
            // SAFETY: the handle is consumed exactly once, after CPAL disposed the stream.
            unsafe { gft_ios_audio_end(self.0) };
        }
    }

    /// Declaration order is drop order: end the audio session, then release ownership,
    /// so the next recording never activates while this one is still tearing down.
    pub struct Session {
        audio: Audio,
        _claim: Claim,
    }
    impl Session {
        pub fn acquire(control: &Control) -> Result<Option<Self>> {
            let Some(claim) = Claim::acquire(&ACTIVE, control, HANDOFF_WAIT, STEP)? else {
                return Ok(None);
            };
            // The adapter schedules the consent prompt only when undetermined.
            if !await_permission(control, PERMISSION_WAIT, STEP, permission)? {
                return Ok(None);
            }
            Ok(Some(Self {
                audio: Audio::begin()?,
                _claim: claim,
            }))
        }

        /// Do not silently resume after a call and splice together missing speech.
        pub fn check_interruption(&self) -> Result<()> {
            // SAFETY: `audio.0` is live for the lifetime of `self`.
            if unsafe { gft_ios_audio_interrupted(self.audio.0) } != 0 {
                Err(INTERRUPTED.into())
            } else {
                Ok(())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;

    const SHORT: Duration = Duration::from_millis(1);

    #[test]
    fn restart_waits_for_the_canceled_predecessor_to_finish() {
        static FLAG: AtomicBool = AtomicBool::new(false);
        let control = Control::default();
        let first = Claim::acquire(&FLAG, &control, SHORT, SHORT).unwrap().unwrap();
        let releaser = thread::spawn(move || {
            thread::sleep(Duration::from_millis(40));
            drop(first);
        });
        let second = Claim::acquire(&FLAG, &control, Duration::from_secs(2), SHORT)
            .expect("restart must not fail while the old stream closes");
        releaser.join().unwrap();
        assert!(second.is_some() && FLAG.load(Ordering::Acquire));
    }

    #[test]
    fn live_owner_is_reported_busy_and_release_reopens_the_slot() {
        static FLAG: AtomicBool = AtomicBool::new(false);
        let control = Control::default();
        let owner = Claim::acquire(&FLAG, &control, SHORT, SHORT).unwrap().unwrap();
        let busy = Claim::acquire(&FLAG, &control, Duration::from_millis(10), SHORT);
        assert_eq!(busy.err().as_deref(), Some(BUSY));
        drop(owner);
        assert!(!FLAG.load(Ordering::Acquire));
        assert!(Claim::acquire(&FLAG, &control, SHORT, SHORT).unwrap().is_some());
    }

    #[test]
    fn stop_or_cancel_ends_the_handoff_wait_without_taking_the_slot() {
        static FLAG: AtomicBool = AtomicBool::new(true);
        for cancel in [false, true] {
            let control = Control::default();
            if cancel {
                control.cancel();
            } else {
                control.stop(1);
            }
            let started = Instant::now();
            assert!(Claim::acquire(&FLAG, &control, Duration::from_secs(5), SHORT).unwrap().is_none());
            assert!(started.elapsed() < Duration::from_secs(1));
            assert!(FLAG.load(Ordering::Acquire), "must not release another recording's slot");
        }
    }

    #[test]
    fn permission_prompt_resolves_to_granted_denied_unanswered_or_aborted() {
        let control = Control::default();
        let polls = Cell::new(0);
        let granted = await_permission(&control, Duration::from_secs(2), SHORT, || {
            polls.set(polls.get() + 1);
            if polls.get() < 4 { Permission::Pending } else { Permission::Granted }
        });
        assert_eq!((granted, polls.get()), (Ok(true), 4));
        let denied = await_permission(&control, Duration::from_secs(2), SHORT, || Permission::Denied);
        assert_eq!(denied.err().as_deref(), Some(DENIED));
        let unanswered = await_permission(&control, Duration::from_millis(5), SHORT, || Permission::Pending);
        assert_eq!(unanswered.err().as_deref(), Some(UNANSWERED));
        assert_ne!(UNANSWERED, "No audio arrived from the microphone. Check its permission and input device.");
    }

    #[test]
    fn release_during_the_prompt_records_nothing_and_never_probes_again() {
        for cancel in [false, true] {
            let control = Control::default();
            let probes = Cell::new(0);
            let result = await_permission(&control, Duration::from_secs(2), SHORT, || {
                probes.set(probes.get() + 1);
                if cancel { control.cancel() } else { control.stop(1) }
                Permission::Pending
            });
            assert_eq!((result, probes.get()), (Ok(false), 1));
        }
        // Even an already-granted permission does not start a session after release.
        let control = Control::default();
        control.stop(1);
        let result = await_permission(&control, Duration::from_secs(1), SHORT, || panic!("probed"));
        assert_eq!(result, Ok(false));
    }

    #[test]
    fn activation_failures_explain_a_busy_microphone() {
        for code in [b"!pri", b"!int", b"!act", b"!rec", b"siri", b"!res"] {
            assert_eq!(activation_error(i32::from_be_bytes(*code) as i64), IN_USE);
        }
        assert_eq!(activation_error(-50), SESSION_FAILED);
        assert!(!SESSION_FAILED.chars().any(|c| c.is_ascii_digit()));
        assert!(!INTERRUPTED.contains("permission"));
    }
}
