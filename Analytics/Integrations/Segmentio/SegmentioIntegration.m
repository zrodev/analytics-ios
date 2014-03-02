// SegmentioIntegration.m
// Copyright (c) 2014 Segment.io. All rights reserved.

#include <sys/sysctl.h>

#import <UIKit/UIKit.h>
#import <CoreTelephony/CTCarrier.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import "Analytics.h"
#import "AnalyticsUtils.h"
#import "AnalyticsRequest.h"
#import "SegmentioIntegration.h"

#define SEGMENTIO_API_URL [NSURL URLWithString:@"https://api.segment.io/v1/import"]
#define SEGMENTIO_MAX_BATCH_SIZE 100
#define DISK_ANONYMOUS_ID_URL AnalyticsURLForFilename(@"segmentio.anonymousId")
#define DISK_USER_ID_URL AnalyticsURLForFilename(@"segmentio.userId")
#define DISK_QUEUE_URL AnalyticsURLForFilename(@"segmentio.queue.plist")
#define DISK_TRAITS_URL AnalyticsURLForFilename(@"segmentio.traits.plist")

NSString *const SegmentioDidSendRequestNotification = @"SegmentioDidSendRequest";
NSString *const SegmentioRequestDidSucceedNotification = @"SegmentioRequestDidSucceed";
NSString *const SegmentioRequestDidFailNotification = @"SegmentioRequestDidFail";

static NSString *GenerateUUIDString() {
    CFUUIDRef theUUID = CFUUIDCreate(NULL);
    NSString *UUIDString = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, theUUID);
    CFRelease(theUUID);
    return UUIDString;
}

static NSString *GetAnonymousId(BOOL reset) {
    // We've chosen to generate a UUID rather than use the UDID (deprecated in iOS 5),
    // identifierForVendor (iOS6 and later, can't be changed on logout),
    // or MAC address (blocked in iOS 7). For more info see https://segment.io/libraries/ios#ids
    NSURL *url = DISK_ANONYMOUS_ID_URL;
    NSString *anonymousId = [[NSString alloc] initWithContentsOfURL:url encoding:NSUTF8StringEncoding error:NULL];
    if (!anonymousId || reset) {
        anonymousId = GenerateUUIDString();
        SOLog(@"New anonymousId: %@", anonymousId);
        [anonymousId writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }
    return anonymousId;
}

static NSString *GetDeviceModel() {
    size_t size;
    sysctlbyname("hw.machine", NULL, &size, NULL, 0);
    char result[size];
    sysctlbyname("hw.machine", result, &size, NULL, 0);
    NSString *results = [NSString stringWithCString:result encoding:NSUTF8StringEncoding];
    return results;
}

static NSString *GetIdForAdvertiser() {
    if (NSClassFromString(@"ASIdentifierManager")) {
        NSString* idForAdvertiser = nil;
        Class ASIdentifierManagerClass = NSClassFromString(@"ASIdentifierManager");
        if (ASIdentifierManagerClass) {
            SEL sharedManagerSelector = NSSelectorFromString(@"sharedManager");
            id sharedManager = ((id (*)(id, SEL))[ASIdentifierManagerClass methodForSelector:sharedManagerSelector])(ASIdentifierManagerClass, sharedManagerSelector);
            SEL advertisingIdentifierSelector = NSSelectorFromString(@"advertisingIdentifier");
            NSUUID *uuid = ((NSUUID* (*)(id, SEL))[sharedManager methodForSelector:advertisingIdentifierSelector])(sharedManager, advertisingIdentifierSelector);
            idForAdvertiser = [uuid UUIDString];
        }
        return idForAdvertiser;
    }
    else {
        return nil;
    }
}

static NSMutableDictionary *BuildStaticContext() {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    
    // Library
    NSMutableDictionary *library = [NSMutableDictionary dictionary];
    [library setObject:@"analytics-ios" forKey:@"name"];
    [library setObject:NSStringize(ANALYTICS_VERSION) forKey:@"version"];
    [context setObject:library forKey:@"library"];
    
    // App
    NSDictionary *bundle = [[NSBundle mainBundle] infoDictionary];
    if (bundle.count) {
        NSMutableDictionary *app = [NSMutableDictionary dictionary];
        [app setObject:[bundle objectForKey:@"CFBundleDisplayName"] forKey:@"name"];
        [app setObject:[bundle objectForKey:@"CFBundleShortVersionString"] forKey:@"version"];
        [app setObject:[bundle objectForKey:@"CFBundleVersion"] forKey:@"build"];
        [context setObject:app forKey:@"app"];
    }
    
    // Device
    UIDevice *uiDevice = [UIDevice currentDevice];
    NSMutableDictionary *device = [NSMutableDictionary dictionary];
    [device setObject:@"Apple" forKey:@"manufacturer"];
    [device setObject:GetDeviceModel() forKey:@"model"];
    [device setObject:[[uiDevice identifierForVendor] UUIDString] forKey:@"idfv"];
    [device setObject:GetIdForAdvertiser() forKey:@"idfa"];
    [context setObject:device forKey:@"device"];
    
    // OS
    NSMutableDictionary *os = [NSMutableDictionary dictionary];
    [os setObject:[uiDevice systemName] forKey:@"name"];
    [os setObject:[uiDevice systemVersion] forKey:@"version"];
    [context setObject:os forKey:@"os"];
    
    // Telephony
    CTTelephonyNetworkInfo *networkInfo = [[CTTelephonyNetworkInfo alloc] init];
    CTCarrier *carrier = [networkInfo subscriberCellularProvider];
    if (carrier.carrierName.length) {
        NSMutableDictionary *telephony = [NSMutableDictionary dictionary];
        [telephony setObject:carrier.carrierName forKey:@"carrier"];
        [context setObject:telephony forKey:@"telephony"];
    }
    
    // Screen
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    NSMutableDictionary *screen = [NSMutableDictionary dictionary];
    [screen setObject:[NSNumber numberWithInt:(int)screenSize.width] forKey:@"width"];
    [screen setObject:[NSNumber numberWithInt:(int)screenSize.height] forKey:@"height"];
    [context setObject:screen forKey:@"screen"];
    
    return context;
}

@interface SegmentioIntegration ()

@property (nonatomic, weak) Analytics *analytics;
@property (nonatomic, strong) NSMutableArray *queue;
@property (nonatomic, strong) NSMutableDictionary *context;
@property (nonatomic, strong) NSArray *batch;
@property (nonatomic, strong) AnalyticsRequest *request;
@property (nonatomic, assign) UIBackgroundTaskIdentifier flushTaskID;

@end


@implementation SegmentioIntegration {
    dispatch_queue_t _serialQueue;
    NSMutableDictionary *_traits;
}

- (id)initWithAnalytics:(Analytics *)analytics {
    if (self = [self initWithWriteKey:analytics.writeKey flushAt:20]) {
        self.analytics = analytics;
    }
    return self;
}

- (id)initWithWriteKey:(NSString *)writeKey flushAt:(NSUInteger)flushAt {
    NSParameterAssert(writeKey.length);
    NSParameterAssert(flushAt > 0);
    
    if (self = [self init]) {
        _flushAt = flushAt;
        _writeKey = writeKey;
        _anonymousId = GetAnonymousId(NO);
        _userId = [NSString stringWithContentsOfURL:DISK_USER_ID_URL encoding:NSUTF8StringEncoding error:NULL];
        _queue = [NSMutableArray arrayWithContentsOfURL:DISK_QUEUE_URL];
        if (!_queue)
            _queue = [[NSMutableArray alloc] init];
        _traits = [NSMutableDictionary dictionaryWithContentsOfURL:DISK_TRAITS_URL];
        if (!_traits)
            _traits = [[NSMutableDictionary alloc] init];
        _context = BuildStaticContext();
        _serialQueue = dispatch_queue_create_specific("io.segment.analytics.segmentio", DISPATCH_QUEUE_SERIAL);
        _flushTaskID = UIBackgroundTaskInvalid;
        
        self.name = @"Segment.io";
        self.valid = NO;
        self.initialized = NO;
        self.settings = [NSDictionary dictionaryWithObjectsAndKeys:writeKey, @"writeKey", nil];
        [self validate];
        self.initialized = YES;

    }
    return self;
}

- (NSMutableDictionary *)liveContext {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    
    // Network
    // TODO https://github.com/segmentio/spec/issues/30
    
    // Traits
    // TODO https://github.com/segmentio/spec/issues/29
    
    return context;
}

- (void)dispatchBackground:(void(^)(void))block {
    dispatch_specific_async(_serialQueue, block);
}

- (void)dispatchBackgroundAndWait:(void(^)(void))block {
    dispatch_specific_sync(_serialQueue, block);
}

- (void)beginBackgroundTask {
    [self endBackgroundTask];
    self.flushTaskID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        [self endBackgroundTask];
    }];
}

- (void)endBackgroundTask {
    [self dispatchBackgroundAndWait:^{
        if (self.flushTaskID != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.flushTaskID];
            self.flushTaskID = UIBackgroundTaskInvalid;
        }
    }];
}

- (void)validate {
    BOOL hasWriteKey = [self.settings objectForKey:@"writeKey"] != nil;
    self.valid = hasWriteKey;
}

- (NSString *)getAnonymousId {
    return self.anonymousId;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SegmentioIntegration writeKey:%@>", self.writeKey];
}

- (void)saveUserId:(NSString *)userId {
    [self dispatchBackground:^{
        self.userId = userId;
        [_userId writeToURL:DISK_USER_ID_URL atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    }];
}

- (void)addTraits:(NSDictionary *)traits {
    [self dispatchBackground:^{
        [_traits addEntriesFromDictionary:traits];
        [_traits writeToURL:DISK_TRAITS_URL atomically:YES];
    }];
}

#pragma mark - Analytics API

- (void)identify:(NSString *)userId traits:(NSDictionary *)traits options:(NSDictionary *)options {
    [self dispatchBackground:^{
        [self saveUserId:userId];
        [self addTraits:traits];
    }];

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:traits forKey:@"traits"];

    [self enqueueAction:@"identify" dictionary:dictionary options:options];
}

 - (void)track:(NSString *)event properties:(NSDictionary *)properties options:(NSDictionary *)options {
    NSAssert(event.length, @"%@ track requires an event name.", self);

    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:event forKey:@"event"];
    [dictionary setValue:properties forKey:@"properties"];
    
    [self enqueueAction:@"track" dictionary:dictionary options:options];
 }

- (void)screen:(NSString *)screenTitle properties:(NSDictionary *)properties options:(NSDictionary *)options {
    NSAssert(screenTitle.length, @"%@ screen requires a screen title.", self);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:screenTitle forKey:@"name"];
    [dictionary setValue:properties forKey:@"properties"];
    
    [self enqueueAction:@"screen" dictionary:dictionary options:options];
}

- (void)group:(NSString *)groupId traits:(NSDictionary *)traits options:(NSDictionary *)options {
    NSAssert(groupId.length, @"%@ group requires a groupId.", self);
    
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
    [dictionary setValue:groupId forKey:@"groupId"];
    [dictionary setValue:traits forKey:@"traits"];
    
    [self enqueueAction:@"group" dictionary:dictionary options:options];
}

- (void)registerPushDeviceToken:(NSData *)deviceToken {
    NSAssert(deviceToken, @"%@ registerPushDeviceToken requires a deviceToken", self);
    
    const unsigned char *buffer = (const unsigned char *)[deviceToken bytes];
    if (!buffer) {
        return;
    }
    NSMutableString *hexadecimal = [NSMutableString stringWithCapacity:(deviceToken.length * 2)];
    for (NSUInteger i = 0; i < deviceToken.length; i++) {
        [hexadecimal appendString:[NSString stringWithFormat:@"%02lx", (unsigned long)buffer[i]]];
    }
    // TODO make this safer
    _context[@"device"][@"token"] = [NSString stringWithString:hexadecimal];
    
}

#pragma mark - Queueing

- (NSDictionary *)integrationsDictionary:(NSDictionary *)options {
    NSMutableDictionary *integrations = [options ?: @{} mutableCopy];
    for (AnalyticsIntegration *integration in self.analytics.integrations.allValues) {
        if (![integration isKindOfClass:[SegmentioIntegration class]]) {
            integrations[integration.name] = @NO;
        }
    }
    return integrations;
}

- (void)enqueueAction:(NSString *)action dictionary:(NSMutableDictionary *)dictionary options:(NSDictionary *)options {
    // attach these parts of the payload outside since they are all synchronous
    // and the timestamp will be more accurate.
    NSMutableDictionary *payload = [NSMutableDictionary dictionaryWithDictionary:dictionary];
    payload[@"action"] = action;
    payload[@"timestamp"] = [[NSDate date] description];
    payload[@"requestId"] = GenerateUUIDString();

    [self dispatchBackground:^{
        // attach userId and anonymousId inside the dispatch_async in case
        // they've changed (see identify function)
        [payload setValue:self.userId forKey:@"userId"];
        [payload setValue:self.anonymousId forKey:@"anonymousId"];
        SOLog(@"%@ Enqueueing action: %@", self, payload);
        
        [payload setValue:[self integrationsDictionary:options] forKey:@"integrations"];
        [payload setValue:[self liveContext] forKey:@"context"];
        [self.queue addObject:payload];
        [self flushQueueByLength];
    }];
}

- (void)flush {
    [self flushWithMaxSize:SEGMENTIO_MAX_BATCH_SIZE];
}

- (void)flushWithMaxSize:(NSUInteger)maxBatchSize {
    [self dispatchBackground:^{
        if ([self.queue count] == 0) {
            SOLog(@"%@ No queued API calls to flush.", self);
            return;
        } else if (self.request != nil) {
            SOLog(@"%@ API request already in progress, not flushing again.", self);
            NSLog(@"%@ %@", self.batch, self.request);
            return;
        } else if ([self.queue count] >= maxBatchSize) {
            self.batch = [self.queue subarrayWithRange:NSMakeRange(0, maxBatchSize)];
        } else {
            self.batch = [NSArray arrayWithArray:self.queue];
        }
        
        SOLog(@"%@ Flushing %lu of %lu queued API calls.", self, (unsigned long)self.batch.count, (unsigned long)self.queue.count);
        
        NSMutableDictionary *payloadDictionary = [NSMutableDictionary dictionary];
        [payloadDictionary setObject:self.writeKey forKey:@"writeKey"];
        [payloadDictionary setObject:[[NSDate date] description] forKey:@"sentAt"];
        [payloadDictionary setObject:self.context forKey:@"context"];
        [payloadDictionary setObject:self.batch forKey:@"batch"];
        
        NSData *payload = [NSJSONSerialization dataWithJSONObject:payloadDictionary
                                                          options:0 error:NULL];
        [self sendData:payload];
    }];
}

- (void)flushQueueByLength {
    [self dispatchBackground:^{
        SOLog(@"%@ Length is %lu.", self, (unsigned long)self.queue.count);
        if (self.request == nil && [self.queue count] >= self.flushAt) {
            [self flush];
        }
    }];
}

- (void)reset {
    [self dispatchBackgroundAndWait:^{
        [[NSFileManager defaultManager] removeItemAtURL:DISK_ANONYMOUS_ID_URL error:NULL];
        [[NSFileManager defaultManager] removeItemAtURL:DISK_USER_ID_URL error:NULL];
        [[NSFileManager defaultManager] removeItemAtURL:DISK_TRAITS_URL error:NULL];
        [[NSFileManager defaultManager] removeItemAtURL:DISK_QUEUE_URL error:NULL];
        self.userId = nil;
        self.queue = [NSMutableArray array];
        self.request.completion = nil;
        self.request = nil;
    }];
}

- (void)notifyForName:(NSString *)name userInfo:(id)userInfo {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:name object:self];
        NSLog(@"sent notification %@", name);
    });
}

- (void)sendData:(NSData *)data {
    NSMutableURLRequest *urlRequest = [NSMutableURLRequest requestWithURL:SEGMENTIO_API_URL];
    [urlRequest setValue:@"gzip" forHTTPHeaderField:@"Accept-Encoding"];
    [urlRequest setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [urlRequest setHTTPMethod:@"POST"];
    [urlRequest setHTTPBody:data];
    SOLog(@"%@ Sending batch API request.", self);
    self.request = [AnalyticsRequest startWithURLRequest:urlRequest completion:^{
        [self dispatchBackground:^{
            if (self.request.error) {
                SOLog(@"%@ API request had an error: %@", self, self.request.error);
                [self notifyForName:SegmentioRequestDidFailNotification userInfo:self.batch];
            } else {
                SOLog(@"%@ API request success 200", self);
                [self.queue removeObjectsInArray:self.batch];
                [self notifyForName:SegmentioRequestDidSucceedNotification userInfo:self.batch];
            }
            
            self.batch = nil;
            self.request = nil;
            [self endBackgroundTask];
        }];
    }];
    [self notifyForName:SegmentioDidSendRequestNotification userInfo:self.batch];
}

- (void)applicationDidEnterBackground {
    [self beginBackgroundTask];
    // We are gonna try to flush as much as we reasonably can when we enter background
    // since there is a chance that the user will never launch the app again.
    [self flushWithMaxSize:1000];
}

- (void)applicationWillTerminate {
    [self dispatchBackgroundAndWait:^{
        if (self.queue.count)
            [self.queue writeToURL:DISK_QUEUE_URL atomically:YES];
    }];
}

#pragma mark - Class Methods

+ (void)load {
    [Analytics registerIntegration:self withIdentifier:@"Segment.io"];
}

@end