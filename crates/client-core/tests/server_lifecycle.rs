//! Run explicitly after building the standalone server:
//! GRAFFITTY_TEST_SERVER=/absolute/server cargo test -p graffitty-client-core --test server_lifecycle -- --ignored
use graffitty_client_core::{
    client::Event,
    mirror::Mirror,
    server::{AttachOptions, Connection, Launch},
};
use graffitty_protocol::SessionId;
use serde_json::json;
use std::{
    path::PathBuf,
    time::{Duration, Instant},
};

#[test]
#[ignore = "requires GRAFFITTY_TEST_SERVER pointing to a built standalone server"]
fn real_server_owns_pty_across_attachment_and_isolated_owner_reaps_it() {
    let launch = Launch {
        binary: PathBuf::from(
            std::env::var_os("GRAFFITTY_TEST_SERVER").expect("Set an explicit test server binary"),
        ),
        shell: Some(
            if cfg!(windows) {
                "powershell.exe"
            } else {
                "/bin/sh"
            }
            .into(),
        ),
        working_directory: None,
    };
    let options = AttachOptions {
        workspace: "client-core-lifecycle".into(),
        ..Default::default()
    };
    let mut owner = Connection::isolated(&launch, &options).unwrap();
    assert!(owner.newly_started);
    let pid = owner.server_pid.unwrap();
    let descriptor = owner.descriptor.clone();
    let result = owner
        .client
        .request(
            json!({"type":"create","kind":"tab"}),
            Duration::from_secs(10),
            |_| {},
        )
        .unwrap();
    let session = SessionId(result["created"].as_u64().expect("Created terminal ID"));
    let mut attached = Connection::attach(&descriptor, &options).unwrap();
    assert!(!attached.newly_started);
    assert_eq!(attached.server_pid, Some(pid));
    attached.client.subscribe(&[session]).unwrap();
    let mut mirror = Mirror::new(80, 24, (12, 23), Default::default()).unwrap();
    let command: &[u8] = if cfg!(windows) {
        b"Write-Output ('CORE_' + 'LIFECYCLE_OK')\r"
    } else {
        b"printf '%s%s\\n' 'CORE_' 'LIFECYCLE_OK'\r"
    };
    owner.client.input(session, command).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        for event in attached.client.poll().unwrap() {
            if let Event::Scene {
                session: id,
                commit,
            } = event
            {
                if id == session {
                    mirror.apply_scene(commit).unwrap();
                }
            }
        }
        if mirror.text(true).unwrap().contains("CORE_LIFECYCLE_OK") {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "Real PTY output did not reach the mirror"
        );
        std::thread::sleep(Duration::from_millis(2));
    }
    drop(attached);
    let reattached = Connection::attach(&descriptor, &options).unwrap();
    assert_eq!(reattached.server_pid, Some(pid));
    drop(reattached);
    owner.stop_owned();
    owner.stop_owned();
    // The frontend may still hold the connection after its window closes.
    // Explicit cleanup must release the owned process without waiting for Drop.
    #[cfg(unix)]
    assert_eq!(unsafe { libc::kill(pid as i32, 0) }, -1);
    drop(owner);
    assert!(
        !descriptor.exists(),
        "Isolated descriptor directory must be removed"
    );
    #[cfg(unix)]
    {
        assert_eq!(
            unsafe { libc::kill(pid as i32, 0) },
            -1,
            "Owned server must be reaped"
        );
        assert_eq!(
            std::io::Error::last_os_error().raw_os_error(),
            Some(libc::ESRCH)
        );
    }
}
