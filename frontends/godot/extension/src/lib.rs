mod scene;
mod remote_client;
mod font_cache;
mod workspace_layout;
mod agent_socket;
mod session_transport;
mod session_client;
mod terminal_scene;
mod terminal_snapshot;
use graffitty_terminal_core::binding_core;
mod bindings;
#[cfg(any(target_os = "macos", target_os = "linux", windows))]
mod chromium_gpu;
mod chromium_video;
mod client_config;
mod clipboard;
mod file_upload;
use graffitty_terminal_core::clipboard_core;
#[cfg(target_os = "macos")]
mod clipboard_macos;
#[cfg(windows)]
#[path = "../../../../crates/platform/src/clipboard_windows.rs"]
mod clipboard_windows;
mod desktop_blur;
mod dictation_audio;
mod client_dictation;
mod window_frame;
#[cfg(target_os = "linux")]
mod window_frame_x11;
mod font;
mod font_assets;
mod fuzzy_ranker;
use graffitty_terminal_core::inline_images;
mod input;
use graffitty_terminal_core::key_encoding;
mod mod_view;
mod profile;
mod movie_writer;
use graffitty_terminal_core::navigation;
mod options;
mod plugin;
use graffitty_terminal_core::progress;
use graffitty_terminal_core::protocol;
mod pty;
mod input_delivery;
use graffitty_terminal_core::quick_select;
mod resource_monitor;
mod remote_auth;
mod video_datagram;
mod run;
use graffitty_terminal_core::selection;
use graffitty_scene_core::scroll;
mod sprite;
mod sync;
mod terminal;
mod elastic_gesture;
mod elastic_scroller;
mod text_words;
use graffitty_terminal_core::terminal_text;
mod theme;
#[cfg(target_os = "macos")]
mod trackpad;
mod touchpad_phases;
#[cfg(target_os = "linux")]
mod touchpad_wayland;
#[cfg(windows)]
mod touchpad_windows;

use godot::prelude::*;

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn graffitty_install_ime_shim();
    fn graffitty_set_terminal_key_focus(window: *mut std::ffi::c_void, owner: u64, active: bool);
    fn graffitty_restore_sigint();
    fn graffitty_install_window_frame();
    fn graffitty_install_folder_services();
}

#[cfg(target_os = "macos")]
pub(crate) fn install_ime_shim() {
    unsafe { trackpad::graffitty_install_trackpad() };
    // Temporary opt-out for testing the upstream Godot IME key-event fix.
    if std::env::var("GRAFFITTY_DISABLE_IME_SHIM").as_deref() == Ok("1") {
        return;
    }
    // The shim is version/class gated and becomes a no-op on unsupported Godot
    // builds. It must be installed after AppKit has registered the Godot view.
    unsafe { graffitty_install_ime_shim() };
}

#[cfg(not(target_os = "macos"))]
pub(crate) fn install_ime_shim() {}

pub(crate) fn set_terminal_key_focus(window_id: i32, owner: u64, active: bool) {
    #[cfg(target_os = "macos")]
    {
        use godot::classes::{DisplayServer, display_server::HandleType};
        if !DisplayServer::singleton().has_feature(godot::classes::display_server::Feature::IME) {
            return;
        }
        let handle = DisplayServer::singleton()
            .window_get_native_handle_ex(HandleType::WINDOW_HANDLE)
            .window_id(window_id)
            .done();
        unsafe { graffitty_set_terminal_key_focus(handle as *mut _, owner, active) };
    }
    #[cfg(not(target_os = "macos"))]
    let _ = (window_id, owner, active);
}

struct GraffittyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for GraffittyExtension {
    // iOS picks its renderer before Main reads the rendering method (Core stage).
    #[cfg(target_os = "ios")]
    fn min_level() -> InitLevel {
        InitLevel::Core
    }

    #[cfg(windows)]
    fn min_level() -> InitLevel {
        InitLevel::Servers
    }

    fn on_stage_init(stage: InitStage) {
        #[cfg(windows)]
        if stage == InitStage::Servers {
            window_frame::enable_per_monitor_dpi();
        }
        #[cfg(target_os = "ios")]
        if stage == InitStage::Core {
            ios_renderer::select();
        }
        if stage == InitStage::Scene {
            movie_writer::register();
        }
        #[cfg(target_os = "macos")]
        if stage == InitStage::Scene && !godot::classes::Engine::singleton().is_editor_hint() {
            if godot::classes::Os::singleton().has_feature("template") {
                // Exported Godot moves cwd into Contents/Resources before
                // loading extensions. An app replacement then unlinks that
                // directory, breaking even absolute DirAccess queries.
                //
                // Packs and native libraries already have absolute paths;
                // terminal launch cwd is retained separately in
                // GRAFFITTY_INITIAL_PWD.
                if let Err(error) = std::env::set_current_dir("/") {
                    godot_error!("Cannot set a stable application working directory: {error}");
                }
            }
            // Godot's AppKit SIGINT handler waits for Main::iteration(). A
            // blocked resource load therefore also traps the launching tty.
            // Standalone terminals must remain interruptible outside that loop.
            unsafe { graffitty_restore_sigint() };
            unsafe { graffitty_install_window_frame() };
            unsafe { graffitty_install_folder_services() };
        }
        let _ = stage;
    }

    fn on_stage_deinit(stage: InitStage) {
        if stage == InitStage::Scene {
            movie_writer::unregister();
        }
    }
}

mod graph_client;
#[cfg(any(target_os = "linux", test))]
mod x11_scale;
#[cfg(target_os = "ios")]
mod ios_renderer;
mod agent_attention;
mod agents;
mod attention_audio;
