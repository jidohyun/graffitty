// AVAudioSession policy only; CPAL owns RemoteIO and Rust owns capture/resampling.
// Every call except the permission probe runs on the dictation worker thread.
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include <stdatomic.h>
#include <stdint.h>

static atomic_bool requested = false;

// One object per recording. Interruption state lives here, not in globals, so a late
// notification for a finished recording can never fail the next one.
@interface GFTAudioSession : NSObject {
@public
    atomic_int interrupted;
}
@property(nonatomic, strong) NSString *category;
@property(nonatomic, strong) NSString *mode;
@property(nonatomic) AVAudioSessionCategoryOptions options;
@property(nonatomic, strong) id observer;
@end
@implementation GFTAudioSession
@end

// 1 granted, -1 denied, 0 pending. Never wait on the UI thread.
int gft_ios_microphone_permission(void) {
    @autoreleasepool {
        // AVAudioApplication is iOS 17+; iOS 16 has only the AVAudioSession API.
        void (^done)(BOOL) = ^(BOOL granted) {
            (void)granted; // The worker reads the system's permission state.
            atomic_store(&requested, false);
        };
        if (@available(iOS 17.0, *)) {
            switch (AVAudioApplication.sharedInstance.recordPermission) {
                case AVAudioApplicationRecordPermissionGranted: return 1;
                case AVAudioApplicationRecordPermissionDenied: return -1;
                default: break;
            }
            if (!atomic_exchange(&requested, true)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [AVAudioApplication requestRecordPermissionWithCompletionHandler:done];
                });
            }
            return 0;
        }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVAudioSession *session = AVAudioSession.sharedInstance;
        switch (session.recordPermission) {
            case AVAudioSessionRecordPermissionGranted: return 1;
            case AVAudioSessionRecordPermissionDenied: return -1;
            default: break;
        }
        if (!atomic_exchange(&requested, true)) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [session requestRecordPermission:done];
            });
        }
#pragma clang diagnostic pop
        return 0;
    }
}

// Returns an owned session handle, or NULL with the NSError code in *failure.
// The interruption observer exists before activation so no early event is missed.
void *gft_ios_audio_begin(int64_t *failure) {
    @autoreleasepool {
        AVAudioSession *session = AVAudioSession.sharedInstance;
        GFTAudioSession *state = [GFTAudioSession new];
        atomic_init(&state->interrupted, 0);
        state.category = session.category;
        state.mode = session.mode;
        state.options = session.categoryOptions;
        __weak GFTAudioSession *weak = state;
        state.observer = [NSNotificationCenter.defaultCenter
            addObserverForName:AVAudioSessionInterruptionNotification object:session queue:nil
            usingBlock:^(NSNotification *notification) {
                GFTAudioSession *current = weak;
                if (current && [notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue]
                        == AVAudioSessionInterruptionTypeBegan) {
                    atomic_store(&current->interrupted, 1);
                }
            }];
        NSError *error = nil;
        // AllowBluetooth is the iOS 16–25 spelling; AllowBluetoothHFP requires iOS 26.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        BOOL ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                                 mode:AVAudioSessionModeMeasurement
                              options:AVAudioSessionCategoryOptionDefaultToSpeaker | AVAudioSessionCategoryOptionAllowBluetooth
                                error:&error];
#pragma clang diagnostic pop
        ok = ok && [session setActive:YES error:&error];
        if (!ok) {
            if (failure) *failure = error ? (int64_t)error.code : -1;
            [NSNotificationCenter.defaultCenter removeObserver:state.observer];
            state.observer = nil;
            [session setCategory:state.category mode:state.mode options:state.options error:nil];
            return NULL;
        }
        return (__bridge_retained void *)state;
    }
}

// 1 once an interruption has begun. It is never cleared: resuming would splice speech.
int gft_ios_audio_interrupted(void *opaque) {
    GFTAudioSession *state = (__bridge GFTAudioSession *)opaque;
    return atomic_load(&state->interrupted);
}

// Called only after CPAL has disposed the input stream. Consumes the handle.
void gft_ios_audio_end(void *opaque) {
    @autoreleasepool {
        GFTAudioSession *state = (__bridge_transfer GFTAudioSession *)opaque;
        [NSNotificationCenter.defaultCenter removeObserver:state.observer];
        state.observer = nil;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
        [session setCategory:state.category mode:state.mode options:state.options error:nil];
    }
}
