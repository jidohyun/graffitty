package com.graffitty.launch;

import android.app.Activity;
import android.app.Application;
import android.os.Bundle;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.ImageView;
import java.lang.ref.WeakReference;

/** Own the textured launch screen: Android's system splash only supports a solid color. */
public final class GraffittyApplication extends Application implements Application.ActivityLifecycleCallbacks {
    private static WeakReference<FrameLayout> cover = new WeakReference<>(null);

    @Override public void onCreate() {
        super.onCreate();
        registerActivityLifecycleCallbacks(this);
    }

    @Override public void onActivityCreated(Activity activity, Bundle state) {
        if (!activity.getClass().getName().equals("com.godot.game.GodotApp")) return;
        // Install before the first window traversal. Posting this allowed one
        // black engine/window frame to be presented before the wall.
        showLaunch(activity);
    }

    private void showLaunch(Activity activity) {
        String resourcePackage = getResources().getResourcePackageName(getApplicationInfo().icon);
        FrameLayout layout = new FrameLayout(activity);
        ImageView wall = new ImageView(activity);
        wall.setImageResource(getResources().getIdentifier("icon_background", "mipmap", resourcePackage));
        wall.setScaleType(ImageView.ScaleType.FIT_XY);
        layout.addView(wall, new FrameLayout.LayoutParams(-1, -1));
        ImageView logo = new ImageView(activity);
        logo.setImageResource(getResources().getIdentifier("splash_icon", "drawable", resourcePackage));
        logo.setScaleType(ImageView.ScaleType.FIT_CENTER);
        int size = Math.round(288 * getResources().getDisplayMetrics().density);
        layout.addView(logo, new FrameLayout.LayoutParams(size, size, Gravity.CENTER));
        layout.setImportantForAccessibility(android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO_HIDE_DESCENDANTS);
        ((ViewGroup) activity.getWindow().getDecorView()).addView(layout, new ViewGroup.LayoutParams(-1, -1));
        cover = new WeakReference<>(layout);
    }

    /** Called after Godot has drawn its first application frame. No artificial delay. */
    public static void finishLaunch() {
        new Handler(Looper.getMainLooper()).post(() -> {
            FrameLayout layout = cover.get();
            if (layout != null && layout.getParent() instanceof ViewGroup) {
                // The API 31+ launch theme suppresses the system color splash
                // through translucency. Restore real activity opacity as well
                // as the theme, so Android can stop windows behind this app.
                if (Build.VERSION.SDK_INT >= 31)
                    ((Activity) layout.getContext()).setTranslucent(false);
                ((ViewGroup) layout.getParent()).removeView(layout);
            }
            cover.clear();
        });
    }

    @Override public void onActivityDestroyed(Activity activity) { }
    @Override public void onActivityStarted(Activity activity) { }
    @Override public void onActivityResumed(Activity activity) { }
    @Override public void onActivityPaused(Activity activity) { }
    @Override public void onActivityStopped(Activity activity) { }
    @Override public void onActivitySaveInstanceState(Activity activity, Bundle state) { }
}
