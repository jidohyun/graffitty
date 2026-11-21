package com.graffitty.ime_test;

import android.app.Instrumentation;
import android.inputmethodservice.InputMethodService;
import android.os.Bundle;
import android.os.Parcel;
import android.os.ResultReceiver;
import android.view.KeyEvent;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.widget.EditText;
import com.graffitty.input.TerminalIme;
import java.lang.reflect.Proxy;
import org.godotengine.godot.GodotLib;

/** Both production Android adapters, in a disposable fixture; no installed IME is replaced. */
final class SwiftKeyChannelTest {
    private static final class Service extends InputMethodService {
        InputConnection connection;
        EditorInfo info;
        @Override public InputConnection getCurrentInputConnection() { return connection; }
        @Override public EditorInfo getCurrentInputEditorInfo() { return info; }
    }
    private static void check(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    static boolean run(Instrumentation test, EditText editor, TerminalIme ime) throws Exception {
        final Class<?> type;
        try { type = Class.forName("app.polyglot.swiftkey.extension.SharedModifiers"); }
        catch (ClassNotFoundException absent) { return false; }
        Class<?> function = Class.forName("kotlin.jvm.functions.Function0");
        Object unit = Class.forName("kotlin.Unit").getField("INSTANCE").get(null);
        Object callback = Proxy.newProxyInstance(function.getClassLoader(), new Class<?>[]{function},
            (proxy, method, args) -> unit);
        Service service = new Service();
        Object[] client = {null};
        ResultReceiver[] reply = {null};
        String[] session = {null};
        int[] ack = {0};
        test.runOnMainSync(() -> {
            try {
                service.info = new EditorInfo();
                service.connection = new InputConnectionWrapper(editor.onCreateInputConnection(service.info), false) {
                    @Override public boolean performPrivateCommand(String action, Bundle data) {
                        // Model Binder's application boundary. The receiving
                        // editor must not resolve any of the keyboard's classes.
                        Parcel parcel = Parcel.obtain();
                        try {
                            data.writeToParcel(parcel, 0);
                            parcel.setDataPosition(0);
                            Bundle received = Bundle.CREATOR.createFromParcel(parcel);
                            received.setClassLoader(ResultReceiver.class.getClassLoader());
                            if (received.getString("op").equals("hello")) {
                                reply[0] = received.getParcelable("reply");
                                check(reply[0].getClass() == ResultReceiver.class,
                                    "Handshake must carry a framework receiver, not a keyboard subclass");
                            }
                            return super.performPrivateCommand(action, received);
                        } finally { parcel.recycle(); }
                    }
                };
                GodotLib.modifierCommands.clear(); GodotLib.sharedKeys.clear();
                client[0] = type.getConstructor(InputMethodService.class, function).newInstance(service, callback);
                type.getMethod("connect", boolean.class).invoke(client[0], true);
                Object[] hello = GodotLib.modifierCommands.get(0);
                session[0] = (String) hello[1]; ack[0] = (Integer) hello[2];
                ime.modifierState(1, session[0], ack[0], 0, 0);
            } catch (Exception error) { throw new AssertionError(error); }
        });
        test.waitForIdleSync();
        check((Boolean) type.getMethod("getReady").invoke(client[0]), "Actual keyboard connector did not negotiate");
        test.runOnMainSync(() -> {
            try {
                type.getMethod("cycle", int.class).invoke(client[0], 4);
                Object[] command = GodotLib.modifierCommands.get(1);
                check(command[3].equals("cycle") && command[4].equals(4), "Keyboard Shift did not reach application");
                ack[0] = (Integer) command[2];
                ime.modifierState(1, session[0], ack[0], 4, 0);
            } catch (Exception error) { throw new AssertionError(error); }
        });
        test.waitForIdleSync();
        Object snapshot = type.getMethod("getSnapshot").invoke(client[0]);
        check(snapshot.getClass().getMethod("getArmed").invoke(snapshot).equals(4), "Keyboard lost shared Shift");
        test.runOnMainSync(() -> ime.modifierState(1, session[0], ack[0], 4, 4));
        test.waitForIdleSync();
        check(snapshot.getClass().getMethod("getLocked").invoke(snapshot).equals(4), "Toolbar lock did not reach keyboard");
        test.runOnMainSync(() -> {
            try {
                int id = (Integer) type.getMethod("begin", int.class, int.class, int.class)
                    .invoke(client[0], KeyEvent.KEYCODE_DPAD_LEFT, 0, 0);
                check(id != 0, "Actual keyboard gesture did not begin");
                for (int index = 0; index < 50; index++) type.getMethod("repeat", int.class).invoke(client[0], id);
                type.getMethod("end", int.class).invoke(client[0], id);
                check(GodotLib.sharedKeys.size() == 52, "Actual connector lost or duplicated gesture edges");
                check(GodotLib.sharedKeys.get(0)[6].equals(1) && GodotLib.sharedKeys.get(51)[6].equals(3),
                    "Actual connector did not preserve press/release");
                type.getMethod("close").invoke(client[0]);
                Bundle stale = new Bundle(); stale.putString("session", session[0]);
                stale.putInt("revision", 999); stale.putInt("ack", 999); stale.putInt("armed", 4);
                reply[0].send(1, stale);
            } catch (Exception error) { throw new AssertionError(error); }
        });
        test.waitForIdleSync();
        check(!(Boolean) type.getMethod("getReady").invoke(client[0]), "Stale callback resurrected disconnected keyboard state");
        return true;
    }
}
