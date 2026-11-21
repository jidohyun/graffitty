// AppKit adapter for the NSServices declaration in the application bundle.
#import <AppKit/AppKit.h>

@interface GraffittyFolderService : NSObject
@property(nonatomic, strong) NSURL *launcher;
@end

@implementation GraffittyFolderService
- (void)openFolders:(NSPasteboard *)pasteboard
          userData:(NSString *)userData
             error:(NSString **)error {
    NSArray<NSURL *> *urls = [pasteboard readObjectsForClasses:@[[NSURL class]]
        options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
    NSMutableSet<NSString *> *opened = [NSMutableSet set];
    for (NSURL *url in urls) {
        BOOL directory = NO;
        NSString *path = url.path;
        if (!url.isFileURL || ![[NSFileManager defaultManager] fileExistsAtPath:path
            isDirectory:&directory] || !directory || [opened containsObject:path]) continue;
        [opened addObject:path];
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = self.launcher;
        // No shell interpolation: filenames (including newlines) remain one argument.
        task.arguments = @[[NSString stringWithFormat:@"--cwd=%@", path]];
        task.currentDirectoryURL = [NSURL fileURLWithPath:@"/" isDirectory:YES];
        task.standardInput = [NSFileHandle fileHandleWithNullDevice];
        task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
        task.standardError = [NSFileHandle fileHandleWithNullDevice];
        NSError *failure = nil;
        if (![task launchAndReturnError:&failure] && error) *error = failure.localizedDescription;
    }
}
@end

extern "C" void graffitty_install_folder_services() {
    NSBundle *bundle = [NSBundle mainBundle];
    // Development/editor processes must not register themselves as the installed app.
    if (![bundle.bundleIdentifier isEqualToString:@"dev.graffitty.terminal"]) return;
    static GraffittyFolderService *provider;
    if (provider) return;
    provider = [[GraffittyFolderService alloc] init];
    provider.launcher = [bundle.bundleURL URLByAppendingPathComponent:@"Contents/MacOS/Graffitty"];
    [NSApp setServicesProvider:provider];
    NSUpdateDynamicServices();
}
