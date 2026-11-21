use graffitty_client_core::server::{AttachOptions, Connection, Launch};
use graffitty_workspace_core::{merge::TabPatch, state::{Edit, Snapshot}};
use serde_json::{Value, json};
use std::{path::PathBuf, time::Duration};

fn request(connection: &mut Connection, value: Value) -> Value {
    connection.client.request(value, Duration::from_secs(10), |_| {}).unwrap()
}
fn state(connection: &mut Connection) -> Snapshot {
    serde_json::from_value(request(connection, json!({"type":"workspace_get"}))["workspace_state"].clone()).unwrap()
}
fn edit(connection: &mut Connection, revision: u64, edit: Edit) -> Snapshot {
    serde_json::from_value(request(connection, json!({"type":"workspace_edit","expected_revision":revision,"edit":edit}))["workspace_state"].clone()).unwrap()
}

#[test]
#[ignore = "requires GRAFFITTY_TEST_SERVER; run by the full E2E runner"]
fn two_frontend_clients_share_layout_reconnect_and_server_undo() {
    let launch = Launch {
        binary: PathBuf::from(std::env::var_os("GRAFFITTY_TEST_SERVER").expect("Explicit test server binary")),
        shell: Some(if cfg!(windows) {"powershell.exe"} else {"/bin/sh"}.into()),
        working_directory: None,
    };
    let options = AttachOptions { workspace: "conformance".into(), ..Default::default() };
    let mut first = Connection::isolated(&launch, &options).unwrap();
    let mut second = Connection::attach(&first.descriptor, &options).unwrap();
    assert_eq!(first.server_pid, second.server_pid);
    let before = state(&mut first);
    let tab = before.active.unwrap();
    let id = before.layout.tabs[&tab].windows[0].key.strip_prefix('%').unwrap().parse::<u64>().unwrap();
    request(&mut first, json!({"type":"create","kind":"pane","session":id}));
    let before = state(&mut first);
    assert_eq!(state(&mut second), before);
    assert_eq!(before.layout.tabs[&tab].windows.len(), 2);
    let mut intended = before.layout.tabs[&tab].clone();
    intended.windows[0].rect[0] = 325.;
    let pending = TabPatch::between(&before.layout.tabs[&tab], &intended).unwrap();
    let mut concurrent = before.layout.tabs[&tab].clone();
    concurrent.windows[1].rect[1] = 450.;
    let latest = edit(&mut second, before.revision, Edit::Tab { tab, layout: concurrent, settings: None });
    assert!(first.client.request(json!({"type":"workspace_edit","expected_revision":before.revision,
        "edit":{"op":"tab","tab":tab,"layout":intended,"settings":null}}),Duration::from_secs(10), |_| {}).is_err());
    let rebased = pending.rebase(&latest.layout.tabs[&tab]).unwrap();
    let saved = edit(&mut first, latest.revision, Edit::Tab { tab, layout: rebased, settings: None });
    assert_eq!(saved.layout.tabs[&tab].windows[0].rect[0], 325.);
    assert_eq!(saved.layout.tabs[&tab].windows[1].rect[1], 450.);
    drop(second);
    let mut reconnected = Connection::attach(&first.descriptor, &options).unwrap();
    assert_eq!(state(&mut reconnected), saved);
    let undone = edit(&mut reconnected, saved.revision, Edit::Undo);
    assert_eq!(undone.layout.tabs[&tab], latest.layout.tabs[&tab]);
    assert_eq!(state(&mut first), undone);
}
