//! Recorded Neovim oracle. tests/copy-mode/neovim.json is tracked in DVC, not
//! Git: `dvc pull` fetches it; `mise run copy-mode:record` regenerates it.
use super::*;
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Deserialize)]
struct Corpus {
    neovim: String,
    commands: Vec<Command>,
    outcomes: Vec<Value>,
    buffers: Vec<Buffer>,
}

#[derive(Deserialize)]
struct Command {
    keys: String,
    copy: bool,
}

#[derive(Deserialize)]
struct Buffer {
    lines: Vec<String>,
    // Row, cell column, command index, outcome index.
    cases: Vec<[usize; 4]>,
}

fn inputs(mut keys: &str) -> Vec<Input> {
    let mut out = Vec::new();
    while let Some(c) = keys.chars().next() {
        if c == '<'
            && let Some(end) = keys.find('>')
        {
            let input = match &keys[1..end] {
                "Esc" => Some(Input::key(Key::Escape)),
                "CR" => Some(Input::key(Key::Enter)),
                "BS" => Some(Input::key(Key::Backspace)),
                "Tab" => Some(Input::key(Key::Tab)),
                "lt" => Some(Input::char('<')),
                name if name.starts_with("C-") && name.chars().count() == 3 => {
                    Some(Input::ctrl(name.chars().nth(2).unwrap()))
                }
                _ => None,
            };
            if let Some(input) = input {
                out.push(input);
                keys = &keys[end + 1..];
                continue;
            }
        }
        out.push(Input::char(c));
        keys = &keys[c.len_utf8()..];
    }
    out
}

#[test]
fn recorded_neovim_parity() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/copy-mode/neovim.json");
    let Ok(text) = std::fs::read_to_string(path) else {
        eprintln!("skipping recorded_neovim_parity: {path} is missing; fetch it with `dvc pull` or regenerate it with `mise run copy-mode:record`");
        return;
    };
    let corpus: Corpus = serde_json::from_str(&text).unwrap();
    let commands: Vec<_> = corpus.commands.iter().map(|c| inputs(&c.keys)).collect();
    let mut failures = Vec::new();
    let mut total = 0;
    for buffer in &corpus.buffers {
        let mut vt = tests::terminal(200, buffer.lines.len() as u16, &buffer.lines.join("\r\n"));
        for &[row, col, cmd, expected] in &buffer.cases {
            let mut mode = CopyMode::new(&mut vt, (col as u16, row as u16));
            let mut copied = None;
            for &input in &commands[cmd] {
                match mode.key(&mut vt, input) {
                    Effect::Copy { text, exit } => {
                        copied = Some(text);
                        if exit {
                            break;
                        }
                    }
                    Effect::Exit => break,
                    _ => {}
                }
            }
            let actual = if corpus.commands[cmd].copy {
                json!(copied.filter(|s| !s.is_empty()))
            } else {
                json!([mode.cursor.y, mode.cursor.x])
            };
            if actual != corpus.outcomes[expected] {
                failures.push(format!(
                    "{} at ({row}, {col}) in {:?}: {actual} != {}",
                    corpus.commands[cmd].keys, buffer.lines, corpus.outcomes[expected]
                ));
            }
            total += 1;
        }
    }
    assert!(
        failures.is_empty(),
        "{}/{} cases differ from {}:\n{}",
        failures.len(),
        total,
        corpus.neovim,
        failures
            .iter()
            .take(25)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n")
    );
}
