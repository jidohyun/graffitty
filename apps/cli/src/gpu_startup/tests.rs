use super::*;

fn run(
    runtime: &Path,
    root: &Path,
    state: &Path,
    args: &[OsString],
    chain: &[&str],
    fingerprint: &str,
) -> io::Result<ExitStatus> {
    supervise(
        runtime,
        root,
        state,
        args,
        &Policy {
            chain,
            fingerprint,
            disabled: &[],
            rules: &[],
        },
        watchdog::BASE_TIMEOUT,
    )
}

#[test]
fn cooldown_reprobes_and_crashes_decay_by_mode() {
    let mut h = History::reset("gpu", &[]);
    h.selected = "opengl3".into();
    h.reprobe = 700;
    assert_eq!(h.order(WINDOWS, &[], 699), ["opengl3", "d3d12", "vulkan"]);
    assert_eq!(h.order(WINDOWS, &["d3d12"], 700), ["vulkan", "opengl3"]);
    for (at, cause) in [
        (500, Cause::Timeout),
        (501, Cause::InitDialog),
        (502, Cause::DeviceLost),
        (503, Cause::EarlyExit),
    ] {
        h.record(
            "d3d12",
            Failure {
                at,
                phase: "engine".into(),
                cause,
                status: None,
            },
        );
    }
    assert_eq!(h.budget.count, 3);
    assert!(!h.order(WINDOWS, &[], 801).contains(&"d3d12"));
    assert!(h.order(WINDOWS, &[], 802).contains(&"d3d12"));
    h.record(
        "vulkan",
        Failure {
            at: 803,
            phase: "running".into(),
            cause: Cause::DeviceLost,
            status: None,
        },
    );
    assert_eq!(h.budget.count, 1);
}

#[test]
fn override_preserves_user_settings_and_removes_only_its_block() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("override.cfg");
    let original = "[display]\nwindow/size/viewport_width=1000\n";
    fs::write(&path, original).unwrap();
    for mode in ["vulkan", "opengl3", "opengl3"] {
        save_override(dir.path(), mode, true).unwrap();
        let text = fs::read_to_string(&path).unwrap();
        assert!(text.starts_with(original));
        assert_eq!(text.matches(BEGIN).count(), 1);
        assert!(text.contains(if mode == "vulkan" {
            "driver.windows=\"vulkan\""
        } else {
            "gl_compatibility"
        }));
    }
    // A Windows editor can normalize line endings in the managed section.
    let edited = fs::read_to_string(&path).unwrap().replace('\n', "\r\n");
    fs::write(&path, edited).unwrap();
    save_override(dir.path(), "d3d12", true).unwrap();
    assert_eq!(
        fs::read_to_string(path).unwrap(),
        original.replace('\n', "\r\n")
    );
}

#[cfg(unix)]
#[test]
fn supervised_process_recovers_and_next_launch_uses_the_healthy_mode() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("engine");
    fs::write(
        &path,
        r#"#!/bin/sh
set -eu
cd "$(dirname "$0")"
echo "$GRAFFITTY_GPU_MODE" >> runs
test "$5" = "--" && test "$6" = "a b" || exit 2
test "$GRAFFITTY_GPU_MODE" != vulkan || exit 42
echo '{"renderer":"opengl3","adapter":"mock","api":"3.3","presentation":{"display_server":"X11","transparency_at_startup":true,"godot_transparency_after_draw":false,"transparency_after_draw":true}}' > "$GRAFFITTY_GPU_ATTEMPT/adapter"
touch "$GRAFFITTY_GPU_ATTEMPT/healthy"
"#,
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    for _ in 0..2 {
        assert!(
            run(
                &path,
                dir.path(),
                dir.path(),
                &["--".into(), "a b".into()],
                LINUX,
                "app/driver"
            )
            .unwrap()
            .success()
        );
    }
    assert_eq!(
        fs::read_to_string(dir.path().join("runs")).unwrap(),
        "vulkan\nopengl3\nopengl3\n"
    );
    let saved: History =
        serde_json::from_slice(&fs::read(dir.path().join("history.json")).unwrap()).unwrap();
    assert_eq!(saved.failures["vulkan"].cause, Cause::EarlyExit);
    assert_eq!(saved.budget.count, 0);
    assert_eq!(saved.selected, "opengl3");
    let display = &saved.adapters["opengl3"].presentation;
    assert_eq!(display.display_server, "X11");
    assert_eq!(display.godot_transparency_after_draw, Some(false));
    assert_eq!(display.transparency_after_draw, Some(true));
}

#[cfg(unix)]
#[test]
#[ignore = "requires a window system and GRAFFITTY_TEST_GODOT"]
fn real_godot_draws_after_first_renderer_fails() {
    use std::os::unix::fs::PermissionsExt;
    let godot = std::env::var_os("GRAFFITTY_TEST_GODOT").expect("Set the Godot executable");
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let state = root.join("graffitty/gpu");
    let project = root.join("project");
    fs::create_dir_all(&state).unwrap();
    fs::create_dir_all(project.join("graffitty")).unwrap();
    for (name, source) in [
        (
            "graffitty/GpuStartup.gd",
            include_str!("../../../../frontends/godot/project/graffitty/GpuStartup.gd"),
        ),
        (
            "graffitty/window_transparency.gd",
            include_str!("../../../../frontends/godot/project/graffitty/window_transparency.gd"),
        ),
        (
            "graffitty/paths.gd",
            include_str!("../../../../frontends/godot/project/graffitty/paths.gd"),
        ),
        (
            "project.godot",
            "config_version=5\n[application]\nrun/main_scene=\"res://screen.tscn\"\nrun/max_fps=15\n[autoload]\nGpuStartup=\"*res://graffitty/GpuStartup.gd\"\n",
        ),
        (
            "screen.tscn",
            "[gd_scene format=3]\n[node name=\"Surface\" type=\"ColorRect\"]\noffset_right=64.0\noffset_bottom=64.0\n",
        ),
    ] {
        fs::write(project.join(name), source).unwrap();
    }
    let engine = root.join("engine");
    fs::write(
        &engine,
        r#"#!/bin/sh
set -eu
cd "$(dirname "$0")"
echo "$GRAFFITTY_GPU_MODE" >> runs
test "$GRAFFITTY_GPU_MODE" != vulkan || exit 42
export XDG_STATE_HOME="$PWD"
exec "$GRAFFITTY_TEST_GODOT" "$@"
"#,
    )
    .unwrap();
    fs::set_permissions(&engine, fs::Permissions::from_mode(0o755)).unwrap();
    let args = [
        "--path".into(),
        project.into_os_string(),
        "--quit-after".into(),
        "65".into(),
        "--audio-driver".into(),
        "Dummy".into(),
    ];
    for _ in 0..2 {
        assert!(
            run(&engine, root, &state, &args, LINUX, "integration")
                .unwrap()
                .success()
        );
    }
    assert_eq!(
        fs::read_to_string(root.join("runs")).unwrap(),
        "vulkan\nopengl3\nopengl3\n"
    );
    let history: History =
        serde_json::from_slice(&fs::read(state.join("history.json")).unwrap()).unwrap();
    let observed = serde_json::to_value(&history.adapters["opengl3"]).unwrap();
    assert_eq!(observed["renderer"], "opengl3");
    assert!(!observed["adapter"].as_str().unwrap().is_empty());
    assert!(observed["presentation"]["transparency_after_draw"].is_boolean());
    println!(
        "{} rendered healthy frames: {observed}",
        Path::new(&godot).display()
    );
}

#[cfg(unix)]
#[test]
fn pre_autoload_exits_exhaust_the_chain_but_orderly_close_does_not_retry() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let engine = dir.path().join("engine");
    fs::write(
        &engine,
        r#"#!/bin/sh
set -eu
cd "$(dirname "$0")"
echo "$GRAFFITTY_GPU_MODE" >> runs
if test -f close; then touch "$GRAFFITTY_GPU_ATTEMPT/closed"; fi
exit 0
"#,
    )
    .unwrap();
    fs::set_permissions(&engine, fs::Permissions::from_mode(0o755)).unwrap();
    for _ in 0..3 {
        assert!(run(&engine, dir.path(), dir.path(), &[], LINUX, "one").is_err());
    }
    let runs = dir.path().join("runs");
    assert_eq!(
        fs::read_to_string(&runs).unwrap(),
        "vulkan\nopengl3\nsoftware\n".repeat(3)
    );
    fs::write(dir.path().join("close"), "").unwrap();
    assert!(
        run(&engine, dir.path(), dir.path(), &[], LINUX, "two")
            .unwrap()
            .success()
    );
    assert_eq!(fs::read_to_string(runs).unwrap().lines().count(), 10);
}

#[cfg(unix)]
#[test]
fn software_selection_survives_relaunch_and_adapter_change_retests_vulkan() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("engine");
    fs::write(
        &path,
        r#"#!/bin/sh
set -eu
cd "$(dirname "$0")"
echo "$GRAFFITTY_GPU_MODE" >> runs
if test -f upgraded; then
    if test "$GRAFFITTY_GPU_MODE" = software; then
        test -n "$GRAFFITTY_GPU_EXPECTED" || exit 3
        touch "$GRAFFITTY_GPU_ATTEMPT/changed"
        exit 75
    fi
    driver=vulkan
else
    test "$GRAFFITTY_GPU_MODE" = software || exit 42
    test "$LIBGL_ALWAYS_SOFTWARE" = 1 || exit 4
    driver=opengl3
fi
printf '{"renderer":"%s","adapter":"test","api":"1","presentation":{"display_server":"X11","transparency_at_startup":true,"godot_transparency_after_draw":false,"transparency_after_draw":true}}' "$driver" > "$GRAFFITTY_GPU_ATTEMPT/adapter"
touch "$GRAFFITTY_GPU_ATTEMPT/healthy"
"#,
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
    let run = || run(&path, dir.path(), dir.path(), &[], LINUX, "app").unwrap();
    assert!(run().success());
    assert!(run().success());
    fs::write(dir.path().join("upgraded"), "").unwrap();
    assert!(run().success());
    assert_eq!(
        fs::read_to_string(dir.path().join("runs")).unwrap(),
        "vulkan\nopengl3\nsoftware\nsoftware\nsoftware\nvulkan\n"
    );
    assert!(
        fs::read_to_string(dir.path().join("override.cfg"))
            .unwrap()
            .is_empty()
    );
}

#[cfg(unix)]
#[test]
fn stalled_engine_is_reaped_and_angle_fault_after_health_is_recorded() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let engine = dir.path().join("engine");
    fs::write(
        &engine,
        r#"#!/bin/sh
set -eu
cd "$(dirname "$0")"
echo "$GRAFFITTY_GPU_MODE" >> runs
if test "$GRAFFITTY_GPU_MODE" = d3d12; then exec sleep 60; fi
echo '{"renderer":"opengl3_angle","adapter":"fixture","api":"3","presentation":{"display_server":"X11","transparency_at_startup":true,"godot_transparency_after_draw":false,"transparency_after_draw":true}}' > "$GRAFFITTY_GPU_ATTEMPT/adapter"
touch "$GRAFFITTY_GPU_ATTEMPT/healthy"
while ! test -f "$GRAFFITTY_GPU_ATTEMPT/accepted"; do sleep 0.03; done
cat "$GRAFFITTY_GPU_ATTEMPT/accepted" >> notices
touch "$GRAFFITTY_GPU_ATTEMPT/device-lost"
exit 77
"#,
    )
    .unwrap();
    fs::set_permissions(&engine, fs::Permissions::from_mode(0o755)).unwrap();
    let policy = Policy {
        chain: WINDOWS,
        fingerprint: "fixture",
        disabled: &[],
        rules: &[],
    };
    for _ in 0..2 {
        assert_eq!(
            supervise(
                &engine,
                dir.path(),
                dir.path(),
                &[],
                &policy,
                Duration::from_millis(250)
            )
            .unwrap()
            .code(),
            Some(77)
        );
    }
    let h: History =
        serde_json::from_slice(&fs::read(dir.path().join("history.json")).unwrap()).unwrap();
    assert_eq!(h.failures["d3d12"].cause, Cause::Timeout);
    assert_eq!(h.failures["opengl3"].phase, "running");
    assert_eq!(h.failures["opengl3"].cause, Cause::DeviceLost);
    assert_eq!(h.adapters["opengl3"].identity.renderer, "opengl3_angle");
    assert_eq!(
        fs::read_to_string(dir.path().join("runs")).unwrap(),
        "d3d12\nvulkan\nopengl3\n"
    );
    assert_eq!(
        fs::read_to_string(dir.path().join("notices")).unwrap(),
        "10"
    );
}

#[cfg(unix)]
#[test]
fn concurrent_healthy_children_share_one_fallback_notice() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    let engine = root.join("engine");
    fs::write(
        &engine,
        r#"#!/bin/sh
set -eu
cd "$(dirname "$0")"
touch "started-$$"
while test "$(ls started-* | wc -l)" -lt 2; do sleep 0.03; done
touch "$GRAFFITTY_GPU_ATTEMPT/healthy"
while ! test -f "$GRAFFITTY_GPU_ATTEMPT/accepted"; do sleep 0.03; done
cat "$GRAFFITTY_GPU_ATTEMPT/accepted" > "notice-$$"
"#,
    )
    .unwrap();
    fs::set_permissions(&engine, fs::Permissions::from_mode(0o755)).unwrap();
    let policy = Policy {
        chain: WINDOWS,
        fingerprint: "gpu",
        disabled: &["d3d12"],
        rules: &[1],
    };
    std::thread::scope(|scope| {
        let launch = || {
            supervise(&engine, root, root, &[], &policy, Duration::from_secs(3))
                .unwrap()
                .success()
        };
        let first = scope.spawn(launch);
        assert!(launch());
        assert!(first.join().unwrap());
    });
    let mut notices: Vec<_> = fs::read_dir(root)
        .unwrap()
        .flatten()
        .filter(|f| f.file_name().to_string_lossy().starts_with("notice-"))
        .map(|f| fs::read_to_string(f.path()).unwrap())
        .collect();
    notices.sort();
    assert_eq!(notices, ["0", "1"]);
}
