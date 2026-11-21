#import <UIKit/UIKit.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// Invoked from an explicit user paste on Godot's main thread. UIPasteboard
// retains iOS's native paste-consent behavior; there is no background polling.
unsigned char *graffitty_ios_clipboard_image(size_t *size) {
    @autoreleasepool {
        *size = 0;
        UIPasteboard *board = UIPasteboard.generalPasteboard;
        if (!board.hasImages) return NULL;
        NSData *data = [board dataForPasteboardType:@"public.png"];
        if (!data) data = [board dataForPasteboardType:@"public.jpeg"];
        if (!data) {
            UIImage *image = board.image;
            if (image) data = UIImagePNGRepresentation(image);
        }
        if (!data || data.length > 32 * 1024 * 1024) { *size = SIZE_MAX; return NULL; }
        unsigned char *bytes = malloc(data.length ?: 1);
        if (!bytes) { *size = SIZE_MAX; return NULL; }
        memcpy(bytes, data.bytes, data.length);
        *size = data.length;
        return bytes;
    }
}
void graffitty_ios_clipboard_free(unsigned char *data) { free(data); }
