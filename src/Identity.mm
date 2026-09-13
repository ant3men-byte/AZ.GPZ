#import "Identity.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "Audit.h"

static NSUUID *(*AZOriginalIdentifierForVendor)(id,SEL);
static NSString *const AZIdentityValueKey=@"AZ.GPS.identity.uuid";
static NSString *const AZIdentityEnabledKey=@"AZ.GPS.identity.enabled";

BOOL AZIdentityEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:AZIdentityEnabledKey];
}
NSString *AZSavedIdentity(void) {
    return [NSUserDefaults.standardUserDefaults stringForKey:AZIdentityValueKey] ?: @"";
}
static NSUUID *AZIdentityGetter(id device,SEL selector) {
    if(AZIdentityEnabled()){
        NSUUID *uuid=[[NSUUID alloc]initWithUUIDString:AZSavedIdentity()];
        if(uuid)return uuid;
    }
    return AZOriginalIdentifierForVendor?AZOriginalIdentifierForVendor(device,selector):nil;
}
void AZInstallIdentityHook(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        Method method=class_getInstanceMethod(UIDevice.class,@selector(identifierForVendor));
        if(!method){AZAuditLogFeature(@"identityHook",@"ERROR",@"identifierForVendor unavailable");return;}
        AZOriginalIdentifierForVendor=(NSUUID *(*)(id,SEL))method_getImplementation(method);
        method_setImplementation(method,(IMP)AZIdentityGetter);
        AZAuditLogFeature(@"identityHook",@"SUCCESS",@"identifierForVendor hook installed");
    });
}
NSString *AZCurrentIdentity(void) {
    return UIDevice.currentDevice.identifierForVendor.UUIDString ?: @"";
}
BOOL AZSetIdentity(NSString *value) {
    AZInstallIdentityHook();
    if(!AZOriginalIdentifierForVendor)return NO;
    NSUUID *uuid=[[NSUUID alloc]initWithUUIDString:[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    if(!uuid)return NO;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [defaults setObject:uuid.UUIDString forKey:AZIdentityValueKey];
    [defaults setBool:YES forKey:AZIdentityEnabledKey];
    AZAuditLogFeature(@"deviceIdentity",@"SUCCESS",@"Replacement enabled for future identifierForVendor reads");
    return YES;
}
void AZRestoreIdentity(void) {
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:AZIdentityEnabledKey];
    AZAuditLogFeature(@"deviceIdentity",@"SUCCESS",@"Original identifierForVendor passthrough restored");
}
