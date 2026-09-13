#import <Foundation/Foundation.h>

@interface AZUIController : NSObject

+ (instancetype)sharedController;
- (void)installWhenReady;

@end