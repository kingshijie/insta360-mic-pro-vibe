#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "serial-audio.h"

enum { serialChannel = 12 };

@interface Bridge : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property (nonatomic) BOOL inject;
@property (nonatomic) BOOL returnOnDoublePress;
@property BOOL finished;
@property NSTimeInterval lastSerialAudio;
@property (strong) NSMutableData *pending;
@property (strong) SerialAudio *serialAudio;
@end
