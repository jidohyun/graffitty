package com.graffitty.input;

import android.app.Activity;
import android.graphics.Color;
import android.text.Editable;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import java.lang.reflect.Method;

/** Native composing editor for terminal input. Latin keys stream immediately, Hangul streams each finished
 * syllable, and other composing scripts stay local. */
public final class TerminalIme {
    private final Activity activity;
    private final long receiver;
    private final Method callback;
    private final ModifierChannel modifiers;
    private boolean beforeSharedKey;
    private Editor editor;
    private View previousFocus;
    private boolean active, shortcut;
    private int generation, batch, connectionSerial;
    private String lastPreview = "";
    private int forwarded;
    /** The forwarded text itself: editor text [0, forwarded). */
    private String sent = "";
    private volatile int keyboardHeight = -1;
    private volatile String surfaceBounds = "[]";

    /** Native content bounds, including system bars; useful for input mapping. */
    public String surfaceBounds() {
        activity.runOnUiThread(() -> {
            android.view.SurfaceView view = findSurface(activity.getWindow().getDecorView());
            if (view == null) { surfaceBounds = "[]"; return; }
            int[] position = new int[2];
            view.getLocationOnScreen(position);
            surfaceBounds = "[" + position[0] + "," + position[1] + ","
                + (position[0] + view.getWidth()) + "," + (position[1] + view.getHeight()) + "]";
        });
        return surfaceBounds;
    }

    private static android.view.SurfaceView findSurface(View view) {
        if (view instanceof android.view.SurfaceView
                && view.getClass().getName().startsWith("org.godotengine.godot."))
            return (android.view.SurfaceView) view;
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int index = 0; index < group.getChildCount(); index++) {
                android.view.SurfaceView result = findSurface(group.getChildAt(index));
                if (result != null) return result;
            }
        }
        return null;
    }

    private View insetObserver;
    private boolean disposed;
    private android.view.ViewTreeObserver.OnGlobalLayoutListener layoutListener;

    public int height() {
        return keyboardHeight;
    }

    public TerminalIme(Activity activity, long receiver) throws Exception {
        this.activity = activity;
        this.receiver = receiver;
        callback = Class.forName("org.godotengine.godot.GodotLib")
            .getMethod("calldeferred", long.class, String.class, Object[].class);
        modifiers = new ModifierChannel(new ModifierChannel.Sink() {
            public void state(String session, int sequence, String operation, int bit) {
                if (operation.equals("cycle")) finishBeforeSharedKey();
                notifyGodot("_native_modifier_command", generation, session, sequence, operation, bit);
            }
            public void key(String session, int sequence, int code, int meta, int unicode, int edge) {
                if (edge == 1) finishBeforeSharedKey();
                notifyGodot("_native_shared_key", generation, session, sequence, code, meta, unicode, edge);
            }
        });
        RenderSurfaceLifecycle.install(activity);
        activity.runOnUiThread(this::observeInsets);
    }

    private void publishHeight(int value) {
        if (disposed || (value >= 0 && value == keyboardHeight)) return;
        keyboardHeight = value;
        try {
            callback.invoke(null, receiver, "_native_keyboard_height", new Object[]{value});
        } catch (Exception e) { throw new IllegalStateException("Keyboard inset callback", e); }
    }

    private void observeInsets() {
        if (disposed) return;
        View root = activity.getWindow().getDecorView();
        // A separate observer preserves Godot's own inset/animation listeners.
        insetObserver = new View(activity);
        insetObserver.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        insetObserver.setAlpha(0);
        activity.addContentView(insetObserver, new FrameLayout.LayoutParams(1, 1));
        // A consumed inset can stop child dispatch. The decor's layout observer
        // still receives the final geometry without replacing Godot's listener.
        layoutListener = () -> {
            if (android.os.Build.VERSION.SDK_INT >= 30) readInsets(root.getRootWindowInsets());
            else publishHeight(-1);
        };
        root.getViewTreeObserver().addOnGlobalLayoutListener(layoutListener);
        if (android.os.Build.VERSION.SDK_INT >= 30) {
            insetObserver.setOnApplyWindowInsetsListener((view, insets) -> {
                readInsets(insets);
                return insets;
            });
            insetObserver.setWindowInsetsAnimationCallback(new android.view.WindowInsetsAnimation.Callback(
                    android.view.WindowInsetsAnimation.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
                @Override public android.view.WindowInsets onProgress(android.view.WindowInsets insets,
                        java.util.List<android.view.WindowInsetsAnimation> running) {
                    readInsets(insets);
                    return insets;
                }
            });
            readInsets(root.getRootWindowInsets());
            insetObserver.requestApplyInsets();
        } else {
            // Godot measures older Android's keyboard from layout changes. Ask
            // for that measurement only when the native layout actually changes.
            publishHeight(-1);
        }
    }

    private void readInsets(android.view.WindowInsets insets) {
        if (android.os.Build.VERSION.SDK_INT < 30 || insets == null) return;
        View root = activity.getWindow().getDecorView();
        publishHeight(insets.isVisible(android.view.WindowInsets.Type.ime())
            ? Math.max(0, insets.getInsets(android.view.WindowInsets.Type.ime()).bottom - root.getPaddingBottom()) : 0);
    }

    public void dispose() {
        activity.runOnUiThread(() -> {
            modifiers.close();
            disposed = true;
            active = false;
            if (layoutListener != null) activity.getWindow().getDecorView().getViewTreeObserver()
                .removeOnGlobalLayoutListener(layoutListener);
            if (insetObserver != null) {
                insetObserver.setOnApplyWindowInsetsListener(null);
                if (android.os.Build.VERSION.SDK_INT >= 30) insetObserver.setWindowInsetsAnimationCallback(null);
                ((ViewGroup) insetObserver.getParent()).removeView(insetObserver);
                insetObserver = null;
            }
            if (editor != null && editor.getParent() instanceof ViewGroup) {
                imm().hideSoftInputFromWindow(editor.getWindowToken(), 0);
                ((ViewGroup) editor.getParent()).removeView(editor);
            }
        });
    }

    private InputMethodManager imm() {
        return (InputMethodManager) activity.getSystemService(Activity.INPUT_METHOD_SERVICE);
    }

    private void notifyGodot(String method, Object... args) {
        try { callback.invoke(null, receiver, method, args); }
        catch (Exception e) { throw new IllegalStateException("Terminal IME callback", e); }
    }

    public void modifierState(int epoch, String session, int acknowledged, int armed, int locked) {
        activity.runOnUiThread(() -> {
            if (active && generation == epoch) modifiers.publish(session, acknowledged, armed, locked);
        });
    }

    private void emit(String committed, String preview, int key) {
        emit(committed, preview, key, 0, 0);
    }

    private void emit(String committed, String preview, int key, int modifiers, int unicode) {
        if (!active) return;
        try {
            callback.invoke(null, receiver, "_native_event",
                new Object[]{generation, committed, preview, key, modifiers, unicode, beforeSharedKey});
        } catch (Exception e) { throw new IllegalStateException("Terminal IME callback", e); }
        lastPreview = preview;
    }

    public void open(int epoch) {
        activity.runOnUiThread(() -> {
            generation = epoch;
            connectionSerial++;
            if (editor == null) {
                editor = new Editor();
                editor.setTextColor(Color.TRANSPARENT);
                editor.setBackgroundColor(Color.TRANSPARENT);
                editor.setCursorVisible(false);
                editor.setAlpha(0);
                editor.setSingleLine(false);
                editor.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE
                    | InputType.TYPE_TEXT_FLAG_AUTO_CORRECT);
                editor.setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
                editor.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
                activity.addContentView(editor, new FrameLayout.LayoutParams(1, 1));
            }
            previousFocus = activity.getCurrentFocus();
            active = true;
            shortcut = false;
            batch = 0;
            lastPreview = "";
            forwarded = 0;
            sent = "";
            editor.setText("");
            editor.requestFocus();
            imm().restartInput(editor);
            imm().showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT);
            editor.postDelayed(() -> {
                if (active && generation == epoch && editor.hasFocus())
                    imm().showSoftInput(editor, InputMethodManager.SHOW_IMPLICIT);
            }, 250);
        });
    }

    public void close(int epoch) {
        activity.runOnUiThread(() -> {
            modifiers.close();
            generation = epoch;
            connectionSerial++;
            active = false;
            batch = 0;
            lastPreview = "";
            forwarded = 0;
            sent = "";
            if (editor == null) return;
            editor.setText("");
            if (editor.hasFocus()) {
                imm().hideSoftInputFromWindow(editor.getWindowToken(), 0);
                editor.clearFocus();
                if (previousFocus != null && previousFocus != editor) previousFocus.requestFocus();
            }
        });
    }

    public void reset(int epoch, boolean shortcutMode) {
        activity.runOnUiThread(() -> {
            generation = epoch;
            shortcut = shortcutMode;
            batch = 0;
            lastPreview = "";
            forwarded = 0;
            sent = "";
            if (editor != null && active) {
                // A cleared editor already has no word to discard. Notifying
                // the IME again would reset its selected symbol keyboard.
                if (editor.length() == 0) return;
                connectionSerial++;
                editor.setText("");
                imm().restartInput(editor);
            }
        });
    }

    // Called after an InputConnection operation, never from TextWatcher: spans
    // are updated AFTER text mutations, and finishComposingText changes only spans.
    private void publish() {
        if (!active || batch > 0) return;
        Editable text = editor.getText();
        int start = BaseInputConnection.getComposingSpanStart(text);
        int end = BaseInputConnection.getComposingSpanEnd(text);
        if (shortcut) { start = -1; end = -1; }
        String value = text.toString();
        String committed = "", preview = "";
        if (start >= 0 && end > start) {
            // Retain Android's word context for suggestions, but do not wait
            // for Space before sending Latin terminal commands.
            //
            // Hangul sends every syllable but the last, which the next
            // consonant or vowel can still reshape. Other scripts keep the
            // whole composition local.
            boolean immediate = true, hangul = true;
            int last = start;
            for (int offset = start; offset < value.length();) {
                int cp = value.codePointAt(offset);
                Character.UnicodeScript script = Character.UnicodeScript.of(cp);
                if (script != Character.UnicodeScript.LATIN
                    && script != Character.UnicodeScript.COMMON) {
                    immediate = false;
                    if (script != Character.UnicodeScript.HANGUL) hangul = false;
                }
                last = offset;
                offset += Character.charCount(cp);
            }
            int sendThrough = immediate ? value.length() : start;
            if (!immediate && hangul) {
                boolean open = Character.UnicodeScript.of(value.codePointAt(last)) == Character.UnicodeScript.HANGUL;
                sendThrough = open ? last : value.length();
                // Backspace can take a consonant out of a syllable already sent
                // (녕 -> 녀): erase it remotely and compose it locally again.
                int same = 0;
                while (same < sent.length() && same < value.length() && sent.charAt(same) == value.charAt(same)) same++;
                if (same < sent.length()) {
                    int erase = sent.codePointCount(same, sent.length());
                    forwarded = same;
                    sent = sent.substring(0, same);
                    for (int i = 0; i < erase; i++) emit("", lastPreview, KeyEvent.KEYCODE_DEL);
                }
            }
            if (sendThrough > forwarded) committed = value.substring(forwarded, sendThrough);
            forwarded = Math.max(forwarded, sendThrough);
            sent += committed;
            if (!immediate) preview = value.substring(Math.max(start, Math.min(forwarded, value.length())));
            // Suggestions can append characters, but must never generate remote
            // Backspaces to rewrite letters which may have executed commands.
            if (start > 0) {
                text.delete(0, start);
                forwarded = Math.max(0, forwarded - start);
                sent = sent.substring(Math.min(start, sent.length()));
            }
        } else {
            committed = value.substring(Math.min(forwarded, value.length()));
            forwarded = 0;
            sent = "";
            BaseInputConnection.removeComposingSpans(text);
            text.clear();
        }
        if (!committed.isEmpty() || !preview.equals(lastPreview)) emit(committed, preview, 0);
        imm().updateSelection(editor, editor.getSelectionStart(), editor.getSelectionEnd(),
            BaseInputConnection.getComposingSpanStart(text), BaseInputConnection.getComposingSpanEnd(text));
    }

    private void explicitDeletion(int oldLength) {
        int removed = Math.max(0, oldLength - editor.length());
        int local = Math.max(0, oldLength - forwarded);
        int remote = Math.max(0, removed - local);
        forwarded = Math.max(0, forwarded - remote);
        sent = sent.substring(0, Math.min(forwarded, sent.length()));
        for (int i = 0; i < remote; i++) emit("", lastPreview, KeyEvent.KEYCODE_DEL);
    }

    private void finish() {
        if (editor == null) return;
        BaseInputConnection.removeComposingSpans(editor.getText());
        int saved = batch; batch = 0; publish(); batch = saved;
    }

    private void finishBeforeSharedKey() {
        beforeSharedKey = true;
        try { finish(); }
        finally { beforeSharedKey = false; }
    }

    private final class Editor extends EditText {
        Editor() { super(activity); }

        @Override public boolean onTextContextMenuItem(int id) {
            if (active && id == android.R.id.paste) {
                String result = TerminalClipboard.read(activity);
                try {
                    org.json.JSONObject value = new org.json.JSONObject(result);
                    if (value.has("image") || value.has("error")) {
                        finish();
                        notifyGodot("_native_image", generation, result);
                        return true;
                    }
                } catch (org.json.JSONException ignored) {}
            }
            return super.onTextContextMenuItem(id);
        }

        @Override public InputConnection onCreateInputConnection(EditorInfo attrs) {
            InputConnection original = super.onCreateInputConnection(attrs);
            if (original == null) return null;
            attrs.contentMimeTypes = new String[]{"image/png", "image/jpeg", "image/webp", "image/gif", "image/bmp", "image/tiff"};
            modifiers.close();
            if (attrs.extras == null) attrs.extras = new android.os.Bundle();
            attrs.extras.putInt(ModifierChannel.ACTION, 1);
            final int serial = ++connectionSerial;
            return new InputConnectionWrapper(original, false) {
                private boolean valid() { return active && connectionSerial == serial; }
                @Override public boolean commitContent(android.view.inputmethod.InputContentInfo content, int flags, android.os.Bundle opts) {
                    if (!valid() || content == null || !content.getDescription().hasMimeType("image/*")) return false;
                    boolean permission = (flags & InputConnection.INPUT_CONTENT_GRANT_READ_URI_PERMISSION) != 0;
                    try {
                        if (permission) content.requestPermission();
                        finish();
                        // Read while the IME's temporary URI grant is held. The
                        // receiver's generation check prevents late delivery.
                        String result = TerminalClipboard.image(activity, content.getContentUri());
                        notifyGodot("_native_image", generation, result);
                        return true;
                    } catch (Exception error) {
                        notifyGodot("_native_image", generation, TerminalClipboard.failure(error));
                        return true;
                    } finally {
                        if (permission) try { content.releasePermission(); } catch (Exception ignored) {}
                    }
                }
                @Override public boolean performPrivateCommand(String action, android.os.Bundle data) {
                    if (!valid()) return false;
                    return ModifierChannel.ACTION.equals(action) ? modifiers.handle(data) : super.performPrivateCommand(action, data);
                }
                @Override public void closeConnection() {
                    if (valid()) { modifiers.close(); connectionSerial++; }
                    super.closeConnection();
                }
                @Override public boolean beginBatchEdit() {
                    if (!valid()) return false;
                    batch++; return super.beginBatchEdit();
                }
                @Override public boolean endBatchEdit() {
                    if (!valid()) return false;
                    boolean result = super.endBatchEdit();
                    batch = Math.max(0, batch - 1); publish(); return result;
                }
                @Override public boolean setComposingText(CharSequence text, int cursor) {
                    if (!valid()) return false;
                    int oldLength = editor.length();
                    String oldText = editor.getText().toString();
                    boolean result = super.setComposingText(text, cursor);
                    // Some keyboards implement Backspace by shortening the
                    // composing span rather than deleteSurroundingText.
                    if (oldText.startsWith(editor.getText().toString())) explicitDeletion(oldLength);
                    publish(); return result;
                }
                @Override public boolean commitText(CharSequence text, int cursor) {
                    if (!valid()) return false;
                    boolean result = super.commitText(text, cursor); publish(); return result;
                }
                @Override public boolean finishComposingText() {
                    if (!valid()) return false;
                    boolean result = super.finishComposingText(); publish(); return result;
                }
                @Override public boolean setComposingRegion(int start, int end) {
                    if (!valid()) return false;
                    boolean result = super.setComposingRegion(start, end); publish(); return result;
                }
                @Override public boolean deleteSurroundingText(int before, int after) {
                    if (!valid()) return false;
                    int missing = Math.max(0, before - Math.max(0, editor.getSelectionStart()));
                    int oldLength = editor.length();
                    boolean result = super.deleteSurroundingText(before, after); explicitDeletion(oldLength); publish();
                    for (int i = 0; i < missing; i++) emit("", lastPreview, KeyEvent.KEYCODE_DEL);
                    return result;
                }
                @Override public boolean deleteSurroundingTextInCodePoints(int before, int after) {
                    if (!valid()) return false;
                    int position = Math.max(0, editor.getSelectionStart());
                    int missing = Math.max(0, before - Character.codePointCount(editor.getText(), 0, position));
                    int oldLength = editor.length();
                    boolean result = super.deleteSurroundingTextInCodePoints(before, after); explicitDeletion(oldLength); publish();
                    for (int i = 0; i < missing; i++) emit("", lastPreview, KeyEvent.KEYCODE_DEL);
                    return result;
                }
                @Override public boolean performEditorAction(int action) {
                    if (!valid()) return false;
                    finish(); emit("", "", KeyEvent.KEYCODE_ENTER); return true;
                }
                @Override public boolean sendKeyEvent(KeyEvent event) {
                    if (!valid()) return false;
                    return super.sendKeyEvent(event);
                }
            };
        }

        @Override public boolean onKeyDown(int code, KeyEvent event) {
            if (!active) return super.onKeyDown(code, event);
            int modifiers = (event.isCtrlPressed() ? 1 : 0) | (event.isAltPressed() ? 2 : 0)
                | (event.isShiftPressed() ? 4 : 0) | (event.isMetaPressed() ? 8 : 0);
            if (!KeyEvent.isModifierKey(code)
                && (event.isCtrlPressed() || event.isAltPressed() || event.isMetaPressed())) {
                finish();
                emit("", "", code, modifiers, event.getUnicodeChar(0));
                return true;
            }
            if (code == KeyEvent.KEYCODE_DEL && length() > 0) {
                int oldLength = length();
                boolean result = super.onKeyDown(code, event); explicitDeletion(oldLength); publish(); return result;
            }
            if (code == KeyEvent.KEYCODE_DEL || code == KeyEvent.KEYCODE_ENTER
                || code == KeyEvent.KEYCODE_ESCAPE || code == KeyEvent.KEYCODE_TAB
                || (code >= KeyEvent.KEYCODE_DPAD_UP && code <= KeyEvent.KEYCODE_DPAD_RIGHT)) {
                // IMEs such as SwiftKey send Shift+arrows as real key chords.
                // Keep Shift here too; it is not a Ctrl/Alt/Meta shortcut above.
                finish(); emit("", "", code, modifiers, 0); return true;
            }
            return super.onKeyDown(code, event);
        }
    }
}
