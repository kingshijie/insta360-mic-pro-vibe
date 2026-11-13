#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import "serial-audio.h"

enum { serialChannel = 12 };

@interface Bridge : NSObject <IOBluetoothRFCOMMChannelDelegate>
@property BOOL inject;
@property BOOL finished;
@property NSTimeInterval lastSerialAudio;
@property (strong) NSMutableData *pending;
@property (strong) SerialAudio *serialAudio;
@end
