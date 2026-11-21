#[path = "../../tools/rust_build_info.rs"]
mod build_info;

fn main() {
    build_info::emit();
}
