//! Line protocol for driving the production queue from the real-zsh PTY test.
#[path = "../../frontends/godot/extension/src/input_delivery.rs"]
mod input_delivery;
use std::io::{self, BufRead, Write};
use std::time::Instant;
fn main() {
    let mut queue = input_delivery::InputDelivery::default();
    for line in io::stdin().lock().lines() {
        let line = line.unwrap();
        let (op, hex) = line.split_once(' ').unwrap_or((&line, ""));
        let data: Vec<u8> = hex.as_bytes().chunks_exact(2)
            .map(|p| u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap()).collect();
        match op {
            "commit" => queue.push(&data, true),
            "key" => queue.push(&data, false),
            "output" => queue.output_received(),
            "take" => {
                for byte in queue.take(Instant::now()) { print!("{byte:02x}"); }
            }
            _ => panic!("Unknown command"),
        }
        println!();
        io::stdout().flush().unwrap();
    }
}
