package com.graffitty.ui;

import android.app.Activity;
import android.content.res.ColorStateList;
import android.graphics.drawable.Drawable;
import android.os.Build;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewConfiguration;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;
import java.lang.reflect.Method;

/**
 * OS adapter only: Android's own selection handles, Copy toolbar and clipboard
 * over Godot's read-only text.
 *
 * The view never scrolls or stretches by itself. A vertical finger drag is
 * reported to Godot, whose shared rubber band (Rust) answers with the offset
 * and pull to draw, so dialog text moves exactly like every other list.
 * All methods may be called from any thread.
 */
public final class NativeSelectableText {
    private final Activity activity;
    private final long receiver;
    private final Method callback;
    private Frame frame;
    private TextView label;
    private String text = "";
    private boolean disposed;

    public NativeSelectableText(Activity activity, long receiver, int accent) throws Exception {
        this.activity = activity;
        this.receiver = receiver;
        callback = Class.forName("org.godotengine.godot.GodotLib")
            .getMethod("calldeferred", long.class, String.class, Object[].class);
        activity.runOnUiThread(() -> create(accent));
    }

    private void notifyGodot(String method, Object... args) {
        if (disposed) return;
        try { callback.invoke(null, receiver, method, args); }
        catch (Exception error) { throw new IllegalStateException("Native text callback", error); }
    }

    private void create(int accent) {
        if (disposed) return;
        frame = new Frame();
        frame.setClipChildren(true);
        frame.setVisibility(View.GONE);
        label = new TextView(activity);
        label.setTextIsSelectable(true);
        label.setPadding(0, 0, 0, 0);
        label.setHighlightColor((accent & 0x00ffffff) | 0x59000000);
        if (Build.VERSION.SDK_INT >= 29) {
            for (Drawable handle : new Drawable[]{label.getTextSelectHandle(), label.getTextSelectHandleLeft(), label.getTextSelectHandleRight()}) {
                if (handle != null) handle.mutate().setTintList(ColorStateList.valueOf(accent));
            }
        }
        label.addOnLayoutChangeListener((view, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom) -> {
            if (bottom - top != oldBottom - oldTop) notifyGodot("_native_content_height", bottom - top);
        });
        frame.addView(label, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        View surface = activity.getWindow().getDecorView().findViewById(android.R.id.content);
        ((ViewGroup) surface).addView(frame, new FrameLayout.LayoutParams(1, 1));
    }

    /** Place the view in surface pixels and show this text, leaving `trailing`
     *  pixels free on the right for the overlay scrollbar Godot draws. */
    public void update(int x, int y, int width, int height, int trailing, String content, float size, int color, boolean visible) {
        activity.runOnUiThread(() -> {
            if (disposed || frame == null) return;
            if (!visible) {
                label.clearFocus();
                frame.setVisibility(View.GONE); // GONE also closes contextual selection.
                return;
            }
            FrameLayout.LayoutParams params = (FrameLayout.LayoutParams) frame.getLayoutParams();
            if (params.width != width || params.height != height) {
                params.width = width;
                params.height = height;
                frame.setLayoutParams(params);
            }
            frame.setX(x);
            frame.setY(y);
            if (label.getPaddingRight() != trailing) label.setPadding(0, 0, trailing, 0);
            label.setTextSize(android.util.TypedValue.COMPLEX_UNIT_PX, size);
            label.setTextColor(color);
            if (!text.equals(content)) {
                text = content;
                label.setText(content);
            }
            frame.setVisibility(View.VISIBLE);
        });
    }

    /** Draw the text scrolled by `offset` and pulled by `stretch`, in surface pixels. */
    public void scroll(float offset, float stretch) {
        activity.runOnUiThread(() -> {
            if (!disposed && label != null) label.setTranslationY(-(offset + stretch));
        });
    }

    public void dispose() {
        activity.runOnUiThread(() -> {
            disposed = true;
            if (frame != null && frame.getParent() != null) ((ViewGroup) frame.getParent()).removeView(frame);
        });
    }

    /** Reports vertical drags instead of letting the text scroll itself. */
    private final class Frame extends FrameLayout {
        private final int slop = ViewConfiguration.get(activity).getScaledTouchSlop();
        private final long longPress = ViewConfiguration.getLongPressTimeout();
        private float startX;
        private float startY;
        private float lastY;
        private long downAt = -1;
        private boolean dragging;

        Frame() { super(activity); }

        // FrameLayout caps a child's height at its own, which would cut the
        // text off; it must be as tall as its text so it can scroll.
        @Override protected void measureChildWithMargins(View child, int widthSpec, int widthUsed, int heightSpec, int heightUsed) {
            super.measureChildWithMargins(child, widthSpec, widthUsed, MeasureSpec.makeMeasureSpec(0, MeasureSpec.UNSPECIFIED), heightUsed);
        }

        // Events reach `track` through the intercept while the text is the touch
        // target, or through onTouchEvent when the finger landed beside it.
        @Override public boolean onInterceptTouchEvent(MotionEvent event) { return track(event); }

        @Override public boolean onTouchEvent(MotionEvent event) {
            track(event);
            return true;
        }

        /** Returns whether this frame now owns the gesture as a scroll. */
        private boolean track(MotionEvent event) {
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    if (event.getDownTime() == downAt) return false; // Seen through the intercept.
                    startX = event.getX();
                    startY = lastY = event.getY();
                    downAt = event.getDownTime();
                    dragging = false;
                    // A finger on gliding text stops it.
                    notifyGodot("_native_touch", "down", 0.0f);
                    return false;
                case MotionEvent.ACTION_MOVE: {
                    if (dragging) {
                        notifyGodot("_native_touch", "move", event.getY() - lastY);
                        lastY = event.getY();
                        return true;
                    }
                    float dx = event.getX() - startX;
                    float dy = event.getY() - startY;
                    // After a long press the finger extends the selection instead.
                    boolean held = event.getEventTime() - downAt >= longPress;
                    if (held || Math.abs(dy) <= slop || Math.abs(dy) <= Math.abs(dx)) return false;
                    dragging = true;
                    // Start from the slop edge so crossing it does not jump.
                    lastY = startY + Math.signum(dy) * slop;
                    notifyGodot("_native_touch", "move", event.getY() - lastY);
                    lastY = event.getY();
                    getParent().requestDisallowInterceptTouchEvent(true);
                    return true;
                }
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL: {
                    boolean owned = dragging;
                    dragging = false;
                    if (downAt != -1) notifyGodot("_native_touch", event.getActionMasked() == MotionEvent.ACTION_UP ? "up" : "cancel", 0.0f);
                    downAt = -1;
                    return owned;
                }
                default:
                    return dragging;
            }
        }
    }
}
