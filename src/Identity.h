#import <Foundation/Foundation.h>
void AZInstallIdentityHook(void);
NSString *AZCurrentIdentity(void);
BOOL AZSetIdentity(NSString *value);
void AZRestoreIdentity(void);
BOOL AZIdentityEnabled(void);
NSString *AZSavedIdentity(void);
