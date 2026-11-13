#import <Foundation/Foundation.h>

@interface SerialAudio : NSObject
- (BOOL)openLoopback;
- (BOOL)receiveFrame:(const uint8_t *)frame;
@end
