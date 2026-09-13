#import "AZGPS.h"
#import "Portable.h"
#import "UI.h"
#import "Audit.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <MapKit/MapKit.h>
#import <objc/runtime.h>
#import <cmath>

#pragma mark - Constants

static NSString * const kSchemaLocation = @"azgps.location/1";
NSString * const AZEventLocationChanged = @"azgps.location.changed";
NSString * const AZEventRuntimeStateChanged = @"azgps.runtime.changed";
NSString * const AZEventRouteProgressChanged = @"azgps.route.progress.changed";
NSString * const AZEventErrorOccurred = @"azgps.error.occurred";


#pragma mark - Runtime Hooks (CLLocationManager)

static CLLocation *(*orig_location)(id, SEL) = NULL;
static id (*orig_delegate)(id, SEL) = NULL;
static void (*orig_setDelegate)(id, SEL, id) = NULL;
static void (*orig_startUpdatingLocation)(id, SEL) = NULL;
static void (*orig_stopUpdatingLocation)(id, SEL) = NULL;
static void (*orig_requestLocation)(id, SEL) = NULL;
static const void *kAZGPSProxyKey = &kAZGPSProxyKey;

static CLLocation *AZGPS_buildFakeLocation(AZRuntimeState *state) {
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake(state.currentLatitude, state.currentLongitude);
    CLLocationDirection course = -1.0;
    CLLocationSpeed speed = 0.0;
    if (state.movementActive) {
        course = state.movementCourse;
        speed = state.movementSpeed;
    }
    return [[CLLocation alloc]
        initWithCoordinate:coordinate
        altitude:0.0
        horizontalAccuracy:5.0
        verticalAccuracy:5.0
        course:course
        speed:speed
        timestamp:[NSDate date]];
}

#pragma mark - Delegate Proxy

@interface AZGPSDelegateProxy : NSObject <CLLocationManagerDelegate>
@property (nonatomic, weak) id originalDelegate;
@end

@implementation AZGPSDelegateProxy

- (BOOL)isKindOfClass:(Class)aClass {
    if (self.originalDelegate != nil && [self.originalDelegate isKindOfClass:aClass]) return YES;
    return [super isKindOfClass:aClass];
}

- (BOOL)respondsToSelector:(SEL)selector {
    if (self.originalDelegate != nil && [self.originalDelegate respondsToSelector:selector]) return YES;
    return [super respondsToSelector:selector];
}

- (BOOL)conformsToProtocol:(Protocol *)protocol {
    if (self.originalDelegate != nil && [self.originalDelegate conformsToProtocol:protocol]) return YES;
    return [super conformsToProtocol:protocol];
}

- (id)forwardingTargetForSelector:(SEL)selector {
    if (self.originalDelegate != nil && [self.originalDelegate respondsToSelector:selector]) return self.originalDelegate;
    return [super forwardingTargetForSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    if (self.originalDelegate != nil) {
        NSMethodSignature *signature = [self.originalDelegate methodSignatureForSelector:selector];
        if (signature != nil) return signature;
    }
    return [super methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
    if (self.originalDelegate != nil && [self.originalDelegate respondsToSelector:invocation.selector]) {
        [invocation invokeWithTarget:self.originalDelegate];
        return;
    }
    [super forwardInvocation:invocation];
}

- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {

    AZRuntimeState *state = [AZRuntimeState sharedState];

    AZAuditLogNSString(
        @"DELEGATE",
        [NSString stringWithFormat:
            @"didUpdateLocations ENTERED | incomingCount=%lu | locationEnabled=%@",
            (unsigned long)locations.count,
            state.locationEnabled ? @"YES" : @"NO"]
    );

    id delegate = self.originalDelegate;

    if (delegate == nil) {

        AZAuditLogNSString(
            @"DELEGATE",
            @"didUpdateLocations | originalDelegate=nil | callback dropped"
        );

        return;
    }

    if (state.locationEnabled) {

        CLLocation *fake = AZGPS_buildFakeLocation(state);

        AZAuditLogIntercept(
            @"delegate.didUpdateLocations",
            @"FAKE"
        );

        AZAuditLogLocation(
            @"delegate.didUpdateLocations.fake",
            fake
        );
        if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [(id<CLLocationManagerDelegate>)delegate locationManager:manager didUpdateLocations:@[ fake ]];
        }
        return;
    }
    AZAuditLogIntercept(
        @"delegate.didUpdateLocations",
        @"ORIGINAL"
    );

    if (locations.count > 0) {
        AZAuditLogLocation(
            @"delegate.didUpdateLocations.original",
            locations.lastObject
        );
    }

    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [(id<CLLocationManagerDelegate>)delegate locationManager:manager didUpdateLocations:locations];
    }
}

- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    AZRuntimeState *state = [AZRuntimeState sharedState];
    if (state.locationEnabled) return;
    id delegate = self.originalDelegate;
    if (delegate != nil && [delegate respondsToSelector:@selector(locationManager:didFailWithError:)]) {
        [(id<CLLocationManagerDelegate>)delegate locationManager:manager didFailWithError:error];
    }
}

@end

#pragma mark - Proxy Helpers

static id AZGPS_rawDelegate(id manager) {
    if (manager == nil || orig_delegate == NULL) return nil;
    return orig_delegate(manager, @selector(delegate));
}

static AZGPSDelegateProxy *AZGPS_existingProxy(id manager) {
    if (manager == nil) return nil;
    id value = objc_getAssociatedObject(manager, kAZGPSProxyKey);
    if ([value isKindOfClass:[AZGPSDelegateProxy class]]) return (AZGPSDelegateProxy *)value;
    return nil;
}

#pragma mark - Proxy Attach / Detach

static void AZGPS_attachProxy(id manager) {
    if (manager == nil) return;
    @try {
        AZGPSDelegateProxy *existing = AZGPS_existingProxy(manager);
        if (existing != nil) {
            id raw = AZGPS_rawDelegate(manager);
            if (raw != existing) {
                existing.originalDelegate = raw;
                if (orig_setDelegate != NULL) orig_setDelegate(manager, @selector(setDelegate:), existing);
            }
            return;
        }
        id currentDelegate = AZGPS_rawDelegate(manager);
        if (currentDelegate == nil) return;
        if ([currentDelegate isKindOfClass:[AZGPSDelegateProxy class]]) {
            objc_setAssociatedObject(manager, kAZGPSProxyKey, currentDelegate, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return;
        }
        AZGPSDelegateProxy *proxy = [[AZGPSDelegateProxy alloc] init];
        proxy.originalDelegate = currentDelegate;
        objc_setAssociatedObject(manager, kAZGPSProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (orig_setDelegate != NULL) orig_setDelegate(manager, @selector(setDelegate:), proxy);
        [[AZLogger sharedLogger] logCategory:AZLogLocation message:@"Delegate proxy attached"];

        AZAuditLogNSString(
            @"DELEGATE",
            [NSString stringWithFormat:
                @"Proxy attached | originalDelegate=%@",
                currentDelegate
                    ? (NSStringFromClass([currentDelegate class]) ?: @"unknown")
                    : @"nil"]
        );
    }
    @catch (NSException *exception) {
        [[AZLogger sharedLogger] logCategory:AZLogLocation message:[NSString stringWithFormat:@"Proxy attach failed: %@", exception]];
    }
}

static void AZGPS_detachProxy(id manager) {
    if (manager == nil) return;
    @try {
        AZGPSDelegateProxy *proxy = AZGPS_existingProxy(manager);
        if (proxy == nil) {
            id raw = AZGPS_rawDelegate(manager);
            if ([raw isKindOfClass:[AZGPSDelegateProxy class]]) proxy = (AZGPSDelegateProxy *)raw;
        }
        if (proxy != nil) {
            id original = proxy.originalDelegate;
            if (orig_setDelegate != NULL) orig_setDelegate(manager, @selector(setDelegate:), original);
            objc_setAssociatedObject(manager, kAZGPSProxyKey, nil, OBJC_ASSOCIATION_ASSIGN);
            [[AZLogger sharedLogger] logCategory:AZLogLocation message:@"Delegate proxy detached"];

            AZAuditLogNSString(
                @"DELEGATE",
                @"Proxy detached"
            );
        }
    }
    @catch (NSException *exception) {
        [[AZLogger sharedLogger] logCategory:AZLogLocation message:[NSString stringWithFormat:@"Proxy detach failed: %@", exception]];
    }
}


static NSHashTable *AZGPSManagers(void) {
    static NSHashTable *table; static dispatch_once_t once;
    dispatch_once(&once, ^{ table=[NSHashTable weakObjectsHashTable]; });
    return table;
}
static void AZGPSDeliver(CLLocationManager *manager) {
    AZRuntimeState *state=[AZRuntimeState sharedState];
    if (!state.locationEnabled) return;
    AZGPS_attachProxy(manager);
    id delegate=AZGPS_rawDelegate(manager);
    if ([delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)])
        [(id<CLLocationManagerDelegate>)delegate locationManager:manager didUpdateLocations:@[AZGPS_buildFakeLocation(state)]];
}
static void AZGPSStartBroadcasts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        static NSTimer *timer;
        timer=[NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
            for (CLLocationManager *manager in AZGPSManagers().allObjects) AZGPSDeliver(manager);
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
    });
}

#pragma mark - Hooked Methods

static CLLocation *AZGPS_hooked_location(id self, SEL _cmd) {

    @autoreleasepool {

        AZRuntimeState *state =
            [AZRuntimeState sharedState];

        AZAuditLogNSString(
            @"HOOK",
            [NSString stringWithFormat:
                @"CLLocationManager.location ENTERED | locationEnabled=%@",
                state.locationEnabled ? @"YES" : @"NO"]
        );

        if (state.locationEnabled) {

            CLLocation *fake =
                AZGPS_buildFakeLocation(state);

            AZAuditLogIntercept(
                @"CLLocationManager.location",
                @"FAKE"
            );

            AZAuditLogLocation(
                @"CLLocationManager.location.fake",
                fake
            );

            return fake;
        }

        if (orig_location != NULL) {

            CLLocation *original =
                orig_location(self, _cmd);

            AZAuditLogIntercept(
                @"CLLocationManager.location",
                @"ORIGINAL"
            );

            AZAuditLogLocation(
                @"CLLocationManager.location.original",
                original
            );

            return original;
        }

        AZAuditLogIntercept(
            @"CLLocationManager.location",
            @"NO_ORIGINAL_IMPLEMENTATION"
        );

        return nil;
    }
}

static id AZGPS_hooked_delegate(id self, SEL _cmd) {
    id real = nil;
    if (orig_delegate != NULL) real = orig_delegate(self, _cmd);
    if (real != nil && [real isKindOfClass:[AZGPSDelegateProxy class]]) {
        return ((AZGPSDelegateProxy *)real).originalDelegate;
    }
    return real;
}

static void AZGPS_hooked_setDelegate(id self, SEL _cmd, id delegate) {

    AZAuditLogNSString(
        @"DELEGATE",
        [NSString stringWithFormat:
            @"setDelegate ENTERED | manager=%@ | delegate=%@",
            NSStringFromClass([self class]) ?: @"nil",
            delegate ? (NSStringFromClass([delegate class]) ?: @"unknown") : @"nil"]
    );

    if (delegate == nil) {
        AZGPS_detachProxy(self);
        if (orig_setDelegate != NULL) orig_setDelegate(self, _cmd, nil);
        return;
    }
    if ([delegate isKindOfClass:[AZGPSDelegateProxy class]]) {
        if (orig_setDelegate != NULL) orig_setDelegate(self, _cmd, delegate);
        return;
    }
    AZGPSDelegateProxy *proxy = AZGPS_existingProxy(self);
    if (proxy != nil) {
        proxy.originalDelegate = delegate;
        if (orig_setDelegate != NULL) orig_setDelegate(self, _cmd, proxy);
        return;
    }
    if (orig_setDelegate != NULL) orig_setDelegate(self, _cmd, delegate);
    AZGPS_attachProxy(self);
}

static void AZGPS_hooked_startUpdatingLocation(id manager, SEL selector) {
    if (orig_startUpdatingLocation) orig_startUpdatingLocation(manager, selector);
    dispatch_async(dispatch_get_main_queue(), ^{
        [AZGPSManagers() addObject:manager];
        AZGPSStartBroadcasts();
        AZGPSDeliver(manager);
    });
}

static void AZGPS_hooked_stopUpdatingLocation(id self, SEL _cmd) {
    dispatch_async(dispatch_get_main_queue(), ^{ [AZGPSManagers() removeObject:self]; });

    AZAuditLogNSString(
        @"HOOK",
        @"stopUpdatingLocation ENTERED"
    );

    AZAuditLogIntercept(
        @"stopUpdatingLocation",
        @"ORIGINAL"
    );

    if (orig_stopUpdatingLocation != NULL) {
        orig_stopUpdatingLocation(self, _cmd);
    }
}

static void AZGPS_hooked_requestLocation(id self, SEL _cmd) {

    @autoreleasepool {

        AZRuntimeState *state =
            [AZRuntimeState sharedState];

        AZAuditLogNSString(
            @"HOOK",
            [NSString stringWithFormat:
                @"requestLocation ENTERED | locationEnabled=%@",
                state.locationEnabled ? @"YES" : @"NO"]
        );

        if (state.locationEnabled) {

            AZAuditLogIntercept(
                @"requestLocation",
                @"FAKE_MODE"
            );
            [[AZLogger sharedLogger] logCategory:AZLogLocation message:@"requestLocation intercepted"];
            AZGPS_attachProxy(self);
            dispatch_async(dispatch_get_main_queue(), ^{
                id delegate = AZGPS_rawDelegate(self);
                if (delegate != nil && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                    CLLocation *fake = AZGPS_buildFakeLocation([AZRuntimeState sharedState]);
                    [(id<CLLocationManagerDelegate>)delegate locationManager:(CLLocationManager *)self didUpdateLocations:@[ fake ]];
                }
            });
            return;
        }
        AZAuditLogIntercept(
            @"requestLocation",
            @"ORIGINAL"
        );

        if (orig_requestLocation != NULL) {
            orig_requestLocation(self, _cmd);
        }
    }
}

#pragma mark - Hook Installer

static void AZGPS_installHook(Class cls, SEL selector, IMP newImplementation, IMP *originalStorage, NSString *name) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) {
        [[AZLogger sharedLogger] logCategory:AZLogLocation message:[NSString stringWithFormat:@"%@ not found - skipped", name]];
        return;
    }
    IMP previous = method_setImplementation(method, newImplementation);
    if (originalStorage != NULL) *originalStorage = previous;
    [[AZLogger sharedLogger] logCategory:AZLogLocation message:[NSString stringWithFormat:@"%@ hook installed", name]];

    AZAuditLogNSString(
        @"HOOK_INSTALL",
        [NSString stringWithFormat:
            @"%@ installed",
            name ?: @"unknown"]
    );
}

static void AZGPSInstallRuntimeHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class managerClass = objc_getClass("CLLocationManager");
        if (managerClass == Nil) {
            [[AZLogger sharedLogger] logCategory:AZLogLocation message:@"CLLocationManager class not found"];
            return;
        }
        AZGPS_installHook(managerClass, @selector(location), (IMP)AZGPS_hooked_location, (IMP *)&orig_location, @"location");
        AZGPS_installHook(managerClass, @selector(delegate), (IMP)AZGPS_hooked_delegate, (IMP *)&orig_delegate, @"delegate");
        AZGPS_installHook(managerClass, @selector(setDelegate:), (IMP)AZGPS_hooked_setDelegate, (IMP *)&orig_setDelegate, @"setDelegate:");
        AZGPS_installHook(managerClass, @selector(startUpdatingLocation), (IMP)AZGPS_hooked_startUpdatingLocation, (IMP *)&orig_startUpdatingLocation, @"startUpdatingLocation");
        AZGPS_installHook(managerClass, @selector(stopUpdatingLocation), (IMP)AZGPS_hooked_stopUpdatingLocation, (IMP *)&orig_stopUpdatingLocation, @"stopUpdatingLocation");
        AZGPS_installHook(managerClass, @selector(requestLocation), (IMP)AZGPS_hooked_requestLocation, (IMP *)&orig_requestLocation, @"requestLocation");
        [[AZLogger sharedLogger] logCategory:AZLogLocation message:@"All runtime hooks installed"];

        AZAuditLogNSString(
            @"HOOK_INSTALL",
            @"All CLLocationManager runtime hooks installed"
        );
    });
}

#pragma mark - AZLogger

@implementation AZLogger {
    dispatch_queue_t _logQueue;
    NSMutableArray<NSString *> *_buffer;
}

+ (instancetype)sharedLogger {
    static AZLogger *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[AZLogger alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _logQueue = dispatch_queue_create("com.azgps.logger", DISPATCH_QUEUE_SERIAL);
        _buffer = [NSMutableArray array];
    }
    return self;
}

- (void)logCategory:(AZLogCategory)category message:(NSString *)message {
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@", [NSDate date], [self categoryName:category], message ?: @""];
    dispatch_async(_logQueue, ^{
        [self->_buffer addObject:line];
        if (self->_buffer.count > 500) [self->_buffer removeObjectAtIndex:0];
        NSLog(@"AZGPS %@", line);
    });
}

- (NSString *)categoryName:(AZLogCategory)category {
    switch (category) {
        case AZLogCore: return @"CORE";
        case AZLogLocation: return @"LOCATION";
        case AZLogMovement: return @"MOVEMENT";
        case AZLogRandom: return @"RANDOM";
        case AZLogRoute: return @"ROUTE";
        case AZLogWiFi: return @"WIFI";
        case AZLogDevice: return @"DEVICE";
        case AZLogScheduler: return @"SCHEDULER";
        case AZLogStorage: return @"STORAGE";
        case AZLogUI: return @"UI";
    }
    return @"UNKNOWN";
}
@end

#pragma mark - AZEventBus

@implementation AZEventBus {
    dispatch_queue_t _busQueue;
    NSMutableDictionary<NSString *, NSMapTable<id, id> *> *_handlers;
}

+ (instancetype)sharedBus {
    static AZEventBus *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[AZEventBus alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _busQueue = dispatch_queue_create("com.azgps.eventbus", DISPATCH_QUEUE_SERIAL);
        _handlers = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)subscribe:(NSString *)eventName observer:(id)observer block:(void (^)(NSDictionary *payload))block {
    if (eventName.length == 0 || observer == nil || block == nil) return;
    dispatch_sync(_busQueue, ^{
        NSMapTable *table = self->_handlers[eventName];
        if (table == nil) {
            table = [NSMapTable weakToStrongObjectsMapTable];
            self->_handlers[eventName] = table;
        }
        [table setObject:[block copy] forKey:observer];
    });
}

- (void)unsubscribe:(id)observer {
    if (observer == nil) return;
    dispatch_sync(_busQueue, ^{
        for (NSString *eventName in [self->_handlers.allKeys copy]) {
            [self->_handlers[eventName] removeObjectForKey:observer];
        }
    });
}

- (void)publish:(NSString *)eventName payload:(NSDictionary *)payload {
    if (eventName.length == 0) return;
    __block NSArray *blocks = nil;
    dispatch_sync(_busQueue, ^{
        NSMapTable *table = self->_handlers[eventName];
        if (table == nil) { blocks = @[]; return; }
        NSMutableArray *snapshot = [NSMutableArray array];
        NSEnumerator *enumerator = [table objectEnumerator];
        id blockObject = nil;
        while ((blockObject = [enumerator nextObject])) [snapshot addObject:blockObject];
        blocks = [snapshot copy];
    });
    NSDictionary *safePayload = payload ?: @{};
    for (id blockObject in blocks) {
        void (^block)(NSDictionary *) = blockObject;
        if (block != nil) block(safePayload);
    }
}
@end

#pragma mark - AZRuntimeState

@interface AZRuntimeState () <AZRuntimeStateMutable>
@property (nonatomic, assign, readwrite) BOOL locationEnabled;
@property (nonatomic, assign, readwrite) double currentLatitude;
@property (nonatomic, assign, readwrite) double currentLongitude;
@property (nonatomic, assign, readwrite) AZLocationMode locationMode;
@property (nonatomic, assign, readwrite) BOOL movementActive;
@property (nonatomic, assign, readwrite) BOOL movementPaused;
@property (nonatomic, assign, readwrite) double movementSpeed;
@property (nonatomic, assign, readwrite) double movementCourse;
@property (nonatomic, assign, readwrite) BOOL randomMovementActive;
@property (nonatomic, assign, readwrite) double randomRadius;
@property (nonatomic, assign, readwrite) BOOL routeActive;
@property (nonatomic, assign, readwrite) BOOL routePaused;
@property (nonatomic, assign, readwrite) double routeProgress;
@property (nonatomic, assign, readwrite) double routeDistanceRemaining;
@property (nonatomic, assign, readwrite) double routeSpeed;
@property (nonatomic, copy, readwrite) NSString *activeWiFiProfileID;
@property (nonatomic, copy, readwrite) NSString *activeDeviceProfileID;
@property (nonatomic, assign, readwrite) BOOL schedulerActive;
@property (nonatomic, copy, readwrite) NSString *lastAction;
@property (nonatomic, copy, readwrite) NSString *lastError;
@end

@implementation AZRuntimeState {
    dispatch_queue_t _stateQueue;
}

+ (instancetype)sharedState {
    static AZRuntimeState *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[AZRuntimeState alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _stateQueue = dispatch_queue_create("com.azgps.runtime", DISPATCH_QUEUE_SERIAL);
        _locationEnabled = NO;
        _currentLatitude = 0.0;
        _currentLongitude = 0.0;
        _locationMode = AZLocationModeDefault;
        _movementActive = NO;
        _movementPaused = NO;
        _movementSpeed = 0.0;
        _movementCourse = 0.0;
        _randomMovementActive = NO;
        _randomRadius = 0.0;
        _routeActive = NO;
        _routePaused = NO;
        _routeProgress = 0.0;
        _routeDistanceRemaining = 0.0;
        _routeSpeed = 0.0;
        _activeWiFiProfileID = @"";
        _activeDeviceProfileID = @"";
        _schedulerActive = NO;
        _lastAction = @"Initialized";
        _lastError = @"";
    }
    return self;
}

- (void)performUpdate:(void (^)(id<AZRuntimeStateMutable> state))updateBlock {
    if (updateBlock == nil) return;
    dispatch_sync(_stateQueue, ^{ updateBlock((id<AZRuntimeStateMutable>)self); });
    [[AZEventBus sharedBus] publish:AZEventRuntimeStateChanged payload:[self snapshotForUI]];
}

- (NSDictionary *)snapshotForUI {
    __block NSDictionary *snapshot = nil;
    dispatch_sync(_stateQueue, ^{
        snapshot = @{
            @"locationEnabled": @(self.locationEnabled),
            @"currentLatitude": @(self.currentLatitude),
            @"currentLongitude": @(self.currentLongitude),
            @"locationMode": @(self.locationMode),
            @"movementActive": @(self.movementActive),
            @"movementPaused": @(self.movementPaused),
            @"movementSpeed": @(self.movementSpeed),
            @"movementCourse": @(self.movementCourse),
            @"randomMovementActive": @(self.randomMovementActive),
            @"randomRadius": @(self.randomRadius),
            @"routeActive": @(self.routeActive),
            @"routePaused": @(self.routePaused),
            @"routeProgress": @(self.routeProgress),
            @"routeDistanceRemaining": @(self.routeDistanceRemaining),
            @"routeSpeed": @(self.routeSpeed),
            @"activeWiFiProfileID": self.activeWiFiProfileID ?: @"",
            @"activeDeviceProfileID": self.activeDeviceProfileID ?: @"",
            @"schedulerActive": @(self.schedulerActive),
            @"lastAction": self.lastAction ?: @"",
            @"lastError": self.lastError ?: @""
        };
    });
    return snapshot ?: @{};
}

- (void)resetToDefaultEnvironment {
    [self performUpdate:^(id<AZRuntimeStateMutable> state) {
        state.locationEnabled = NO;
        state.currentLatitude = 0.0;
        state.currentLongitude = 0.0;
        state.locationMode = AZLocationModeDefault;
        state.movementActive = NO;
        state.movementPaused = NO;
        state.movementSpeed = 0.0;
        state.movementCourse = 0.0;
        state.randomMovementActive = NO;
        state.randomRadius = 0.0;
        state.routeActive = NO;
        state.routePaused = NO;
        state.routeProgress = 0.0;
        state.routeDistanceRemaining = 0.0;
        state.routeSpeed = 0.0;
        state.activeWiFiProfileID = @"";
        state.activeDeviceProfileID = @"";
        state.schedulerActive = NO;
        state.lastAction = @"Environment reset";
        state.lastError = @"";
    }];
}
@end

#pragma mark - AZError

@interface AZError ()
@property (nonatomic, assign, readwrite) AZErrorCode errorCode;
@property (nonatomic, copy, readwrite) NSString *humanReadableMessage;
@property (nonatomic, copy, readwrite) NSString *technicalMessage;
@end

@implementation AZError

+ (instancetype)success {
    AZError *error = [[AZError alloc] init];
    error.errorCode = AZErrorCodeSuccess;
    error.humanReadableMessage = @"";
    error.technicalMessage = @"";
    return error;
}

+ (instancetype)errorWithCode:(AZErrorCode)code technical:(NSString *)technicalMessage {
    AZError *error = [[AZError alloc] init];
    error.errorCode = code;
    error.humanReadableMessage = [self userMessageForCode:code];
    error.technicalMessage = technicalMessage ?: @"";
    return error;
}

+ (NSString *)userMessageForCode:(AZErrorCode)code {
    switch (code) {
        case AZErrorCodeSuccess: return @"";
        case AZErrorCodeInvalidInput: return @"Invalid input.";
        case AZErrorCodeNotAvailable: return @"Feature not available.";
        case AZErrorCodeNetworkError: return @"Network error.";
        case AZErrorCodeConflict: return @"Another operation is active.";
        case AZErrorCodeStorageError: return @"Storage error.";
        case AZErrorCodeUnsupportedVersion: return @"Unsupported version.";
        case AZErrorCodeRouteError: return @"Route error.";
    }
    return @"Unknown error.";
}

- (BOOL)isSuccess { return self.errorCode == AZErrorCodeSuccess; }
@end

#pragma mark - AZSettingsStore

@implementation AZSettingsStore
+ (instancetype)sharedStore {
    static AZSettingsStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[AZSettingsStore alloc] init]; });
    return instance;
}
- (NSUserDefaults *)defaults { return [NSUserDefaults standardUserDefaults]; }
- (void)setObjectForKey:(NSString *)key value:(id)value {
    if (key.length == 0) return;
    if (value != nil) [[self defaults] setObject:value forKey:key];
    else [[self defaults] removeObjectForKey:key];
}
- (id)objectForKey:(NSString *)key { if (key.length == 0) return nil; return [[self defaults] objectForKey:key]; }
- (void)setStringForKey:(NSString *)key value:(NSString *)value { [self setObjectForKey:key value:value]; }
- (NSString *)stringForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:[NSString class]] ? v : nil; }
- (void)setDoubleForKey:(NSString *)key value:(double)value { if (key.length) [[self defaults] setDouble:value forKey:key]; }
- (double)doubleForKey:(NSString *)key { return key.length ? [[self defaults] doubleForKey:key] : 0.0; }
- (void)setBoolForKey:(NSString *)key value:(BOOL)value { if (key.length) [[self defaults] setBool:value forKey:key]; }
- (BOOL)boolForKey:(NSString *)key { return key.length ? [[self defaults] boolForKey:key] : NO; }
- (void)setArrayForKey:(NSString *)key value:(NSArray *)value { [self setObjectForKey:key value:value]; }
- (NSArray *)arrayForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:[NSArray class]] ? v : nil; }
- (void)setDictionaryForKey:(NSString *)key value:(NSDictionary *)value { [self setObjectForKey:key value:value]; }
- (NSDictionary *)dictionaryForKey:(NSString *)key { id v=[self objectForKey:key]; return [v isKindOfClass:[NSDictionary class]] ? v : nil; }
- (void)removeKey:(NSString *)key { if (key.length) [[self defaults] removeObjectForKey:key]; }
@end

#pragma mark - AZLocationModel

@implementation AZLocationModel {
    NSString *_locationID;
    NSString *_name;
    double _latitude;
    double _longitude;
    NSDate *_createdAt;
}
@synthesize locationID = _locationID;
@synthesize name = _name;
@synthesize latitude = _latitude;
@synthesize longitude = _longitude;
@synthesize createdAt = _createdAt;

+ (instancetype)locationWithName:(NSString *)name latitude:(double)latitude longitude:(double)longitude {
    AZLocationModel *location = [[AZLocationModel alloc] init];
    location->_locationID = [[NSUUID UUID] UUIDString];
    location->_name = [name copy] ?: @"Unnamed";
    location->_latitude = latitude;
    location->_longitude = longitude;
    location->_createdAt = [NSDate date];
    return location;
}

- (BOOL)coordinateIsValid { return _latitude >= -90.0 && _latitude <= 90.0 && _longitude >= -180.0 && _longitude <= 180.0; }
- (NSDictionary *)toDictionary {
    return @{@"schema":kSchemaLocation,@"id":_locationID?:@"",@"name":_name?:@"",@"lat":@(_latitude),@"lon":@(_longitude),@"createdAt":@([_createdAt timeIntervalSince1970])};
}
+ (instancetype)fromDictionary:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    NSString *schema = dict[@"schema"];
    if (![schema isKindOfClass:[NSString class]] || ![schema isEqualToString:kSchemaLocation]) return nil;
    NSNumber *lat = dict[@"lat"], *lon = dict[@"lon"];
    if (![lat isKindOfClass:[NSNumber class]] || ![lon isKindOfClass:[NSNumber class]]) return nil;
    double latitude=[lat doubleValue], longitude=[lon doubleValue];
    if (latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) return nil;
    AZLocationModel *location=[[AZLocationModel alloc] init];
    NSString *locationID=dict[@"id"], *name=dict[@"name"]; NSNumber *created=dict[@"createdAt"];
    location->_locationID=([locationID isKindOfClass:[NSString class]]&&locationID.length>0)?[locationID copy]:[[NSUUID UUID] UUIDString];
    location->_name=([name isKindOfClass:[NSString class]]&&name.length>0)?[name copy]:@"Unnamed";
    location->_latitude=latitude; location->_longitude=longitude;
    location->_createdAt=[created isKindOfClass:[NSNumber class]]?[NSDate dateWithTimeIntervalSince1970:[created doubleValue]]:[NSDate date];
    return location;
}
@end

#pragma mark - AZLocationService

static NSString * const kFavoritesKey = @"azgps.favorites.v1";
static NSString * const kLastLatKey = @"azgps.lastLatitude";
static NSString * const kLastLonKey = @"azgps.lastLongitude";

@implementation AZLocationService
+ (instancetype)sharedService { static AZLocationService *i=nil; static dispatch_once_t once; dispatch_once(&once, ^{ i=[[AZLocationService alloc] init];}); return i; }
- (AZError *)setLocationWithLatitude:(double)latitude longitude:(double)longitude {
    if (latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Coordinate out of range"];
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state) {
        state.locationEnabled=YES; state.currentLatitude=latitude; state.currentLongitude=longitude; state.locationMode=AZLocationModeStatic; state.lastAction=@"Static location activated"; state.lastError=@"";
    }];
    [[AZSettingsStore sharedStore] setDoubleForKey:kLastLatKey value:latitude];
    [[AZSettingsStore sharedStore] setDoubleForKey:kLastLonKey value:longitude];
    [[AZEventBus sharedBus] publish:AZEventLocationChanged payload:@{@"lat":@(latitude),@"lon":@(longitude)}];
    return [AZError success];
}
- (BOOL)isLocationActive { return [AZRuntimeState sharedState].locationEnabled; }
- (NSDictionary *)currentLocation { AZRuntimeState *s=[AZRuntimeState sharedState]; return s.locationEnabled ? @{@"lat":@(s.currentLatitude),@"lon":@(s.currentLongitude)} : nil; }
- (AZError *)clearLocation { return [self restoreDefault]; }
- (AZError *)restoreDefault {
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state) { state.locationEnabled=NO; state.locationMode=AZLocationModeDefault; state.lastAction=@"Location restored to default"; state.lastError=@""; }];
    [[AZEventBus sharedBus] publish:AZEventLocationChanged payload:@{}];
    return [AZError success];
}
- (NSArray<AZLocationModel *> *)favorites {
    NSArray *raw=[[AZSettingsStore sharedStore] arrayForKey:kFavoritesKey]; NSMutableArray *result=[NSMutableArray array];
    for (id object in (raw?:@[])) if ([object isKindOfClass:[NSDictionary class]]) { AZLocationModel *l=[AZLocationModel fromDictionary:object]; if (l) [result addObject:l]; }
    return [result copy];
}
- (AZError *)addFavoriteWithName:(NSString *)name latitude:(double)latitude longitude:(double)longitude {
    if (name.length==0) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Empty favorite name"];
    AZLocationModel *l=[AZLocationModel locationWithName:name latitude:latitude longitude:longitude]; if (![l coordinateIsValid]) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Invalid favorite coordinate"];
    NSMutableArray *f=[[self favorites] mutableCopy] ?: [NSMutableArray array]; [f addObject:l]; [self persistFavorites:f]; return [AZError success];
}
- (AZError *)renameFavoriteWithID:(NSString *)locationID newName:(NSString *)newName {
    if (locationID.length==0||newName.length==0) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Invalid favorite ID or name"];
    NSMutableArray *f=[[self favorites] mutableCopy] ?: [NSMutableArray array]; NSUInteger idx=NSNotFound;
    for (NSUInteger i=0;i<f.count;i++) if ([((AZLocationModel *)f[i]).locationID isEqualToString:locationID]) { idx=i; break; }
    if (idx==NSNotFound) return [AZError errorWithCode:AZErrorCodeNotAvailable technical:@"Favorite not found"];
    NSMutableDictionary *d=[[(AZLocationModel *)f[idx] toDictionary] mutableCopy]; d[@"name"]=newName; AZLocationModel *r=[AZLocationModel fromDictionary:d]; if (!r) return [AZError errorWithCode:AZErrorCodeStorageError technical:@"Unable to rename favorite"];
    [f replaceObjectAtIndex:idx withObject:r]; [self persistFavorites:f]; return [AZError success];
}
- (AZError *)deleteFavoriteWithID:(NSString *)locationID {
    if (locationID.length==0) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Empty favorite ID"];
    NSMutableArray *f=[[self favorites] mutableCopy] ?: [NSMutableArray array]; NSUInteger idx=NSNotFound;
    for (NSUInteger i=0;i<f.count;i++) if ([((AZLocationModel *)f[i]).locationID isEqualToString:locationID]) { idx=i; break; }
    if (idx==NSNotFound) return [AZError errorWithCode:AZErrorCodeNotAvailable technical:@"Favorite not found"];
    [f removeObjectAtIndex:idx]; [self persistFavorites:f]; return [AZError success];
}
- (AZError *)activateFavoriteWithID:(NSString *)locationID {
    if (locationID.length==0) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Empty favorite ID"];
    for (AZLocationModel *l in [self favorites]) if ([l.locationID isEqualToString:locationID]) return [self setLocationWithLatitude:l.latitude longitude:l.longitude];
    return [AZError errorWithCode:AZErrorCodeNotAvailable technical:@"Favorite not found"];
}
- (void)persistFavorites:(NSArray<AZLocationModel *> *)favorites {
    NSMutableArray *serialized=[NSMutableArray array]; for (AZLocationModel *l in favorites) { NSDictionary *d=[l toDictionary]; if (d) [serialized addObject:d]; }
    [[AZSettingsStore sharedStore] setArrayForKey:kFavoritesKey value:serialized];
}
@end


@implementation AZAppManager
+ (instancetype)sharedManager { static AZAppManager *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance=[self new]; }); return instance; }
- (void)initialize { AZGPSInstallRuntimeHooks(); }
- (AZError *)activateStaticLocationWithLatitude:(double)lat longitude:(double)lon {
    if (!isfinite(lat) || !isfinite(lon)) return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Non-finite coordinate"];
    return [[AZLocationService sharedService] setLocationWithLatitude:lat longitude:lon];
}
- (AZError *)restoreDefaultLocation { return [[AZLocationService sharedService] restoreDefault]; }
- (AZError *)stopMovement { return [AZError success]; }
- (AZError *)unavailable { return [AZError errorWithCode:AZErrorCodeNotAvailable technical:@"Deferred until the GPS baseline passes device validation"]; }
- (AZError *)pauseMovement { return [self unavailable]; }
- (AZError *)resumeMovement { return [self unavailable]; }
- (AZError *)startRandomMovementWithRadius:(double)radius { return [self unavailable]; }
- (AZError *)startRouteWithWaypoints:(NSArray *)points speed:(double)speed { return [self unavailable]; }
- (AZError *)startMovementFromLatitude:(double)a longitude:(double)b toLatitude:(double)c longitude2:(double)d speed:(double)s { return [self unavailable]; }
- (AZError *)setActiveWiFiProfileWithID:(NSString *)p { return [self unavailable]; }
- (AZError *)setActiveDeviceProfileWithID:(NSString *)p { return [self unavailable]; }
- (AZError *)startScheduler { return [self unavailable]; }
@end
__attribute__((constructor)) static void AZGPSEntry(void) {
    @autoreleasepool { dispatch_async(dispatch_get_main_queue(), ^{
        [[AZAppManager sharedManager] initialize];
        [[AZUIController sharedController] installWhenReady];
    }); }
}
