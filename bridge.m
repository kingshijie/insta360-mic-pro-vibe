#import <ApplicationServices/ApplicationServices.h>
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOBluetooth/IOBluetooth.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#import "bridge.h"

static const uint8_t powerClick[] = {0xfc, 0xef, 0xfd, 0x86, 0xff, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00};
// The firmware reports its new noise reduction state after a power-button double press.
static const uint8_t noiseReductionHeader[] = {0xfc, 0xef, 0xfd, 0xf3, 0xff, 0x00, 0x06, 0x00, 0x05, 0x04};

@interface Bridge ()
@property pid_t dictationPID;
@property NSTimeInterval returnDeadline;
@end

// RFCOMM is a byte stream. Callbacks may split a frame or deliver several at once.
static BOOL isNoiseReductionReport(const uint8_t *frame, NSUInteger length) {
    return length == 14 && memcmp(frame, noiseReductionHeader, sizeof(noiseReductionHeader)) == 0 &&
        frame[10] <= 1 && frame[11] == 0 && frame[12] == 0 && frame[13] == 0;
}

static void takeFrames(NSMutableData *pending, const void *data, size_t length,
                       void (^handleFrame)(const uint8_t *, NSUInteger)) {
    [pending appendBytes:data length:length];
    const uint8_t *bytes = pending.bytes;
    NSUInteger pos = 0;
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
        handleFrame(frame, frameLength);
        pos += frameLength;
    }
    if (pos) [pending replaceBytesInRange:NSMakeRange(0, pos) withBytes:NULL length:0];
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

static void postReturnToApp(pid_t pid) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0x24, true);
    CGEventRef up = CGEventCreateKeyboardEvent(NULL, 0x24, false);
    if (down && up) {
        CGEventSetFlags(down, 0);
        CGEventSetFlags(up, 0);
        CGEventPostToPid(pid, down);
        CGEventPostToPid(pid, up);
        NSLog(@"Mic Pro double press sent as Return");
    }
    if (down) CFRelease(down);
    if (up) CFRelease(up);
}

@implementation Bridge
- (void)setInject:(BOOL)inject {
    _inject = inject;
    if (!inject) {
        self.dictationPID = 0;
        self.returnDeadline = 0;
    }
}

- (void)setReturnOnDoublePress:(BOOL)enabled {
    _returnOnDoublePress = enabled;
    if (!enabled) {
        self.dictationPID = 0;
        self.returnDeadline = 0;
    }
}

- (void)rfcommChannelOpenComplete:(IOBluetoothRFCOMMChannel *)channel status:(IOReturn)status {
    if (status == kIOReturnSuccess) return;
    NSLog(@"RFCOMM open failed: 0x%x", status);
    self.finished = YES;
}

- (void)rfcommChannelClosed:(IOBluetoothRFCOMMChannel *)channel {
    self.inject = NO;
    self.finished = YES;
}

- (void)rfcommChannelData:(IOBluetoothRFCOMMChannel *)channel data:(void *)data length:(size_t)length {
    takeFrames(self.pending, data, length, ^(const uint8_t *frame, NSUInteger size) {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (frame[3] == 0xf1 && size == 402) {
            if ([self.serialAudio receiveFrame:frame]) self.lastSerialAudio = now;
            return;
        }
        if (!self.inject || self.finished) return;
        if (size == sizeof(powerClick) && memcmp(frame, powerClick, size) == 0) {
            if (self.returnOnDoublePress) {
                pid_t pid = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
                BOOL isSecondPress = pid > 0 && self.dictationPID == pid && self.returnDeadline == 0;
                self.dictationPID = pid;
                self.returnDeadline = isSecondPress ? now + 20 : 0;
            }
            postRightOptionClick();
            NSLog(@"Mic Pro power click sent as Right Option");
        } else if (self.returnOnDoublePress && self.returnDeadline > now &&
                   isNoiseReductionReport(frame, size)) {
            pid_t pid = self.dictationPID;
            self.returnDeadline = 0;
            self.dictationPID = 0;
            if (pid > 0 && pid == NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier) {
                postReturnToApp(pid);
            }
        }
    });
}
@end
