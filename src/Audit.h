#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT void AZAuditLogNSString(NSString *category, NSString *message);
FOUNDATION_EXPORT void AZAuditLogIntercept(NSString *hookName, NSString *result);
FOUNDATION_EXPORT void AZAuditLogLocation(NSString *source, CLLocation * _Nullable location);

FOUNDATION_EXPORT void AZAuditLogFeature(
    NSString *feature,
    NSString *status,
    NSString * _Nullable details
);

FOUNDATION_EXPORT void AZAuditLogState(
    NSString *source,
    NSDictionary *snapshot
);

FOUNDATION_EXPORT NSString *AZAuditLogFilePath(void);
FOUNDATION_EXPORT NSString *AZAuditReadAll(void);
FOUNDATION_EXPORT void AZAuditClear(void);

FOUNDATION_EXPORT void AZAuditPresentLogs(UIViewController *presentingViewController);

NS_ASSUME_NONNULL_END
