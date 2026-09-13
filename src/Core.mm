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
#import <QuartzCore/QuartzCore.h>

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


#pragma mark - Real device location
@interface AZRealLocationReader : NSObject <CLLocationManagerDelegate>
@property(nonatomic, strong) CLLocationManager *manager;
@property(nonatomic, strong) NSMutableArray *callbacks;
@property(nonatomic) BOOL running;
@property(nonatomic) NSUInteger generation;
@end
@implementation AZRealLocationReader
+ (instancetype)sharedReader {
    static AZRealLocationReader *reader; static dispatch_once_t once;
    dispatch_once(&once, ^{ reader=[self new]; reader.callbacks=[NSMutableArray new]; });
    return reader;
}
- (NSError *)error:(NSString *)message {
    return [NSError errorWithDomain:@"AZ.GPS.RealLocation" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
- (void)finish:(CLLocation *)location error:(NSError *)error {
    self.running=NO;
    if (self.manager && orig_stopUpdatingLocation) orig_stopUpdatingLocation(self.manager,@selector(stopUpdatingLocation));
    NSArray *callbacks=[self.callbacks copy]; [self.callbacks removeAllObjects];
    for (void (^callback)(CLLocation *,NSError *) in callbacks) callback(location,error);
}
- (void)request:(void (^)(CLLocation *,NSError *))completion {
    [self.callbacks addObject:[completion copy]];
    if (self.running) return;
    self.running=YES; NSUInteger generation=++self.generation;
    if (!self.manager) {
        self.manager=[CLLocationManager new];
        self.manager.desiredAccuracy=kCLLocationAccuracyBest;
        // Call captured system implementations directly: never register this
        // private reader in the simulation broadcaster or delegate proxy.
        orig_setDelegate(self.manager,@selector(setDelegate:),self);
    }
    CLAuthorizationStatus status=[CLLocationManager authorizationStatus];
    if (status==kCLAuthorizationStatusDenied || status==kCLAuthorizationStatusRestricted) {
        [self finish:nil error:[self error:@"اسمح للتطبيق بالوصول إلى الموقع من إعدادات iOS."]]; return;
    }
    if (status==kCLAuthorizationStatusNotDetermined) {
        NSDictionary *info=NSBundle.mainBundle.infoDictionary;
        if (![info[@"NSLocationWhenInUseUsageDescription"] length]) {
            [self finish:nil error:[self error:@"التطبيق يحتاج NSLocationWhenInUseUsageDescription لطلب إذن الموقع."]]; return;
        }
        [self.manager requestWhenInUseAuthorization];
    }
    orig_startUpdatingLocation(self.manager,@selector(startUpdatingLocation));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (self.running && self.generation==generation)
            [self finish:nil error:[self error:@"لم يصل موقع حقيقي حديث. تحقق من إذن الموقع وخدمات الموقع ثم حاول مجددًا."]];
    });
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    if (!self.running) return;
    CLLocation *location=locations.lastObject;
    if (!location || location.horizontalAccuracy<0 || !CLLocationCoordinate2DIsValid(location.coordinate) ||
        fabs([location.timestamp timeIntervalSinceNow])>15) return;
    [self finish:location error:nil];
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    if (!self.running || ([error.domain isEqualToString:kCLErrorDomain] && error.code==kCLErrorLocationUnknown)) return;
    [self finish:nil error:error];
}
@end
void AZRequestRealLocation(void (^completion)(CLLocation *,NSError *)) {
    if (!completion) return;
    dispatch_async(dispatch_get_main_queue(),^{ [[AZRealLocationReader sharedReader] request:completion]; });
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
        timer=[NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(__unused NSTimer *t) {
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



@interface AZAppManager ()
@property(nonatomic,strong) NSTimer *motionTimer;
@property(nonatomic,strong) NSTimer *scheduleTimer;
@property(nonatomic,strong) MKDirections *directions;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong) NSArray *points;
@property(nonatomic) NSUInteger segment;
@property(nonatomic) double segmentProgress;
@property(nonatomic) double speed;
@property(nonatomic) double radius;
@property(nonatomic) double interval;
@property(nonatomic) double distanceTravelled;
@property(nonatomic) double totalDistance;
@property(nonatomic) CLLocationCoordinate2D anchor;
@property(nonatomic) CLLocationCoordinate2D randomTarget;
@property(nonatomic) BOOL random;
@property(nonatomic) BOOL paused;
@property(nonatomic) CFTimeInterval lastTick;
@end

@implementation AZAppManager
+ (instancetype)sharedManager { static AZAppManager *instance; static dispatch_once_t once; dispatch_once(&once, ^{ instance=[self new]; }); return instance; }
- (void)initialize {
    AZGPSInstallRuntimeHooks();
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(background:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(foreground:) name:UIApplicationDidBecomeActiveNotification object:nil];
    [self startScheduler];
}
- (void)background:(NSNotification *)note { self.lastTick=0; }
- (void)foreground:(NSNotification *)note { self.lastTick=0; [self evaluateSchedules]; }
- (AZError *)invalid { return [AZError errorWithCode:AZErrorCodeInvalidInput technical:@"Invalid simulation parameters"]; }
- (AZError *)unavailable { return [AZError errorWithCode:AZErrorCodeNotAvailable technical:@"Feature unavailable"]; }
- (void)update:(azgps::Coordinate)p speed:(double)s course:(double)course {
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state) {
        state.locationEnabled=YES; state.currentLatitude=p.latitude; state.currentLongitude=p.longitude;
        state.locationMode=self.random?AZLocationModeRandom:AZLocationModeRoute;
        state.movementActive=YES;state.movementPaused=self.paused;state.movementSpeed=s;state.movementCourse=course;
        state.randomMovementActive=self.random;state.randomRadius=self.radius;state.routeActive=!self.random;
        state.routePaused=self.paused;state.routeProgress=self.totalDistance>0?MIN(1.0,self.distanceTravelled/self.totalDistance):0;
        state.routeDistanceRemaining=MAX(0.0,self.totalDistance-self.distanceTravelled);state.routeSpeed=self.speed;
        state.lastAction=self.random?@"Random update":@"Route update";state.lastError=@"";
    }];
}
- (AZError *)stopMovement {
    ++self.generation;[self.directions cancel];self.directions=nil;
    [self.motionTimer invalidate];self.motionTimer=nil;self.points=nil;self.paused=NO;self.random=NO;
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state) {
        state.movementActive=NO;state.movementPaused=NO;state.movementSpeed=0;state.movementCourse=-1;
        state.randomMovementActive=NO;state.routeActive=NO;state.routePaused=NO;
        state.routeSpeed=0;state.routeProgress=0;state.routeDistanceRemaining=0;
        state.locationMode=state.locationEnabled?AZLocationModeStatic:AZLocationModeDefault;state.lastAction=@"Movement stopped";
    }];return [AZError success];
}
- (void)stopAllFeatures {
    [self stopMovement];[self.scheduleTimer invalidate];self.scheduleTimer=nil;
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state){state.schedulerActive=NO;}];
    [[AZLocationService sharedService] restoreDefault];
}
- (AZError *)activateStaticLocationWithLatitude:(double)lat longitude:(double)lon {
    if (!azgps::Coordinate{lat,lon}.isValid()) return [self invalid];
    [self stopMovement];return [[AZLocationService sharedService] setLocationWithLatitude:lat longitude:lon];
}
- (AZError *)restoreDefaultLocation { [self stopAllFeatures];return [AZError success]; }
- (AZError *)pauseMovement {
    if (!self.motionTimer)return [self unavailable];self.paused=YES;
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state){state.movementPaused=YES;state.routePaused=state.routeActive;}];return [AZError success];
}
- (AZError *)resumeMovement {
    if (!self.motionTimer)return [self unavailable];self.paused=NO;self.lastTick=0;
    [[AZRuntimeState sharedState] performUpdate:^(id<AZRuntimeStateMutable> state){state.movementPaused=NO;state.routePaused=NO;}];return [AZError success];
}
- (void)startTimer {
    self.lastTick=0;
    self.motionTimer=[NSTimer timerWithTimeInterval:self.interval repeats:YES block:^(__unused NSTimer *timer){[self tick];}];
    [[NSRunLoop mainRunLoop] addTimer:self.motionTimer forMode:NSRunLoopCommonModes];
}
- (azgps::Coordinate)point:(NSDictionary *)point { return {[point[@"lat"] doubleValue],[point[@"lon"] doubleValue]}; }
- (void)tick {
    CFTimeInterval now=CACurrentMediaTime();double dt=self.lastTick>0?MIN(2.0,now-self.lastTick):self.interval;self.lastTick=now;
    if(self.paused || UIApplication.sharedApplication.applicationState==UIApplicationStateBackground)return;
    AZRuntimeState *state=[AZRuntimeState sharedState];azgps::Coordinate current={state.currentLatitude,state.currentLongitude};
    if(self.random) {
        azgps::Coordinate target={self.randomTarget.latitude,self.randomTarget.longitude};
        double distance=azgps::haversineDistanceMeters(current,target);
        if(distance<1) { double bearing=arc4random_uniform(360000)/1000.0;double radius=sqrt(arc4random_uniform(1000000)/1000000.0)*self.radius;
            target=azgps::destinationPoint({self.anchor.latitude,self.anchor.longitude},bearing,radius);self.randomTarget=CLLocationCoordinate2DMake(target.latitude,target.longitude);distance=azgps::haversineDistanceMeters(current,target);}
        double step=MIN(distance,self.speed*dt);azgps::Coordinate next=azgps::interpolateGreatCircle(current,target,distance>0?step/distance:1);
        [self update:next speed:dt>0?step/dt:0 course:azgps::initialBearingDegrees(current,target)];return;
    }
    double budget=self.speed*dt;
    while(self.segment+1<self.points.count) {
        azgps::Coordinate start=[self point:self.points[self.segment]],end=[self point:self.points[self.segment+1]];
        double length=azgps::haversineDistanceMeters(start,end),remaining=MAX(0.0,length-self.segmentProgress);
        double step=MIN(budget,remaining);self.segmentProgress+=step;self.distanceTravelled+=step;budget-=step;
        current=azgps::interpolateGreatCircle(start,end,length>0?self.segmentProgress/length:1);
        [self update:current speed:self.speed course:azgps::initialBearingDegrees(start,end)];
        if(remaining<=step+0.001){self.segment++;self.segmentProgress=0;}else break;
        if(budget<=0)break;
    }
    if(self.segment+1>=self.points.count){[self stopMovement];}
}
- (AZError *)startRouteWithWaypoints:(NSArray *)points speed:(double)speed {
    if(points.count<2 || !isfinite(speed) || speed<=0 || speed>80)return [self invalid];
    double total=0;for(NSUInteger i=0;i<points.count;i++){
        NSDictionary *p=points[i];if(![p isKindOfClass:NSDictionary.class] || ![p[@"lat"] isKindOfClass:NSNumber.class] || ![p[@"lon"] isKindOfClass:NSNumber.class] || ![self point:p].isValid())return [self invalid];
        if(i)total+=azgps::haversineDistanceMeters([self point:points[i-1]],[self point:p]);
    }
    if(total<1)return [self invalid];
    [self stopMovement];self.points=[points copy];self.speed=speed;self.interval=1;self.segment=0;self.segmentProgress=0;self.distanceTravelled=0;self.totalDistance=total;
    [self update:[self point:points.firstObject] speed:speed course:-1];[self startTimer];
    [[NSUserDefaults standardUserDefaults] setObject:@{@"type":@"route",@"points":points,@"speed":@(speed)} forKey:@"AZ.GPS.lastRoute"];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"AZ.GPS.routePreview" object:points];
    return [AZError success];
}
- (void)prepareRouteFrom:(NSDictionary *)from to:(NSDictionary *)to completion:(void (^)(NSArray *,NSError *))completion {
    [self stopMovement];NSUInteger generation=self.generation;
    MKDirectionsRequest *request=[MKDirectionsRequest new];
    azgps::Coordinate a=[self point:from],b=[self point:to];
    request.source=[[MKMapItem alloc]initWithPlacemark:[[MKPlacemark alloc]initWithCoordinate:CLLocationCoordinate2DMake(a.latitude,a.longitude)]];
    request.destination=[[MKMapItem alloc]initWithPlacemark:[[MKPlacemark alloc]initWithCoordinate:CLLocationCoordinate2DMake(b.latitude,b.longitude)]];
    request.transportType=MKDirectionsTransportTypeWalking;self.directions=[[MKDirections alloc]initWithRequest:request];
    [self.directions calculateDirectionsWithCompletionHandler:^(MKDirectionsResponse *response,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            if(generation!=self.generation)return;self.directions=nil;MKRoute *route=response.routes.firstObject;
            if(!route || error){completion(@[from,to],error ?: [NSError errorWithDomain:@"AZ.GPS" code:1 userInfo:@{NSLocalizedDescriptionKey:@"لم يتوفر مسار من الخرائط"}]);return;}
            NSUInteger count=route.polyline.pointCount;CLLocationCoordinate2D *coordinates=(CLLocationCoordinate2D *)calloc(count,sizeof(CLLocationCoordinate2D));
            [route.polyline getCoordinates:coordinates range:NSMakeRange(0,count)];NSMutableArray *points=[NSMutableArray new];
            for(NSUInteger i=0;i<count;i++)[points addObject:@{@"lat":@(coordinates[i].latitude),@"lon":@(coordinates[i].longitude)}];free(coordinates);
            completion(points,nil);
        });
    }];
}
- (AZError *)startRandomWithRadius:(double)radius speed:(double)speed interval:(double)interval {
    if(!isfinite(radius)||radius<1||radius>10000||!isfinite(speed)||speed<=0||speed>80||!isfinite(interval)||interval<0.25||interval>2)return [self invalid];
    AZRuntimeState *state=[AZRuntimeState sharedState];if(!state.locationEnabled)return [self invalid];
    CLLocationCoordinate2D anchor=CLLocationCoordinate2DMake(state.currentLatitude,state.currentLongitude);
    [self stopMovement];self.random=YES;self.anchor=anchor;self.randomTarget=anchor;self.radius=radius;self.speed=speed;self.interval=interval;
    self.totalDistance=0;self.distanceTravelled=0;[self update:azgps::Coordinate{anchor.latitude,anchor.longitude} speed:0 course:-1];[self startTimer];
    [[NSUserDefaults standardUserDefaults]setObject:@{@"type":@"random",@"lat":@(anchor.latitude),@"lon":@(anchor.longitude),@"radius":@(radius),@"speed":@(speed),@"interval":@(interval)} forKey:@"AZ.GPS.lastRandom"];
    return [AZError success];
}
- (AZError *)startRandomMovementWithRadius:(double)radius {return [self startRandomWithRadius:radius speed:1.4 interval:1];}
- (AZError *)startMovementFromLatitude:(double)a longitude:(double)b toLatitude:(double)c longitude2:(double)d speed:(double)s {return [self startRouteWithWaypoints:@[@{@"lat":@(a),@"lon":@(b)},@{@"lat":@(c),@"lon":@(d)}] speed:s];}
- (NSArray *)schedules {return [[NSUserDefaults standardUserDefaults]arrayForKey:@"AZ.GPS.schedules"] ?: @[];}
- (void)deleteSchedule:(NSString *)identifier {
    NSMutableArray *entries=[[self schedules]mutableCopy];NSIndexSet *indexes=[entries indexesOfObjectsPassingTest:^BOOL(NSDictionary *e,NSUInteger i,BOOL *stop){return [e[@"id"] isEqual:identifier];}];
    [entries removeObjectsAtIndexes:indexes];[[NSUserDefaults standardUserDefaults]setObject:entries forKey:@"AZ.GPS.schedules"];
}
- (void)addDailyScheduleAt:(NSInteger)minute weekdays:(NSArray *)days type:(NSString *)type {
    if(minute<0||minute>=1440)return;
    NSDictionary *plan=nil;NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    if([type isEqual:@"location"]){AZRuntimeState *state=AZRuntimeState.sharedState;plan=@{@"type":type,@"lat":@(state.currentLatitude),@"lon":@(state.currentLongitude)};}
    else plan=[defaults dictionaryForKey:[type isEqual:@"route"]?@"AZ.GPS.lastRoute":@"AZ.GPS.lastRandom"];
    if(!plan)return;NSMutableArray *entries=[[self schedules]mutableCopy];[entries addObject:@{@"id":NSUUID.UUID.UUIDString,@"minute":@(minute),@"days":days,@"plan":plan}];
    [defaults setObject:entries forKey:@"AZ.GPS.schedules"];[self startScheduler];
}
- (AZError *)startScheduler {
    if(!self.scheduleTimer){self.scheduleTimer=[NSTimer timerWithTimeInterval:10 repeats:YES block:^(__unused NSTimer *timer){[self evaluateSchedules];}];[[NSRunLoop mainRunLoop]addTimer:self.scheduleTimer forMode:NSRunLoopCommonModes];}
    [[AZRuntimeState sharedState]performUpdate:^(id<AZRuntimeStateMutable>state){state.schedulerActive=YES;}];return [AZError success];
}
- (void)evaluateSchedules {
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive)return;
    NSDate *now=NSDate.date;NSDateComponents *parts=[NSCalendar.currentCalendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitWeekday|NSCalendarUnitHour|NSCalendarUnitMinute fromDate:now];
    for(NSDictionary *entry in [self schedules]){
        if([entry[@"minute"]integerValue]!=parts.hour*60+parts.minute || ![entry[@"days"]containsObject:@(parts.weekday)])continue;
        NSString *key=[@"AZ.GPS.fired."stringByAppendingString:entry[@"id"]];
        NSString *date=[NSString stringWithFormat:@"%ld-%ld-%ld",(long)parts.year,(long)parts.month,(long)parts.day];
        if([[NSUserDefaults.standardUserDefaults stringForKey:key]isEqual:date])continue;
        [NSUserDefaults.standardUserDefaults setObject:date forKey:key];NSDictionary *plan=entry[@"plan"];NSString *type=plan[@"type"];
        if([type isEqual:@"route"])[self startRouteWithWaypoints:plan[@"points"] speed:[plan[@"speed"]doubleValue]];
        else { [self activateStaticLocationWithLatitude:[plan[@"lat"]doubleValue] longitude:[plan[@"lon"]doubleValue]];
            if([type isEqual:@"random"])[self startRandomWithRadius:[plan[@"radius"]doubleValue] speed:[plan[@"speed"]doubleValue] interval:[plan[@"interval"]doubleValue]]; }
    }
}
- (AZError *)setActiveWiFiProfileWithID:(NSString *)p {return [self unavailable];}
- (AZError *)setActiveDeviceProfileWithID:(NSString *)p {return [self unavailable];}
@end
__attribute__((constructor)) static void AZGPSEntry(void) {
    @autoreleasepool { dispatch_async(dispatch_get_main_queue(), ^{
        [[AZAppManager sharedManager] initialize];
        [[AZUIController sharedController] installWhenReady];
    }); }
}
