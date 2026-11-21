#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <stdlib.h>
#include <string.h>
static NSString *typeFor(const char *mime) {
    NSString *name = [NSString stringWithUTF8String:mime];
    if (!name)
        return nil;
    if ([name isEqualToString:@"text/plain"])
        return NSPasteboardTypeString;
    UTType *type = [UTType typeWithMIMEType:name];
    return type.identifier ?: name;
}
extern "C" void graffitty_clipboard_clear() {
    @autoreleasepool {
        [[NSPasteboard generalPasteboard] clearContents];
    }
}
extern "C" bool graffitty_clipboard_set(const char *mime, const unsigned char *data, size_t size) {
    @autoreleasepool {
        NSString *type = typeFor(mime);
        if (!type)
            return false;
        NSPasteboard *p = [NSPasteboard generalPasteboard];
        [p addTypes:@[ type ] owner:nil];
        return [p setData:[NSData dataWithBytes:data length:size] forType:type];
    }
}
extern "C" unsigned char *graffitty_clipboard_get(const char *mime, size_t *size) {
    @autoreleasepool {
        NSData *data;
        NSPasteboard *p = [NSPasteboard generalPasteboard];
        if (strcmp(mime, ".") == 0) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSString *type in p.types) {
                NSString *name = [UTType typeWithIdentifier:type].preferredMIMEType;
                if (!name && [type containsString:@"/"])
                    name = type;
                if (name && ![names containsObject:name])
                    [names addObject:name];
            }
            data = [[names componentsJoinedByString:@" "] dataUsingEncoding:NSUTF8StringEncoding];
        } else
            data = [p dataForType:typeFor(mime)];
        if (!data || data.length > 64 * 1024 * 1024) {
            *size = 0;
            return nullptr;
        }
        *size = data.length;
        auto *result = (unsigned char *)malloc((data.length ? data.length : 1));
        if (result && data.length)
            memcpy(result, data.bytes, data.length);
        return result;
    }
}
extern "C" void graffitty_clipboard_free(void *data) { free(data); }
