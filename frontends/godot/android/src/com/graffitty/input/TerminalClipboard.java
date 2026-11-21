package com.graffitty.input;

import android.app.Activity;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.net.Uri;
import android.util.Base64;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import org.json.JSONObject;

/** OS adapter only. Image validation, normalization and delivery live in Rust. */
public final class TerminalClipboard {
    private static final int LIMIT = 32 * 1024 * 1024;
    private TerminalClipboard() {}

    public static String read(Activity activity) {
        try {
            ClipboardManager clipboard = (ClipboardManager) activity.getSystemService(Context.CLIPBOARD_SERVICE);
            ClipData clip = clipboard.getPrimaryClip();
            if (clip == null || clip.getItemCount() == 0) return "{}";
            ClipData.Item item = clip.getItemAt(0);
            Uri uri = item.getUri();
            if (uri != null) {
                String mime = activity.getContentResolver().getType(uri);
                if ((mime != null && mime.startsWith("image/")) || clip.getDescription().hasMimeType("image/*"))
                    return image(activity, uri);
            }
            // Do not coerce a content URI into text: it only exists on this device.
            CharSequence text = item.getText();
            return text == null ? "{}" : new JSONObject().put("text", text.toString()).toString();
        } catch (Exception error) { return failure(error); }
    }

    public static String image(Activity activity, Uri uri) {
        try {
            if (uri == null || !"content".equals(uri.getScheme())) throw new IllegalArgumentException("Expected an image content URI");
            try (InputStream input = activity.getContentResolver().openInputStream(uri)) {
                if (input == null) throw new IllegalArgumentException("Cannot open clipboard image");
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] block = new byte[16384];
                int count;
                while ((count = input.read(block)) != -1) {
                    if (count > LIMIT - bytes.size()) throw new IllegalArgumentException("Image exceeds the 32 MiB upload limit");
                    bytes.write(block, 0, count);
                }
                return new JSONObject().put("image", Base64.encodeToString(bytes.toByteArray(), Base64.NO_WRAP)).toString();
            }
        } catch (Exception error) { return failure(error); }
    }

    static String failure(Exception error) {
        try { return new JSONObject().put("error", error.toString()).toString(); }
        catch (Exception ignored) { return "{\"error\":\"Cannot read image\"}"; }
    }
}
