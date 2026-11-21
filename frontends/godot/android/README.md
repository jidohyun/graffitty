# Android native bridges

The shared workspace defaults to Flat 2D. Select **View → World → Flat 3D**
to use the bundled 3D presentation, or set `[world] path = "flat-3d"` at startup.

`uv run tools/build_android.py` builds the Java bridges and bundles them into
Godot's installed Android export template. This requires a JDK, the Android
SDK/NDK, and `apktool` (`brew install apktool` on macOS).

`tools/android_launch.py` caches a resource rebuild of the stock template. It
registers `GraffittyApplication` and suppresses the system's icon-only launch
preview. API 31+ uses a translucent launch theme because launcher-originated
starts can ignore `windowDisablePreview`. After the first Godot frame, the
bridge calls `Activity.setTranslucent(false)` to restore activity opacity;
changing to an opaque theme alone does not update the window manager.

The application draws the exported wall texture across the window
with the transparent Graffitty logo centered. The window theme uses the same
artwork, and the cover is attached synchronously during activity creation so
no queued callback leaves the first window frame uncovered. It removes the
cover after Godot draws its first application frame. There is no minimum
splash duration.
This avoids depending on device-specific support for a bitmap in Android's
system splash background, which officially supports only an opaque color.

Godot's exporter replaces fixed image paths. Apktool normalizes density
qualifiers in those paths, so the template preparation removes the renamed
engine icon variants and retains the base images that Godot replaces. Otherwise
Android selects the untouched Godot launcher icon and solid background.

The IME and Vulkan surface lifecycle bridges are compiled alongside the launch
bridge. No engine fork or Gradle build is needed.

The terminal editor advertises `com.graffitty.input.MODIFIERS = 1` in
`EditorInfo.extras`. SwiftKey Polyglot's Programming Mode negotiates the matching
private-command channel. Graffitty owns the selected Ctrl/Alt/Shift state; keyboard
edits cycle the same toolbar selections, and `ResultReceiver` replies mirror
armed/locked masks back to the keyboard. Masks use Ctrl=1, Alt=2 and Shift=4.
Each peer has an opaque session token and increasing command sequence; replies
include the acknowledged sequence and an increasing revision. Obsolete peers,
connections and replies cannot restore a consumed selection.

`hello` carries a framework `android.os.ResultReceiver`, normalized by parceling
the sender's local receiver through `ResultReceiver.CREATOR`. A keyboard-private
subclass cannot be loaded by another application. Malformed private-command
parcels are rejected without crashing the editor. The instrumentation harness
round-trips the actual connector's Bundle with the framework class loader.
`cycle` carries a modifier bit; `begin`
carries a gesture ID, Android key code, extra modifier mask and character;
`repeat` and `end` refer to that gesture; `bye` disconnects. Complete gestures
become Godot press/repeat/release events, so the existing keybar preserves its
captured modifiers throughout a keyboard arrow hold. The native editor finishes
composition first, without consuming the pending shortcut's modifier. Connection
replacement/cancellation releases the active gesture; toolbar selections survive
an editor restart and are sent to the replacement peer during its handshake.
No standalone OS modifier is held merely by selecting a toolbar button. Other
keyboards and editors keep their ordinary Android input path.

`tests/android/test_android_ime.py --serial <device>` exercises the native receiving
adapter in a disposable package. Add `--keyboard-extension-apk <debug.apk>` to
bundle SwiftKey's debug extension DEX into that fixture and exercise its actual
connector too, without replacing the installed keyboard. This is adapter-level
instrumentation, not a physical keyboard-touch or terminal-byte E2E pass.

The template preparation also raises the minimum to Android 8 (API 26). Dictation
records through AAudio, which Android 8 introduced, and the client disables
Godot's audio driver: its silent output stream kept the system audio server
busy on most of a CPU core. Hardware Chromium video additionally needs Android 9;
Android 8 receives PNG frames.

Verify launches by tapping the actual app icon. `adb shell am start`, even
with MAIN/LAUNCHER intent flags, can bypass the system splash seen from the
launcher. Check both the opening animation and the final opaque activity.


## Terminal image paste

The terminal Paste action and native selection menu read image `content://`
items with `ContentResolver`; URI text is never pasted as a local file path.
The terminal editor advertises PNG, JPEG, WebP, GIF, BMP and TIFF support through
`EditorInfo.contentMimeTypes`. Keyboard `commitContent` reads the image while
its temporary permission grant is held and releases the grant afterward.
Callbacks retain the editor generation, so old connections cannot paste into a
replacement pane. Rust validates/normalizes bytes, then uploads to the owning
Graffitty server before pasting its completed path. Transfer size is limited to
32 MiB. Existing text/composition behavior remains on the text path.

Use `tests/android/test_android_ime.py` for the disposable native adapter test and
`tests/android/test_android_runtime.py android-bracketed-paste` for shared transfer/PTY
checks. Physical clipboard, IME and agent recognition requirements are IN-09 in
`tests/e2e/input.md`; adapter tests alone are not that acceptance pass.
