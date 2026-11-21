use super::*;
fn resolver(text: &str) -> (tempfile::TempDir, Resolver) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("secrets.toml");
    std::fs::write(&path, text).unwrap();
    let resolver = Resolver::load(&path, true).unwrap();
    (dir, resolver)
}
#[test]
fn rejects_ambiguous_obsolete_and_invalid_sources_without_echoing_content() {
    for text in [
        "private_invalid = 'do-not-echo'",
        "[secrets.a]\nenv_var='KEY'\ncommand=['echo']",
        "[secrets.a]\ncommand=[]",
        "[secrets.a]\ncommand=['./untrusted']",
        "[secrets.a]\ncommand=['helper']\ncwd='relative'",
        "[secrets.a]\ncommand=['helper']\ntimeout_seconds=0",
        "[secrets.a]\nenv_var='KEY'\nenv={ OTHER='literal' }",
        "[defaults]\nKEY='missing'",
        "[secrets.a]\ncredential='work'",
    ] {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("secrets.toml");
        std::fs::write(&path, text).unwrap();
        let error = Resolver::load(&path, true).err().unwrap();
        assert!(!error.contains("do-not-echo"));
    }
}
#[test]
fn absent_default_file_is_optional_but_explicit_file_is_required() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("missing");
    assert!(Resolver::load(&path, false).is_ok());
    assert!(Resolver::load(&path, true).is_err());
}
#[cfg(unix)]
#[test]
fn command_arguments_environment_directory_and_cache_are_isolated() {
    let (dir, mut resolver) = resolver(
        r#"
[defaults]
TEST_TOKEN = "test"
[secrets.test]
command = ["/bin/sh", "-c", 'test "$#" = 1 && test "$1" = "\$(echo injected)" || exit 2; printf "called\n" >> calls; printf "  %s\n\n" "$GFT_TEST_SECRET_VALUE"', "helper", "$(echo injected)"]
env = { GFT_TEST_SECRET_VALUE = "synthetic" }
"#,
    );
    assert_eq!(resolver.resolve("test").unwrap(), "  synthetic\n");
    assert_eq!(resolver.resolve("test").unwrap(), "  synthetic\n");
    assert_eq!(
        std::fs::read_to_string(dir.path().join("calls")).unwrap(),
        "called\n"
    );
    assert!(std::env::var("GFT_TEST_SECRET_VALUE").is_err());
    resolver.cache.get_mut("test").unwrap().0 = Instant::now() - Duration::from_secs(301);
    resolver.resolve("test").unwrap();
    assert_eq!(
        std::fs::read_to_string(dir.path().join("calls")).unwrap(),
        "called\ncalled\n"
    );
}
#[cfg(unix)]
#[test]
fn no_cache_refreshes_and_failed_helpers_do_not_leak_or_poison_cache() {
    let (dir, mut resolver) = resolver(
        r#"
[secrets.test]
command = ["/bin/sh", "-c", 'if test -f fail; then echo private-detail >&2; echo partial-secret; exit 1; fi; cat value']
cache_seconds = 0
"#,
    );
    std::fs::write(dir.path().join("fail"), "").unwrap();
    let error = resolver.resolve("test").unwrap_err();
    assert!(!error.contains("private-detail") && !error.contains("partial-secret"));
    std::fs::remove_file(dir.path().join("fail")).unwrap();
    std::fs::write(dir.path().join("value"), "first\r\n").unwrap();
    assert_eq!(resolver.resolve("test").unwrap(), "first");
    std::fs::write(dir.path().join("value"), "second").unwrap();
    assert_eq!(resolver.resolve("test").unwrap(), "second");
}
#[cfg(unix)]
#[test]
fn kills_hung_descendants_and_bounds_output() {
    let (dir, mut resolver) = resolver(
        r#"
[secrets.hung]
command = ["/bin/sh", "-c", '(sleep 2; echo survived > survived) & wait']
timeout_seconds = 1
[secrets.huge]
command = ["/bin/sh", "-c", 'yes secret']
timeout_seconds = 1
"#,
    );
    let start = Instant::now();
    assert!(resolver.resolve("hung").is_err());
    assert!(resolver.resolve("huge").is_err());
    assert!(start.elapsed() < Duration::from_secs(2));
    std::thread::sleep(Duration::from_millis(1200));
    assert!(!dir.path().join("survived").exists());
}
