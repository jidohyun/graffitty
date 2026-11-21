package com.graffitty.input;

import android.app.Activity;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.View;
import android.view.ViewGroup;
import java.lang.reflect.Method;
import java.util.WeakHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

/** Finish an in-flight Vulkan frame before Android releases its native surface. */
final class RenderSurfaceLifecycle {
    private static final WeakHashMap<SurfaceView, Boolean> installed = new WeakHashMap<>();

    static void install(Activity activity) {
        activity.runOnUiThread(() -> visit(activity.getWindow().getDecorView()));
    }

    private static void visit(View view) {
        if (view instanceof SurfaceView
                && view.getClass().getName().equals("org.godotengine.godot.GodotVulkanRenderView")) {
            SurfaceView surface = (SurfaceView) view;
            if (installed.containsKey(surface)) return;
            try {
                Method queue = Class.forName("org.godotengine.godot.vulkan.VkSurfaceView")
                    .getMethod("queueOnVkThread", Runnable.class);
                surface.getHolder().addCallback(new SurfaceHolder.Callback() {
                    public void surfaceCreated(SurfaceHolder holder) {}
                    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {}
                    public void surfaceDestroyed(SurfaceHolder holder) {
                        // Godot's earlier callback stops new frames, but returns
                        // while a frame outside its lifecycle lock can still be
                        // presenting. Android keeps the Surface valid until all
                        // callbacks return. Its render queue runs even paused.
                        CountDownLatch finished = new CountDownLatch(1);
                        try {
                            queue.invoke(surface, (Runnable) finished::countDown);
                            if (!finished.await(2, TimeUnit.SECONDS))
                                Log.e("GraffittySurface", "ERROR: render thread did not release the surface in time");
                        } catch (InterruptedException error) {
                            Thread.currentThread().interrupt();
                            Log.e("GraffittySurface", "ERROR: interrupted surface release", error);
                        } catch (ReflectiveOperationException error) {
                            Log.e("GraffittySurface", "ERROR: cannot synchronize surface release", error);
                        }
                    }
                });
                installed.put(surface, true);
            } catch (ReflectiveOperationException error) {
                Log.e("GraffittySurface", "ERROR: Vulkan lifecycle bridge unavailable", error);
            }
        }
        if (view instanceof ViewGroup) {
            ViewGroup group = (ViewGroup) view;
            for (int index = 0; index < group.getChildCount(); index++) visit(group.getChildAt(index));
        }
    }
}
