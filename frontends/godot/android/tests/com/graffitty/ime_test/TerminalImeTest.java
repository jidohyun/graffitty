package com.graffitty.ime_test;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.widget.EditText;
import com.graffitty.input.TerminalIme;
import org.godotengine.godot.GodotLib;

/** Exercise real InputConnection dispatch, including SwiftKey's balanced Shift chords. */
public final class TerminalImeTest extends Instrumentation {
    public static final class EditorActivity extends Activity {}
    private TerminalIme ime;
    private EditText editor;
    private InputConnection connection;

    @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }

    private void key(int action, int code, int meta) {
        long now = SystemClock.uptimeMillis();
        // BaseInputConnection returns false even after queuing the event.
        connection.sendKeyEvent(new KeyEvent(now, now, action, code, 0, meta,
            KeyCharacterMap.VIRTUAL_KEYBOARD, 0, KeyEvent.FLAG_SOFT_KEYBOARD,
            InputDevice.SOURCE_KEYBOARD));
    }

    private void arrow(int code, boolean shift) {
        int meta = shift ? KeyEvent.META_SHIFT_ON | KeyEvent.META_SHIFT_LEFT_ON : 0;
        if (shift) key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_SHIFT_LEFT, meta);
        key(KeyEvent.ACTION_DOWN, code, meta);
        key(KeyEvent.ACTION_UP, code, meta);
        if (shift) key(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_SHIFT_LEFT, 0);
    }

    /** The host's text after replaying every committed string and Backspace. */
    private String remote() {
        StringBuilder text = new StringBuilder();
        for (Object[] event : GodotLib.events) {
            text.append((String) event[1]);
            if (event[3].equals(KeyEvent.KEYCODE_DEL) && text.length() > 0) text.setLength(text.length() - 1);
        }
        return text.toString();
    }

    private String preview() {
        return GodotLib.events.isEmpty() ? "" : (String) GodotLib.events.get(GodotLib.events.size() - 1)[2];
    }

    private void checkKey(int index, int code, int modifiers) {
        Object[] event = GodotLib.events.get(index);
        if (!event[3].equals(code) || !event[4].equals(modifiers))
            throw new AssertionError("Expected key " + code + " modifiers " + modifiers
                + ", got " + event[3] + "/" + event[4]);
    }

    private Bundle sharedCommand(int sequence, String operation) {
        Bundle data = new Bundle();
        data.putString("session", "keyboard-test"); data.putInt("seq", sequence);
        data.putString("op", operation); data.putInt("gesture", 1);
        return data;
    }

    private void checkSharedModifiers() {
        String action = "com.graffitty.input.MODIFIERS";
        EditorInfo info = new EditorInfo();
        InputConnection input = editor.onCreateInputConnection(info);
        if (info.extras == null || info.extras.getInt(action) != 1)
            throw new AssertionError("Editor must advertise the protocol");
        java.util.List<Bundle> replies = new java.util.ArrayList<>();
        Bundle hello = sharedCommand(1, "hello");
        hello.putParcelable("reply", new android.os.ResultReceiver(null) {
            @Override protected void onReceiveResult(int result, Bundle data) { replies.add(data); }
        });
        android.os.Parcel parcel = android.os.Parcel.obtain();
        try {
            hello.writeToParcel(parcel, 0);
            parcel.setDataPosition(0);
            Bundle foreign = Bundle.CREATOR.createFromParcel(parcel);
            foreign.setClassLoader(android.os.ResultReceiver.class.getClassLoader());
            int commands = GodotLib.modifierCommands.size();
            if (input.performPrivateCommand(action, foreign))
                throw new AssertionError("A private receiver class must be rejected without crashing");
            if (GodotLib.modifierCommands.size() != commands)
                throw new AssertionError("Invalid handshake must not change the modifier state");
        } finally { parcel.recycle(); }
        if (!input.performPrivateCommand(action, hello)) throw new AssertionError("Handshake rejected");
        ime.modifierState(1, "keyboard-test", 1, 4, 0);
        ime.modifierState(1, "old-keyboard", 1, 0, 0);
        if (replies.size() != 1 || replies.get(0).getInt("armed") != 4)
            throw new AssertionError("Only the current peer receives toolbar state");
        Bundle cycle = sharedCommand(2, "cycle"); cycle.putInt("bit", 4);
        if (!input.performPrivateCommand(action, cycle) || input.performPrivateCommand(action, cycle))
            throw new AssertionError("Duplicate modifier commands must not cycle twice");
        Object[] edit = GodotLib.modifierCommands.get(GodotLib.modifierCommands.size() - 1);
        if (!edit[3].equals("cycle") || !edit[4].equals(4)) throw new AssertionError("Modifier UI command lost");
        ime.modifierState(1, "keyboard-test", 2, 4, 4);
        if (replies.get(1).getInt("locked") != 4 || replies.get(1).getInt("ack") != 2)
            throw new AssertionError("Locked state must include its acknowledged edit");
        GodotLib.sharedKeys.clear();
        input.setComposingText("한", 1);
        GodotLib.events.clear();
        Bundle begin = sharedCommand(3, "begin"); begin.putInt("key", KeyEvent.KEYCODE_DPAD_LEFT);
        if (!input.performPrivateCommand(action, begin)) throw new AssertionError("Gesture rejected");
        if (GodotLib.events.size() != 1 || !GodotLib.events.get(0)[1].equals("한") ||
                !GodotLib.events.get(0)[6].equals(true))
            throw new AssertionError("Shared gesture must finish composition without consuming its modifier");
        for (int index = 0; index < 50; index++)
            if (!input.performPrivateCommand(action, sharedCommand(4 + index, "repeat")))
                throw new AssertionError("Repeat rejected");
        if (!input.performPrivateCommand(action, sharedCommand(54, "end"))) throw new AssertionError("Release rejected");
        if (GodotLib.sharedKeys.size() != 52) throw new AssertionError("Lost or duplicate gesture edges");
        for (int index = 0; index < 52; index++) {
            Object[] key = GodotLib.sharedKeys.get(index);
            int edge = index == 0 ? 1 : index == 51 ? 3 : 2;
            if (!key[3].equals(KeyEvent.KEYCODE_DPAD_LEFT) || !key[6].equals(edge))
                throw new AssertionError("Hold must preserve down/repeat/up edges");
        }
        begin = sharedCommand(55, "begin"); begin.putInt("key", KeyEvent.KEYCODE_DPAD_RIGHT);
        input.performPrivateCommand(action, begin);
        InputConnection replacement = editor.onCreateInputConnection(new EditorInfo());
        input.closeConnection(); // A late close of the old connection must leave the new one usable.
        if (GodotLib.sharedKeys.size() != 54 || !GodotLib.sharedKeys.get(53)[6].equals(3))
            throw new AssertionError("Connection cancellation must release the active gesture once");
        if (input.performPrivateCommand(action, sharedCommand(56, "repeat")))
            throw new AssertionError("Closed connection accepted another repeat");
        if (!replacement.performPrivateCommand(action, hello))
            throw new AssertionError("Replacement connection rejected its handshake");
        replacement.closeConnection();
    }

    private void checkImageContent() {
        EditorInfo info = new EditorInfo();
        InputConnection input = editor.onCreateInputConnection(info);
        if (!java.util.Arrays.asList(info.contentMimeTypes).contains("image/png"))
            throw new AssertionError("Editor must advertise image paste");
        android.view.inputmethod.InputContentInfo image = new android.view.inputmethod.InputContentInfo(
            android.net.Uri.parse("content://com.graffitty.ime_test.images/fixture"),
            new android.content.ClipDescription("fixture", new String[]{"image/png"}), null);
        GodotLib.images.clear();
        if (!input.commitContent(image, 0, null)) throw new AssertionError("Image content rejected");
        try {
            if (GodotLib.images.size() != 1) throw new AssertionError("Image must be delivered exactly once");
            Object[] event = GodotLib.images.get(0);
            if (!event[0].equals(1) || !new org.json.JSONObject((String) event[1]).getString("image").equals(ImageProvider.PNG))
                throw new AssertionError("Image bytes or generation changed");
        } catch (org.json.JSONException error) { throw new AssertionError(error); }
        input.closeConnection();
        if (input.commitContent(image, 0, null) || GodotLib.images.size() != 1)
            throw new AssertionError("Obsolete input connection delivered image content");
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        Activity activity = null;
        try {
            activity = startActivitySync(new Intent(getTargetContext(), EditorActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
            Activity target = activity;
            runOnMainSync(() -> {
                try { ime = new TerminalIme(target, 1); }
                catch (Exception e) { throw new AssertionError(e); }
                ime.open(1);
                editor = (EditText) target.getCurrentFocus();
            });
            waitForIdleSync();
            if (android.os.Build.VERSION.SDK_INT >= 30) runOnMainSync(() -> {
                try {
                    java.lang.reflect.Field field = TerminalIme.class.getDeclaredField("insetObserver");
                    field.setAccessible(true);
                    android.view.View observer = (android.view.View) field.get(ime);
                    GodotLib.heights.clear();
                    int padding = target.getWindow().getDecorView().getPaddingBottom();
                    android.view.WindowInsets shown = new android.view.WindowInsets.Builder()
                        .setInsets(android.view.WindowInsets.Type.ime(), android.graphics.Insets.of(0, 0, 0, 420 + padding))
                        .setVisible(android.view.WindowInsets.Type.ime(), true).build();
                    observer.dispatchApplyWindowInsets(shown);
                    observer.dispatchApplyWindowInsets(shown);
                    if (!GodotLib.heights.equals(java.util.Arrays.asList(420)) || ime.height() != 420)
                        throw new AssertionError("Changed inset emits once; getter returns cached height");
                    observer.dispatchApplyWindowInsets(new android.view.WindowInsets.Builder(shown)
                        .setVisible(android.view.WindowInsets.Type.ime(), false).build());
                    if (!GodotLib.heights.equals(java.util.Arrays.asList(420, 0)) || ime.height() != 0)
                        throw new AssertionError("Keyboard dismissal publishes zero inset");
                } catch (ReflectiveOperationException e) { throw new AssertionError(e); }
            });
            int[] codes = {KeyEvent.KEYCODE_DPAD_LEFT, KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_TAB,
                KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_ESCAPE, KeyEvent.KEYCODE_DEL};
            for (int code : codes) {
                runOnMainSync(() -> {
                    // Focus/startup can replace a connection between UI tasks.
                    connection = editor.onCreateInputConnection(new EditorInfo());
                    GodotLib.events.clear(); arrow(code, true);
                });
                waitForIdleSync();
                if (GodotLib.events.size() != 1) throw new AssertionError("Chord must emit once");
                checkKey(0, code, 4);
            }
            runOnMainSync(() -> {
                connection = editor.onCreateInputConnection(new EditorInfo());
                GodotLib.events.clear();
                for (int n = 0; n < 50; n++) arrow(KeyEvent.KEYCODE_DPAD_LEFT, true);
                arrow(KeyEvent.KEYCODE_DPAD_LEFT, false);
            });
            waitForIdleSync();
            if (GodotLib.events.size() != 51) throw new AssertionError("Lost or duplicated repeats");
            for (int n = 0; n < 50; n++) checkKey(n, KeyEvent.KEYCODE_DPAD_LEFT, 4);
            checkKey(50, KeyEvent.KEYCODE_DPAD_LEFT, 0);
            runOnMainSync(() -> {
                connection = editor.onCreateInputConnection(new EditorInfo());
                connection.setComposingText("한", 1);
                GodotLib.events.clear();
                arrow(KeyEvent.KEYCODE_DPAD_LEFT, true);
            });
            waitForIdleSync();
            if (GodotLib.events.size() != 2 || !GodotLib.events.get(0)[1].equals("한"))
                throw new AssertionError("Arrow must commit composition before moving");
            checkKey(1, KeyEvent.KEYCODE_DPAD_LEFT, 4);
            // A keyboard that keeps the whole Korean word composing still
            // delivers each syllable as soon as the next one starts.
            runOnMainSync(() -> {
                connection = editor.onCreateInputConnection(new EditorInfo());
                GodotLib.events.clear();
                for (String step : new String[]{"ㅇ", "아", "안", "안ㄴ", "안녀", "안녕", "안녕ㅎ", "안녕하"})
                    connection.setComposingText(step, 1);
            });
            waitForIdleSync();
            if (!remote().equals("안녕") || !preview().equals("하"))
                throw new AssertionError("Finished syllables stream, the open one previews; got " + remote() + "/" + preview());
            runOnMainSync(() -> {
                for (String step : new String[]{"안녕ㅎ", "안녕", "안녀"}) connection.setComposingText(step, 1);
            });
            waitForIdleSync();
            if (!remote().equals("안") || !preview().equals("녀"))
                throw new AssertionError("Backspace into a sent syllable reopens it; got " + remote() + "/" + preview());
            runOnMainSync(() -> connection.commitText("안녀 ", 1));
            waitForIdleSync();
            if (!remote().equals("안녀 ") || !preview().isEmpty())
                throw new AssertionError("Committing the word sends only the remainder; got " + remote() + "/" + preview());
            runOnMainSync(() -> {
                connection = editor.onCreateInputConnection(new EditorInfo());
                GodotLib.events.clear();
                connection.setComposingText("にほ", 1);
            });
            waitForIdleSync();
            if (!remote().isEmpty() || !preview().equals("にほ"))
                throw new AssertionError("Other composing scripts stay local; got " + remote() + "/" + preview());
            runOnMainSync(() -> connection.commitText("日本", 1));
            waitForIdleSync();
            if (!remote().equals("日本")) throw new AssertionError("Converted text commits whole; got " + remote());
            runOnMainSync(() -> {
                connection = editor.onCreateInputConnection(new EditorInfo());
                GodotLib.events.clear();
                int ctrl = KeyEvent.META_CTRL_ON | KeyEvent.META_CTRL_LEFT_ON;
                key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_CTRL_LEFT, ctrl);
                key(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER, ctrl);
                key(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER, ctrl);
                key(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_CTRL_LEFT, 0);
                arrow(KeyEvent.KEYCODE_ENTER, false);
            });
            waitForIdleSync();
            if (GodotLib.events.size() != 2) throw new AssertionError("Ctrl+Enter and plain Enter must each emit once; got " + GodotLib.events.size());
            checkKey(0, KeyEvent.KEYCODE_ENTER, 1);
            checkKey(1, KeyEvent.KEYCODE_ENTER, 0);
            runOnMainSync(this::checkSharedModifiers);
            runOnMainSync(this::checkImageContent);
            boolean actualKeyboard = SwiftKeyChannelTest.run(this, editor, ime);
            result.putString("stream", "PASS: Shift navigation, 50 SwiftKey-style repeats, Hangul, Ctrl+Enter; shared modifier handshake, foreign callback rejection, state replies, duplicate rejection, 50 gesture repeats and connection cancellation"
                + (actualKeyboard ? "; actual SwiftKey connector negotiation, two-way state, repeat and stale-reply rejection" : "") + "\n");
            finish(Activity.RESULT_OK, result);
        } catch (Throwable error) {
            result.putString("stream", "FAIL: " + error + "\n");
            finish(Activity.RESULT_CANCELED, result);
        } finally {
            if (ime != null) ime.dispose();
            if (activity != null) {
                Activity target = activity;
                runOnMainSync(() -> { if (ime != null) ime.close(2); target.finish(); });
            }
        }
    }
}
