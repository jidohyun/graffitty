//! Diagnose named host sources without printing secret values or contacting consumers.
fn main() -> std::process::ExitCode {
    let mut failed = false;
    for name in std::env::args().skip(1) {
        match graffitty_secrets::lookup("", Some(&name)) {
            Ok(Some(_)) => println!("{name}: available"),
            Ok(None) => {
                eprintln!("{name}: unavailable");
                failed = true;
            }
            Err(error) => {
                eprintln!("{error}");
                failed = true;
            }
        }
    }
    if failed {
        std::process::ExitCode::FAILURE
    } else {
        std::process::ExitCode::SUCCESS
    }
}
