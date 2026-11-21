package com.graffitty.ime_test;

/** Disposable content URI for real InputConnection image delivery; no OS clipboard access. */
public final class ImageProvider extends android.content.ContentProvider {
    public static final String PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
    @Override public boolean onCreate() { return true; }
    @Override public String getType(android.net.Uri uri) { return "image/png"; }
    @Override public android.os.ParcelFileDescriptor openFile(android.net.Uri uri, String mode) throws java.io.FileNotFoundException {
        if (!mode.equals("r")) throw new java.io.FileNotFoundException("Read only");
        java.io.File file = new java.io.File(getContext().getCacheDir(), "ime-image.png");
        try (java.io.FileOutputStream output = new java.io.FileOutputStream(file)) {
            output.write(android.util.Base64.decode(PNG, android.util.Base64.DEFAULT));
        } catch (java.io.IOException error) { throw new java.io.FileNotFoundException(error.toString()); }
        return android.os.ParcelFileDescriptor.open(file, android.os.ParcelFileDescriptor.MODE_READ_ONLY);
    }
    @Override public android.database.Cursor query(android.net.Uri u, String[] p, String s, String[] a, String o) { return null; }
    @Override public android.net.Uri insert(android.net.Uri u, android.content.ContentValues v) { throw new UnsupportedOperationException(); }
    @Override public int update(android.net.Uri u, android.content.ContentValues v, String s, String[] a) { throw new UnsupportedOperationException(); }
    @Override public int delete(android.net.Uri u, String s, String[] a) { throw new UnsupportedOperationException(); }
}
