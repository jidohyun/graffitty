package com.graffitty.input;

import android.os.Bundle;
import android.os.BadParcelableException;
import android.os.ResultReceiver;
import android.view.KeyEvent;

/** Android transport for the editor's modifier UI and complete keyboard gestures.
 * Selection remains owned by the application; this adapter never holds an OS modifier.
 */
final class ModifierChannel {
    static final String ACTION = "com.graffitty.input.MODIFIERS";
    interface Sink {
        void state(String session, int sequence, String operation, int bit);
        void key(String session, int sequence, int code, int meta, int unicode, int edge);
    }
    private final Sink sink;
    private ResultReceiver reply;
    private String session = "";
    private int sequence, revision, publishedAck, gesture, code, meta, unicode;

    ModifierChannel(Sink sink) { this.sink = sink; }

    boolean handle(Bundle data) {
        try {
            return receive(data);
        } catch (BadParcelableException | ClassCastException invalid) {
            // An IME is another process: its private Parcelable classes are
            // unavailable here. Reject the message without losing the editor.
            return false;
        }
    }

    private boolean receive(Bundle data) {
        if (data == null) return false;
        String token = data.getString("session", "");
        String operation = data.getString("op", "");
        int seq = data.getInt("seq");
        if (token.isEmpty() || token.length() > 100 || seq <= 0) return false;
        if (operation.equals("hello")) {
            ResultReceiver receiver = data.getParcelable("reply");
            if (receiver == null) return false;
            release();
            session = token; sequence = seq; reply = receiver; revision = 0; publishedAck = 0;
            sink.state(session, sequence, "hello", 0);
            return true;
        }
        if (reply == null || !session.equals(token) || seq <= sequence) return false;
        sequence = seq;
        switch (operation) {
            case "cycle":
                int bit = data.getInt("bit");
                if (bit != 1 && bit != 2 && bit != 4) return false;
                sink.state(session, sequence, "cycle", bit);
                return true;
            case "begin":
                int key = data.getInt("key"), id = data.getInt("gesture");
                if (id <= 0 || key <= 0 || key > KeyEvent.getMaxKeyCode() || KeyEvent.isModifierKey(key)) return false;
                release();
                gesture = id; code = key; meta = data.getInt("meta") & 7;
                unicode = data.getInt("unicode");
                if (unicode < 0 || unicode > 0x10ffff) unicode = 0;
                sink.key(session, sequence, code, meta, unicode, 1);
                return true;
            case "repeat":
                if (gesture == 0 || data.getInt("gesture") != gesture) return false;
                sink.key(session, sequence, code, meta, unicode, 2);
                return true;
            case "end":
                if (gesture == 0 || data.getInt("gesture") != gesture) return false;
                release();
                return true;
            case "bye":
                close();
                return true;
            default: return false;
        }
    }

    private void release() {
        if (gesture == 0) return;
        sink.key(session, sequence, code, meta, unicode, 3);
        gesture = 0;
    }

    void publish(String token, int acknowledged, int armed, int locked) {
        if (reply == null || !session.equals(token) || acknowledged < publishedAck ||
                (armed & ~7) != 0 || (locked & ~armed) != 0) return;
        publishedAck = acknowledged;
        Bundle data = new Bundle();
        data.putString("session", session); data.putInt("revision", ++revision);
        data.putInt("ack", acknowledged); data.putInt("armed", armed); data.putInt("locked", locked);
        reply.send(1, data);
    }

    void close() {
        release();
        if (reply != null) sink.state(session, sequence, "bye", 0);
        reply = null; session = ""; sequence = 0;
    }
}
