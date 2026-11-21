#include "register_types.h"
#include "core/object/class_db.h"
#include "platform/linuxbsd/wayland/wayland_thread.h"
#include "servers/display/display_server.h"

// Godot receives xdg_toplevel and libdecor configure events on its own
// thread. The public Window API exposes maximize/fullscreen but omits tiling.
// Build this query with the same engine headers that own the surface state.
class GraffittyWaylandFrame : public Object {
    GDCLASS(GraffittyWaylandFrame, Object);

    static WaylandThread::WindowState *window_state(int window_id) {
        auto *server = DisplayServer::get_singleton();
        if (server->get_name() != "Wayland") {
            return nullptr;
        }
        auto *surface = reinterpret_cast<wl_surface *>(server->window_get_native_handle(
                DisplayServerEnums::WINDOW_HANDLE, window_id));
        // Window destruction and this call both run on the Godot main thread.
        return WaylandThread::wl_surface_get_window_state(surface);
    }

    // Godot's fractional per-surface query is public C++ but absent from ClassDB.
    static double get_scale(int window_id) {
        return DisplayServer::get_singleton()->window_get_scale(window_id);
    }

    static bool is_tiled(int window_id) {
        auto *state = window_state(window_id);
        if (!state) {
            return false;
        }
        MutexLock lock(state->wayland_thread->mutex);
        return state->tiled_left || state->tiled_right || state->tiled_top || state->tiled_bottom;
    }

    static void set_input_shape(int window_id, double radius_px, bool passthrough) {
        auto *state = window_state(window_id);
        if (!state) {
            return;
        }
        MutexLock lock(state->wayland_thread->mutex);
        if (!passthrough && radius_px <= 0) {
            wl_surface_set_input_region(state->wl_surface, nullptr);
            return;
        }
        auto *region = wl_compositor_create_region(state->registry->wl_compositor);
        if (!region) {
            return;
        }
        if (!passthrough) {
            // wl_region uses surface coordinates, even for fractional-scale buffers.
            Size2i size = state->rect.size;
            double r = MIN(radius_px / WaylandThread::window_state_get_scale_factor(state),
                    0.5 * MIN(size.x, size.y));
            int rows = MIN(int(Math::ceil(r)), size.y / 2);
            wl_region_add(region, 0, rows, size.x, size.y - 2 * rows);
            for (int y = 0; y < rows; ++y) {
                double dy = MAX(0.0, r - y - 0.5);
                int inset = int(Math::round(r - Math::sqrt(r * r - dy * dy)));
                wl_region_add(region, inset, y, size.x - 2 * inset, 1);
                wl_region_add(region, inset, size.y - 1 - y, size.x - 2 * inset, 1);
            }
        }
        wl_surface_set_input_region(state->wl_surface, region);
        wl_region_destroy(region); // The next Godot surface commit applies the copy.
    }

protected:
    static void _bind_methods() {
        ClassDB::bind_static_method("GraffittyWaylandFrame", D_METHOD("get_scale", "window_id"), &GraffittyWaylandFrame::get_scale);
        ClassDB::bind_static_method("GraffittyWaylandFrame", D_METHOD("set_input_shape", "window_id", "radius_px", "passthrough"), &GraffittyWaylandFrame::set_input_shape);
        ClassDB::bind_static_method("GraffittyWaylandFrame", D_METHOD("is_tiled", "window_id"), &GraffittyWaylandFrame::is_tiled);
    }
};

void initialize_graffitty_wayland_frame_module(ModuleInitializationLevel level) {
    if (level == MODULE_INITIALIZATION_LEVEL_SCENE) {
        GDREGISTER_ABSTRACT_CLASS(GraffittyWaylandFrame);
    }
}

void uninitialize_graffitty_wayland_frame_module(ModuleInitializationLevel level) {}
