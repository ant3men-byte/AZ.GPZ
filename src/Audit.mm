#import "Audit.h"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

#pragma mark - Storage

static dispatch_queue_t AZAuditQueue(void) {

    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create(
            "com.azgps.audit",
            DISPATCH_QUEUE_SERIAL
        );
    });

    return queue;
}


NSString *AZAuditLogFilePath(void) {

    NSArray<NSString *> *paths =
        NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory,
            NSUserDomainMask,
            YES
        );

    NSString *documents = paths.firstObject;

    if (documents.length == 0) {
        documents = NSTemporaryDirectory();
    }

    return [documents
        stringByAppendingPathComponent:
            @"AZGPSAudit.log"];
}


static NSString *AZAuditTimestamp(void) {

    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{

        formatter = [[NSDateFormatter alloc] init];

        formatter.locale =
            [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];

        formatter.dateFormat =
            @"yyyy-MM-dd HH:mm:ss.SSS";
    });

    @synchronized (formatter) {
        return [formatter stringFromDate:[NSDate date]];
    }
}


static void AZAuditWrite(
    NSString *category,
    NSString *message
) {

    NSString *safeCategory =
        category.length ? category : @"GENERAL";

    NSString *safeMessage =
        message.length ? message : @"";

    NSString *line =
        [NSString stringWithFormat:
            @"[%@] [%@] %@\n",
            AZAuditTimestamp(),
            safeCategory,
            safeMessage];

    NSLog(@"[AZGPSAudit] %@", line);

    dispatch_async(AZAuditQueue(), ^{

        NSString *path = AZAuditLogFilePath();

        NSFileManager *fm =
            [NSFileManager defaultManager];

        if (![fm fileExistsAtPath:path]) {

            NSData *data =
                [line dataUsingEncoding:NSUTF8StringEncoding];

            [fm createFileAtPath:path
                       contents:data
                     attributes:nil];

            return;
        }

        NSFileHandle *handle =
            [NSFileHandle fileHandleForWritingAtPath:path];

        if (handle == nil) {
            return;
        }

        @try {

            [handle seekToEndOfFile];

            NSData *data =
                [line dataUsingEncoding:NSUTF8StringEncoding];

            [handle writeData:data];
        }
        @catch (NSException *exception) {

            NSLog(
                @"[AZGPSAudit] Write failed: %@",
                exception
            );
        }
        @finally {

            [handle closeFile];
        }
    });
}


void AZAuditLogNSString(
    NSString *category,
    NSString *message
) {

    AZAuditWrite(category, message);
}


void AZAuditLogIntercept(
    NSString *hookName,
    NSString *result
) {

    AZAuditWrite(
        @"INTERCEPT",
        [NSString stringWithFormat:
            @"HOOK=%@ | RESULT=%@",
            hookName ?: @"unknown",
            result ?: @"unknown"]
    );
}


void AZAuditLogLocation(
    NSString *source,
    CLLocation *location
) {

    if (location == nil) {

        AZAuditWrite(
            @"LOCATION",
            [NSString stringWithFormat:
                @"SOURCE=%@ | LOCATION=nil",
                source ?: @"unknown"]
        );

        return;
    }

    AZAuditWrite(
        @"LOCATION",
        [NSString stringWithFormat:
            @"SOURCE=%@ | LAT=%.8f | LON=%.8f | HACC=%.2f | VACC=%.2f | SPEED=%.2f | COURSE=%.2f",
            source ?: @"unknown",
            location.coordinate.latitude,
            location.coordinate.longitude,
            location.horizontalAccuracy,
            location.verticalAccuracy,
            location.speed,
            location.course]
    );
}


void AZAuditLogFeature(
    NSString *feature,
    NSString *status,
    NSString *details
) {

    NSString *safeFeature =
        feature.length ? feature : @"unknown";

    NSString *safeStatus =
        status.length ? status : @"UNKNOWN";

    NSString *safeDetails =
        details.length ? details : @"";

    NSString *message = nil;

    if (safeDetails.length > 0) {
        message =
            [NSString stringWithFormat:
                @"FEATURE=%@ | STATUS=%@ | %@",
                safeFeature,
                safeStatus,
                safeDetails];
    } else {
        message =
            [NSString stringWithFormat:
                @"FEATURE=%@ | STATUS=%@",
                safeFeature,
                safeStatus];
    }

    AZAuditWrite(
        @"FEATURE",
        message
    );
}


void AZAuditLogState(
    NSString *source,
    NSDictionary *snapshot
) {

    if (![snapshot isKindOfClass:[NSDictionary class]]) {

        AZAuditWrite(
            @"STATE",
            [NSString stringWithFormat:
                @"SOURCE=%@ | SNAPSHOT=nil",
                source ?: @"unknown"]
        );

        return;
    }

    BOOL locationEnabled =
        [snapshot[@"locationEnabled"] boolValue];

    double lat =
        [snapshot[@"currentLatitude"] doubleValue];

    double lon =
        [snapshot[@"currentLongitude"] doubleValue];

    NSInteger locationMode =
        [snapshot[@"locationMode"] integerValue];

    BOOL movementActive =
        [snapshot[@"movementActive"] boolValue];

    BOOL movementPaused =
        [snapshot[@"movementPaused"] boolValue];

    BOOL randomActive =
        [snapshot[@"randomMovementActive"] boolValue];

    BOOL routeActive =
        [snapshot[@"routeActive"] boolValue];

    BOOL schedulerActive =
        [snapshot[@"schedulerActive"] boolValue];

    NSString *lastAction =
        [snapshot[@"lastAction"] isKindOfClass:[NSString class]]
            ? snapshot[@"lastAction"]
            : @"";

    NSString *lastError =
        [snapshot[@"lastError"] isKindOfClass:[NSString class]]
            ? snapshot[@"lastError"]
            : @"";

    AZAuditWrite(
        @"STATE",
        [NSString stringWithFormat:
            @"SOURCE=%@ | locationEnabled=%@ | lat=%.8f | lon=%.8f | mode=%ld | movement=%@ | paused=%@ | random=%@ | route=%@ | scheduler=%@ | lastAction=%@ | lastError=%@",
            source ?: @"unknown",
            locationEnabled ? @"YES" : @"NO",
            lat,
            lon,
            (long)locationMode,
            movementActive ? @"YES" : @"NO",
            movementPaused ? @"YES" : @"NO",
            randomActive ? @"YES" : @"NO",
            routeActive ? @"YES" : @"NO",
            schedulerActive ? @"YES" : @"NO",
            lastAction,
            lastError]
    );
}


NSString *AZAuditReadAll(void) {

    __block NSString *result = @"";

    dispatch_sync(AZAuditQueue(), ^{

        NSString *path = AZAuditLogFilePath();

        NSError *error = nil;

        NSString *text =
            [NSString stringWithContentsOfFile:path
                                     encoding:NSUTF8StringEncoding
                                        error:&error];

        if (text != nil) {
            result = text;
        }
    });

    return result ?: @"";
}


void AZAuditClear(void) {

    dispatch_sync(AZAuditQueue(), ^{

        NSString *path = AZAuditLogFilePath();

        [[NSFileManager defaultManager]
            removeItemAtPath:path
                       error:nil];
    });

    AZAuditWrite(
        @"SYSTEM",
        @"Audit log cleared"
    );
}


#pragma mark - Automatic UI Action Audit

static BOOL AZAuditIsAZGPSTarget(id target) {

    if (target == nil) {
        return NO;
    }

    NSString *className =
        NSStringFromClass([target class]);

    return
        [className hasPrefix:@"AZ"] ||
        [className hasPrefix:@"AZGPS"];
}


static NSString *AZAuditSenderDescription(id sender) {

    if ([sender isKindOfClass:[UIButton class]]) {

        UIButton *button = (UIButton *)sender;

        NSString *title =
            [button titleForState:UIControlStateNormal];

        if (title.length == 0) {
            title = button.accessibilityLabel;
        }

        if (title.length == 0) {
            title = @"<no-title>";
        }

        return [NSString stringWithFormat:
            @"UIButton=\"%@\"",
            title];
    }

    if ([sender isKindOfClass:[UISwitch class]]) {

        UISwitch *sw = (UISwitch *)sender;

        return [NSString stringWithFormat:
            @"UISwitch=%@",
            sw.isOn ? @"ON" : @"OFF"];
    }

    if ([sender isKindOfClass:[UISegmentedControl class]]) {

        UISegmentedControl *seg =
            (UISegmentedControl *)sender;

        return [NSString stringWithFormat:
            @"UISegmentedControl index=%ld",
            (long)seg.selectedSegmentIndex];
    }

    return NSStringFromClass([sender class]) ?: @"Unknown";
}


static BOOL (*AZAuditOrigSendAction)(
    id,
    SEL,
    SEL,
    id,
    id,
    UIEvent *
) = NULL;


static BOOL AZAuditHookedSendAction(
    id self,
    SEL _cmd,
    SEL action,
    id target,
    id sender,
    UIEvent *event
) {

    BOOL shouldLog =
        AZAuditIsAZGPSTarget(target);

    if (shouldLog) {

        NSString *targetName =
            NSStringFromClass([target class]) ?: @"nil";

        NSString *actionName =
            action ? NSStringFromSelector(action) : @"nil";

        AZAuditWrite(
            @"UI",
            [NSString stringWithFormat:
                @"PRESS | %@ | TARGET=%@ | ACTION=%@",
                AZAuditSenderDescription(sender),
                targetName,
                actionName]
        );
    }

    BOOL result = NO;

    if (AZAuditOrigSendAction != NULL) {

        result =
            AZAuditOrigSendAction(
                self,
                _cmd,
                action,
                target,
                sender,
                event
            );
    }

    if (shouldLog) {

        NSString *actionName =
            action ? NSStringFromSelector(action) : @"nil";

        AZAuditWrite(
            @"UI",
            [NSString stringWithFormat:
                @"COMPLETE | ACTION=%@ | RESULT=%@",
                actionName,
                result ? @"YES" : @"NO"]
        );
    }

    return result;
}


static void AZAuditInstallUIHook(void) {

    Class cls = [UIApplication class];

    SEL selector =
        @selector(sendAction:to:from:forEvent:);

    Method method =
        class_getInstanceMethod(cls, selector);

    if (method == NULL) {

        AZAuditWrite(
            @"SYSTEM",
            @"UIApplication sendAction not found"
        );

        return;
    }

    IMP previous =
        method_setImplementation(
            method,
            (IMP)AZAuditHookedSendAction
        );

    AZAuditOrigSendAction =
        (BOOL (*)(id, SEL, SEL, id, id, UIEvent *))previous;

    AZAuditWrite(
        @"SYSTEM",
        @"UI action audit installed"
    );
}


#pragma mark - Log Viewer

@interface AZAuditViewController : UIViewController
@end


@implementation AZAuditViewController {
    UITextView *_textView;
}


- (void)viewDidLoad {

    [super viewDidLoad];

    self.view.backgroundColor =
        [UIColor colorWithRed:0.08
                        green:0.09
                         blue:0.10
                        alpha:1.0];

    self.title = @"AZGPS Logs";

    if (@available(iOS 13.0, *)) {
        self.modalPresentationStyle =
            UIModalPresentationPageSheet;
    }

    CGFloat width =
        CGRectGetWidth(self.view.bounds);

    CGFloat height =
        CGRectGetHeight(self.view.bounds);

    UIView *bar =
        [[UIView alloc]
            initWithFrame:
                CGRectMake(0, 44, width, 72)];

    bar.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;

    bar.backgroundColor =
        [UIColor colorWithWhite:0.13 alpha:1.0];

    [self.view addSubview:bar];

    UILabel *title =
        [[UILabel alloc]
            initWithFrame:
                CGRectMake(16, 18, width - 180, 36)];

    title.autoresizingMask =
        UIViewAutoresizingFlexibleWidth;

    title.text =
        @"AZGPS Audit";

    title.textColor =
        UIColor.whiteColor;

    title.font =
        [UIFont boldSystemFontOfSize:20];

    [bar addSubview:title];

    UIButton *close =
        [UIButton buttonWithType:UIButtonTypeSystem];

    close.frame =
        CGRectMake(width - 54, 14, 44, 44);

    close.autoresizingMask =
        UIViewAutoresizingFlexibleLeftMargin;

    [close setTitle:@"X"
           forState:UIControlStateNormal];

    [close setTitleColor:
        UIColor.whiteColor
             forState:UIControlStateNormal];

    close.titleLabel.font =
        [UIFont boldSystemFontOfSize:20];

    [close addTarget:self
              action:@selector(closeTapped)
    forControlEvents:UIControlEventTouchUpInside];

    [bar addSubview:close];

    _textView =
        [[UITextView alloc]
            initWithFrame:
                CGRectMake(
                    12,
                    128,
                    width - 24,
                    height - 198
                )];

    _textView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth |
        UIViewAutoresizingFlexibleHeight;

    _textView.backgroundColor =
        [UIColor colorWithWhite:0.04 alpha:1.0];

    _textView.textColor =
        UIColor.whiteColor;

    _textView.font =
        [UIFont fontWithName:@"Menlo-Regular" size:11] ?: [UIFont systemFontOfSize:11];

    _textView.editable = NO;
    _textView.selectable = YES;
    _textView.layer.cornerRadius = 14.0;

    [self.view addSubview:_textView];

    CGFloat gap = 8.0;
    CGFloat buttonWidth =
        (width - 24 - gap * 2) / 3.0;

    UIButton *refresh =
        [self auditButton:@"Refresh"];

    refresh.frame =
        CGRectMake(
            12,
            height - 60,
            buttonWidth,
            44
        );

    refresh.autoresizingMask =
        UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleRightMargin;

    [refresh addTarget:self
                action:@selector(refreshTapped)
      forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:refresh];

    UIButton *copy =
        [self auditButton:@"Copy"];

    copy.frame =
        CGRectMake(
            12 + buttonWidth + gap,
            height - 60,
            buttonWidth,
            44
        );

    copy.autoresizingMask =
        UIViewAutoresizingFlexibleTopMargin;

    [copy addTarget:self
             action:@selector(copyTapped)
   forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:copy];

    UIButton *clear =
        [self auditButton:@"Clear"];

    clear.frame =
        CGRectMake(
            12 + (buttonWidth + gap) * 2,
            height - 60,
            buttonWidth,
            44
        );

    clear.autoresizingMask =
        UIViewAutoresizingFlexibleTopMargin |
        UIViewAutoresizingFlexibleLeftMargin;

    [clear addTarget:self
              action:@selector(clearTapped)
    forControlEvents:UIControlEventTouchUpInside];

    [self.view addSubview:clear];

    [self reloadLog];
}


- (UIButton *)auditButton:(NSString *)title {

    UIButton *button =
        [UIButton buttonWithType:UIButtonTypeSystem];

    button.backgroundColor =
        [UIColor colorWithWhite:0.18 alpha:1.0];

    button.layer.cornerRadius = 12.0;

    [button setTitle:title
            forState:UIControlStateNormal];

    [button setTitleColor:
        UIColor.whiteColor
              forState:UIControlStateNormal];

    button.titleLabel.font =
        [UIFont systemFontOfSize:14
                          weight:UIFontWeightSemibold];

    return button;
}


- (void)reloadLog {

    NSString *text =
        AZAuditReadAll();

    if (text.length == 0) {

        text =
            @"No AZGPS audit entries yet.";
    }

    _textView.text = text;

    if (_textView.text.length > 0) {

        NSRange bottom =
            NSMakeRange(
                _textView.text.length - 1,
                1
            );

        [_textView scrollRangeToVisible:bottom];
    }
}


- (void)refreshTapped {

    AZAuditWrite(
        @"AUDIT_UI",
        @"Refresh logs pressed"
    );

    [self reloadLog];
}


- (void)copyTapped {

    AZAuditWrite(
        @"AUDIT_UI",
        @"Copy logs pressed"
    );

    UIPasteboard.generalPasteboard.string =
        AZAuditReadAll();

    [self reloadLog];
}


- (void)clearTapped {

    AZAuditClear();

    [self reloadLog];
}


- (void)closeTapped {

    AZAuditWrite(
        @"AUDIT_UI",
        @"Logs viewer closed"
    );

    [self dismissViewControllerAnimated:YES
                             completion:nil];
}

@end


void AZAuditPresentLogs(
    UIViewController *presentingViewController
) {

    if (presentingViewController == nil) {
        return;
    }

    AZAuditViewController *viewer =
        [[AZAuditViewController alloc] init];

    viewer.modalPresentationStyle =
        UIModalPresentationFullScreen;

    [presentingViewController
        presentViewController:viewer
                     animated:YES
                   completion:nil];
}


#pragma mark - Startup

__attribute__((constructor))
static void AZAuditInit(void) {

    @autoreleasepool {

        AZAuditWrite(
            @"SYSTEM",
            @"=============================="
        );

        AZAuditWrite(
            @"SYSTEM",
            @"AZGPS Audit session started"
        );

        AZAuditWrite(
            @"SYSTEM",
            [NSString stringWithFormat:
                @"LOG_PATH=%@",
                AZAuditLogFilePath()]
        );

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                AZAuditInstallUIHook();
            }
        );
    }
}
