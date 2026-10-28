// System-wide now-playing bridge for the notch app.
//
// Since macOS 15.4 the private MediaRemote framework only answers Apple-signed
// processes, so this dylib is loaded into /usr/bin/perl (see stream.pl), which
// runs as `com.apple.perl`. The notch app spawns that perl process and talks to it:
//   stdout: one JSON object per line describing the current now-playing state
//   stdin : one command per line: play | pause | toggle | next | prev | stop | seek <seconds>
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <stdio.h>

typedef void (^MRInfoBlock)(CFDictionaryRef info);
typedef void (^MRBoolBlock)(Boolean value);
typedef void (^MRClientBlock)(id client);

static void (*MRRegister)(dispatch_queue_t);
static void (*MRGetInfo)(dispatch_queue_t, MRInfoBlock);
static void (*MRGetIsPlaying)(dispatch_queue_t, MRBoolBlock);
static void (*MRGetClient)(dispatch_queue_t, MRClientBlock);
static Boolean (*MRSendCommand)(int, id);
static void (*MRSetElapsed)(double);
static CFStringRef (*MRClientBundleID)(id);
static CFStringRef (*MRClientParentBundleID)(id);

static NSData *gLastArtwork;
static dispatch_queue_t gQueue;
static dispatch_source_t gDebounce;
static dispatch_source_t gPoll;

static void emit(NSDictionary *obj) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data) return;
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static void refresh(void) {
    MRGetInfo(gQueue, ^(CFDictionaryRef cfInfo) {
        NSDictionary *info = (__bridge NSDictionary *)cfInfo;
        MRGetIsPlaying(gQueue, ^(Boolean playing) {
            MRGetClient(gQueue, ^(id client) {
                NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                if (!title.length && !client) {
                    gLastArtwork = nil;
                    emit(@{@"empty": @YES});
                    return;
                }
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"title"] = title ?: @"";
                out[@"artist"] = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
                out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
                out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
                out[@"elapsed"] = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] ?: @0;
                NSNumber *rate = info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
                out[@"rate"] = rate ?: @(playing ? 1 : 0);
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = @(ts ? ts.timeIntervalSince1970 : [NSDate date].timeIntervalSince1970);
                out[@"playing"] = @(playing);
                NSString *bid = client && MRClientBundleID ? (__bridge NSString *)MRClientBundleID(client) : nil;
                NSString *parent = client && MRClientParentBundleID ? (__bridge NSString *)MRClientParentBundleID(client) : nil;
                out[@"bundleId"] = bid ?: @"";
                out[@"parentBundleId"] = parent ?: @"";

                // Artwork is only sent when it changed ("" = cleared) to keep the pipe small.
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if (![art isKindOfClass:[NSData class]]) art = nil;
                BOOL changed = (art == nil) != (gLastArtwork == nil) || (art && ![art isEqualToData:gLastArtwork]);
                if (changed) {
                    gLastArtwork = art;
                    out[@"artwork"] = art ? [art base64EncodedStringWithOptions:0] : @"";
                }
                emit(out);
            });
        });
    });
}

static void scheduleRefresh(void) {
    dispatch_source_set_timer(gDebounce, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_MSEC),
                              DISPATCH_TIME_FOREVER, 5 * NSEC_PER_MSEC);
}

static void handleCommand(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    NSString *cmd = parts.firstObject;
    if ([cmd isEqualToString:@"play"]) MRSendCommand(0, nil);
    else if ([cmd isEqualToString:@"pause"]) MRSendCommand(1, nil);
    else if ([cmd isEqualToString:@"toggle"]) MRSendCommand(2, nil);
    else if ([cmd isEqualToString:@"stop"]) MRSendCommand(3, nil);
    else if ([cmd isEqualToString:@"next"]) MRSendCommand(4, nil);
    else if ([cmd isEqualToString:@"prev"]) MRSendCommand(5, nil);
    else if ([cmd isEqualToString:@"seek"] && parts.count > 1) MRSetElapsed([parts[1] doubleValue]);
    scheduleRefresh();
}

// Entry point invoked from perl through DynaLoader. Never returns.
void dynamicnotch_stream(void *interp, void *cv) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(@{@"error": @"cannot load MediaRemote"}); exit(2); }
        MRRegister = dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        MRGetInfo = dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        MRGetIsPlaying = dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        MRGetClient = dlsym(h, "MRMediaRemoteGetNowPlayingClient");
        MRSendCommand = dlsym(h, "MRMediaRemoteSendCommand");
        MRSetElapsed = dlsym(h, "MRMediaRemoteSetElapsedTime");
        MRClientBundleID = dlsym(h, "MRNowPlayingClientGetBundleIdentifier");
        MRClientParentBundleID = dlsym(h, "MRNowPlayingClientGetParentAppBundleIdentifier");
        if (!MRRegister || !MRGetInfo || !MRGetIsPlaying || !MRGetClient || !MRSendCommand || !MRSetElapsed) {
            emit(@{@"error": @"missing MediaRemote symbols"});
            exit(3);
        }

        gQueue = dispatch_queue_create("dynamicnotch.mediaremote", DISPATCH_QUEUE_SERIAL);
        gDebounce = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_event_handler(gDebounce, ^{ refresh(); });
        dispatch_resume(gDebounce);

        // Safety net: if a future macOS renames the notifications, polling keeps the state fresh.
        gPoll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_timer(gPoll, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), 4 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(gPoll, ^{ refresh(); });
        dispatch_resume(gPoll);

        MRRegister(gQueue);
        NSArray *names = @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingPlaybackQueueChangedNotification",
        ];
        for (NSString *n in names) {
            [[NSNotificationCenter defaultCenter] addObserverForName:n object:nil queue:nil
                                                          usingBlock:^(NSNotification *note) { scheduleRefresh(); }];
        }

        // When the parent app dies stdin closes and this process exits with it.
        [NSThread detachNewThreadWithBlock:^{
            char buf[256];
            while (fgets(buf, sizeof buf, stdin)) {
                NSString *line = [[NSString stringWithUTF8String:buf]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (line.length) dispatch_async(gQueue, ^{ handleCommand(line); });
            }
            exit(0);
        }];

        scheduleRefresh();
        [[NSRunLoop mainRunLoop] run];
    }
}
