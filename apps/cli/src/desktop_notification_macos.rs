#![allow(deprecated)]
use super::*;
use objc2::{
    AnyThread, DefinedClass, define_class, msg_send,
    rc::Retained,
    runtime::{AnyClass, AnyObject, ProtocolObject},
};
use objc2_foundation::{
    NSArray, NSDate, NSObject, NSObjectProtocol, NSRunLoop, NSString, NSUserNotification,
    NSUserNotificationAction, NSUserNotificationCenter, NSUserNotificationCenterDelegate,
};
use std::cell::RefCell;

#[link(name = "AppKit", kind = "framework")]
unsafe extern "C" {}
#[derive(Default)]
struct State {
    result: RefCell<Option<Value>>,
}
define_class!(
    #[unsafe(super(NSObject))]
    #[name = "GraffittyNotificationDelegate"]
    #[ivars = State]
    struct Delegate;
    unsafe impl NSObjectProtocol for Delegate {}
    unsafe impl NSUserNotificationCenterDelegate for Delegate {
        #[unsafe(method(userNotificationCenter:shouldPresentNotification:))]
        fn present(
            &self,
            _center: &NSUserNotificationCenter,
            _notification: &NSUserNotification,
        ) -> bool {
            true
        }
        #[unsafe(method(userNotificationCenter:didActivateNotification:))]
        fn activate(&self, _center: &NSUserNotificationCenter, notification: &NSUserNotification) {
            let button = notification
                .additionalActivationAction()
                .and_then(|a| a.identifier())
                .and_then(|s| s.to_string().parse::<u32>().ok())
                .unwrap_or(0);
            *self.ivars().result.borrow_mut() = Some(json!({"clicked":true,"button":button}));
        }
    }
);
pub fn deliver(r: Request, close: mpsc::Receiver<()>) -> Result<Value> {
    notify_rust::set_application("dev.graffitty.terminal")?;
    let delegate: Retained<Delegate> =
        unsafe { msg_send![super(Delegate::alloc().set_ivars(State::default())), init] };
    let center = NSUserNotificationCenter::defaultUserNotificationCenter();
    unsafe {
        center.setDelegate(Some(ProtocolObject::from_ref(&*delegate)));
    }
    let notification = NSUserNotification::new();
    notification.setIdentifier(Some(&NSString::from_str(&r.native_id)));
    notification.setTitle(Some(&NSString::from_str(&r.title)));
    notification.setInformativeText(Some(&NSString::from_str(&r.body)));
    if r.sound.is_empty() || r.sound == "system" {
        unsafe {
            notification.setSoundName(Some(objc2_foundation::NSUserNotificationDefaultSoundName));
        }
    } else if r.sound != "silent" {
        let sound = match r.sound.as_str() {
            "error" => "Basso",
            "warn" | "warning" => "Sosumi",
            "question" => "Ping",
            "info" => "Glass",
            name => name,
        };
        notification.setSoundName(Some(&NSString::from_str(sound)));
    }
    if !r.buttons.is_empty() {
        let actions: Vec<_> = r
            .buttons
            .iter()
            .enumerate()
            .map(|(i, label)| {
                NSUserNotificationAction::actionWithIdentifier_title(
                    Some(&NSString::from_str(&(i + 1).to_string())),
                    Some(&NSString::from_str(label)),
                )
            })
            .collect();
        notification.setAdditionalActions(Some(&NSArray::from_retained_slice(&actions)));
        notification.setHasActionButton(true);
        notification.setActionButtonTitle(&NSString::from_str("Actions"));
    }
    let mut named_image: Option<Retained<AnyObject>> = None;
    let candidates = if r.icon_names.is_empty() {
        vec![r.app_name.as_str()]
    } else {
        r.icon_names.iter().map(String::as_str).collect()
    };
    if let Some(class) = AnyClass::get(c"NSWorkspace") {
        unsafe {
            let workspace: *mut AnyObject = msg_send![class, sharedWorkspace];
            for name in candidates {
                if [
                    "error",
                    "warn",
                    "warning",
                    "info",
                    "question",
                    "help",
                    "file-manager",
                    "system-monitor",
                    "text-editor",
                ]
                .contains(&name)
                {
                    break;
                }
                if name.is_empty() {
                    continue;
                }
                let url: Option<Retained<AnyObject>> = msg_send![workspace, URLForApplicationWithBundleIdentifier: &*NSString::from_str(name)];
                if let Some(url) = url {
                    let path: Retained<NSString> = msg_send![&*url, path];
                    named_image = msg_send![workspace, iconForFile: &*path];
                    if named_image.is_some() {
                        break;
                    }
                }
            }
        }
    }
    if let Some(image) = named_image {
        unsafe {
            let _: () = msg_send![&*notification, setContentImage: &*image];
        }
    } else if !r.icon_path.is_empty() {
        if let Some(class) = AnyClass::get(c"NSImage") {
            unsafe {
                let image: *mut AnyObject = msg_send![class, alloc];
                let image: *mut AnyObject =
                    msg_send![image, initWithContentsOfFile: &*NSString::from_str(&r.icon_path)];
                if let Some(image) = Retained::from_raw(image) {
                    let _: () = msg_send![&*notification, setContentImage: &*image];
                }
            }
        }
    }
    center.deliverNotification(&notification);
    let start = Instant::now();
    let mut seen = false;
    loop {
        NSRunLoop::currentRunLoop().runUntilDate(&NSDate::dateWithTimeIntervalSinceNow(0.025));
        if let Some(result) = delegate.ivars().result.borrow_mut().take() {
            center.removeDeliveredNotification(&notification);
            return Ok(result);
        }
        let visible = center.deliveredNotifications().iter().any(|n| {
            n.identifier()
                .is_some_and(|id| id.to_string() == r.native_id)
        });
        if visible {
            seen = true;
        }
        if should_close(&close, start, r.timeout) || (seen && !visible) {
            center.removeDeliveredNotification(&notification);
            return Ok(json!({"clicked":false}));
        }
        if !seen && start.elapsed() > Duration::from_secs(10) {
            return Err(
                "macOS did not deliver the notification; check Graffitty notification permission"
                    .into(),
            );
        }
    }
}
