use super::*;
use windows::{
    Data::Xml::Dom::XmlDocument,
    Foundation::TypedEventHandler,
    UI::Notifications::{
        NotificationSetting, ToastActivatedEventArgs, ToastDismissalReason,
        ToastDismissedEventArgs, ToastNotification, ToastNotificationManager,
    },
    core::HSTRING,
};
const APP: &str = "dev.graffitty.terminal";
const GROUP: &str = "graffitty";
pub fn deliver(r: Request, close: mpsc::Receiver<()>) -> Result<Value> {
    let status = std::process::Command::new("reg.exe")
        .args([
            "add",
            r"HKCU\Software\Classes\AppUserModelId\dev.graffitty.terminal",
            "/v",
            "DisplayName",
            "/t",
            "REG_SZ",
            "/d",
            "Graffitty",
            "/f",
        ])
        .stdout(std::process::Stdio::null())
        .status()?;
    if !status.success() {
        return Err("Cannot register Graffitty notification identity".into());
    }
    let buttons: String = r
        .buttons
        .iter()
        .take(5)
        .enumerate()
        .map(|(i, b)| format!("<action content=\"{}\" arguments=\"{}\"/>", xml(b), i + 1))
        .collect();
    let sound = if r.sound == "silent" {
        "<audio silent=\"true\"/>".into()
    } else {
        let name = match r.sound.as_str() {
            "error" | "warn" | "warning" => "IM",
            "question" => "Reminder",
            _ => "Default",
        };
        format!("<audio src=\"ms-winsoundevent:Notification.{name}\"/>")
    };
    let icon = if r.icon_path.is_empty() {
        String::new()
    } else {
        format!(
            "<image placement=\"appLogoOverride\" src=\"file:///{}\"/>",
            xml(&r.icon_path.replace('\\', "/"))
        )
    };
    let xml_doc = XmlDocument::new()?;
    xml_doc.LoadXml(&HSTRING::from(format!("<toast duration=\"long\" scenario=\"{}\"><visual><binding template=\"ToastGeneric\"><text>{}</text><text>{}</text>{icon}</binding></visual><actions>{buttons}</actions>{sound}</toast>",if r.urgency==2 {"reminder"} else {"default"},xml(&r.title),xml(&r.body))))?;
    let toast = ToastNotification::CreateToastNotification(&xml_doc)?;
    let tag: String = r.native_id.chars().rev().take(16).collect();
    toast.SetTag(&HSTRING::from(&tag))?;
    toast.SetGroup(&HSTRING::from(GROUP))?;
    let (tx, rx) = mpsc::channel();
    let activated = tx.clone();
    toast.Activated(&TypedEventHandler::new(
        move |_, args: windows::core::Ref<windows::core::IInspectable>| {
            use windows::core::Interface;
            let button = args
                .as_ref()
                .and_then(|a| a.cast::<ToastActivatedEventArgs>().ok())
                .and_then(|a| a.Arguments().ok())
                .and_then(|s| s.to_string().parse::<u32>().ok())
                .unwrap_or(0);
            let _ = activated.send(json!({"clicked":true,"button":button}));
            Ok(())
        },
    ))?;
    let dismissed = tx.clone();
    toast.Dismissed(&TypedEventHandler::new(
        move |_, args: windows::core::Ref<ToastDismissedEventArgs>| {
            if args.as_ref().is_some_and(|a| {
                a.Reason()
                    .is_ok_and(|reason| reason != ToastDismissalReason::TimedOut)
            }) {
                let _ = dismissed.send(json!({"clicked":false}));
            }
            Ok(())
        },
    ))?;
    toast.Failed(&TypedEventHandler::new(move |_, _| {
        let _ = tx.send(json!({"error":"Windows could not display the notification"}));
        Ok(())
    }))?;
    let notifier = ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(APP))
        .map_err(|e| format!("Create Windows toast notifier: {e}"))?;
    // Windows creates the per-app notification record on the first Show.
    // Reading Setting immediately after registering a new unpackaged identity
    // can fail with E_ELEMENTNOTFOUND. Show still honors the OS notification policy.
    notifier.Show(&toast).map_err(|e| format!("Show Windows toast: {e}"))?;
    if notifier.Setting().map_err(|e| format!("Read Windows notification setting: {e}"))? != NotificationSetting::Enabled {
        return Err("Windows notifications are disabled for Graffitty".into());
    }
    let start = Instant::now();
    let history = ToastNotificationManager::History().map_err(|e| format!("Open Windows toast history: {e}"))?;
    let mut seen = false;
    let mut checked = Instant::now();
    loop {
        if let Ok(result) = rx.try_recv() {
            history.RemoveGroupedTagWithId(
                &HSTRING::from(&tag),
                &HSTRING::from(GROUP),
                &HSTRING::from(APP),
            ).map_err(|e| format!("Remove completed Windows toast: {e}"))?;
            return Ok(result);
        }
        if checked.elapsed() >= Duration::from_millis(250) {
            checked = Instant::now();
            let visible = history
                .GetHistoryWithId(&HSTRING::from(APP)).map_err(|e| format!("Read Windows toast history: {e}"))?
                .into_iter()
                .any(|n| n.Tag().is_ok_and(|t| t.to_string() == tag));
            if seen && !visible {
                return Ok(json!({"clicked":false}));
            }
            seen |= visible;
        }
        if should_close(&close, start, r.timeout) {
            notifier.Hide(&toast).map_err(|e| format!("Hide Windows toast: {e}"))?;
            history.RemoveGroupedTagWithId(
                &HSTRING::from(&tag),
                &HSTRING::from(GROUP),
                &HSTRING::from(APP),
            ).map_err(|e| format!("Remove closed Windows toast: {e}"))?;
            return Ok(json!({"clicked":false}));
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}
