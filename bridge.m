#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import "bridge.h"

static const uint8_t powerClick[] = {0xfc, 0xef, 0xfd, 0x86, 0xff, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00};

// RFCOMM is a byte stream. Callbacks may split a frame or deliver several at once.
static NSUInteger takePowerClicks(NSMutableData *pending, const void *data, size_t length,
                                  SerialAudio *serialAudio, BOOL *audioReady) {
    [pending appendBytes:data length:length];
    const uint8_t *bytes = pending.bytes;
    NSUInteger pos = 0, clicks = 0;
    while (pending.length - pos >= 8) {
        const uint8_t *frame = bytes + pos;
        if (frame[0] != 0xfc || frame[1] != 0xef || frame[2] != 0xfd) {
            pos++;
            continue;
        }
        NSUInteger payloadLength = frame[6] | ((NSUInteger)frame[7] << 8);
        if (payloadLength > 4096) {
            pos++;
            continue;
        }
        NSUInteger frameLength = 8 + payloadLength;
        if (pending.length - pos < frameLength) break;
        if (frameLength == sizeof(powerClick) && memcmp(frame, powerClick, sizeof(powerClick)) == 0) {
            clicks++;
        }
        if (frame[3] == 0xf1 && frameLength == 402) {
            if ([serialAudio receiveFrame:frame]) *audioReady = YES;
        }
        pos += frameLength;
    }
    if (pos) [pending replaceBytesInRange:NSMakeRange(0, pos) withBytes:NULL length:0];
    return clicks;
}

static void postRightOptionClick(void) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0x3d, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0x3d, false);
    if (down && up) {
        CGEventSetType(down, kCGEventFlagsChanged);
        CGEventSetType(up, kCGEventFlagsChanged);
        CGEventFlags flags = CGEventSourceFlagsState(kCGEventSourceStateHIDSystemState);
        CGEventSetFlags(down, flags | kCGEventFlagMaskAlternate | NX_DEVICERALTKEYMASK);
        CGEventSetFlags(up, flags);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

@implementation Bridge
- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    if (status == kIOReturnSuccess) return;
    NSLog(@"RFCOMM open failed: 0x%x", status);
    self.finished = YES;
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    self.finished = YES;
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    BOOL audioReady = NO;
    NSUInteger clicks = takePowerClicks(self.pending, data, length, self.serialAudio, &audioReady);
    if (audioReady) self.lastSerialAudio = NSProcessInfo.processInfo.systemUptime;
    if (!self.inject || self.finished) return;
    for (NSUInteger i = 0; i < clicks; i++) {
        postRightOptionClick();
        NSLog(@"Mic Pro power click sent as Right Option");
    }
}
@end
