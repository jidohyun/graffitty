package org.godotengine.godot;

import java.util.ArrayList;
import java.util.List;

/** Capture the native bridge boundary in the isolated Android instrumentation APK. */
public final class GodotLib {
    public static final List<Object[]> events = new ArrayList<>();
    public static final List<Integer> heights = new ArrayList<>();
    public static final List<Object[]> modifierCommands = new ArrayList<>();
    public static final List<Object[]> sharedKeys = new ArrayList<>();
    public static final List<Object[]> images = new ArrayList<>();
    public static void calldeferred(long receiver, String method, Object[] args) {
        if (method.equals("_native_event")) events.add(args);
        else if (method.equals("_native_keyboard_height")) heights.add((Integer) args[0]);
        else if (method.equals("_native_modifier_command")) modifierCommands.add(args);
        else if (method.equals("_native_shared_key")) sharedKeys.add(args);
        else if (method.equals("_native_image")) images.add(args);
        else throw new AssertionError("Unexpected bridge method: " + method);
    }
}
