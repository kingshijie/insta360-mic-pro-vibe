#import "serial-audio.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <os/lock.h>
#include <lc3.h>

enum {
    sampleRate = 48000,
    frameDurationUS = 10000,
    samplesPerFrame = 480,
    samplesPerPacket = 1440,
    queueBufferFrames = 480,
    ringCapacity = 5760,
    initialBuffers = 3,
};

static CFStringRef copyBlackHoleUID(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) || !size) return NULL;
    NSMutableData *ids = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, ids.mutableBytes)) return NULL;
    const AudioDeviceID *devices = ids.bytes;
    for (NSUInteger i = 0; i < size / sizeof(*devices); i++) {
        CFStringRef name = NULL;
        UInt32 propertySize = sizeof(name);
        address.mSelector = kAudioObjectPropertyName;
        if (AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &propertySize, &name)) continue;
        BOOL matches = [CFBridgingRelease(name) isEqualToString:@"BlackHole 2ch"];
        if (!matches) continue;
        CFStringRef uid = NULL;
        address.mSelector = kAudioDevicePropertyDeviceUID;
        propertySize = sizeof(uid);
        if (!AudioObjectGetPropertyData(devices[i], &address, 0, NULL, &propertySize, &uid)) return uid;
    }
    return NULL;
}

@interface SerialAudio () {
    lc3_decoder_mem_48k_t _decoderMemory;
    lc3_decoder_t _decoder;
    AudioQueueRef _queue;
    AudioQueueBufferRef _buffers[initialBuffers];
    BOOL _started;
    os_unfair_lock _lock;
    int16_t _samples[ringCapacity];
    unsigned _read;
    unsigned _count;
}
- (OSStatus)enqueue:(AudioQueueBufferRef)buffer on:(AudioQueueRef)queue;
@end

static void refill(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    [(__bridge SerialAudio *)context enqueue:buffer on:queue];
}

@implementation SerialAudio
- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _decoder = lc3_setup_decoder(frameDurationUS, sampleRate, 0, &_decoderMemory);
    if (!_decoder) return nil;
    return self;
}

- (void)dealloc {
    if (_queue) AudioQueueDispose(_queue, true);
}

- (BOOL)openLoopback {
    CFStringRef uid = copyBlackHoleUID();
    if (!uid) {
        fputs("BlackHole 2ch is not installed or is not yet visible to Core Audio.\n", stderr);
        return NO;
    }
    AudioStreamBasicDescription format = {
        .mSampleRate = sampleRate,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        .mBytesPerPacket = 2 * sizeof(int16_t),
        .mFramesPerPacket = 1,
        .mBytesPerFrame = 2 * sizeof(int16_t),
        .mChannelsPerFrame = 2,
        .mBitsPerChannel = 16,
    };
    OSStatus status = AudioQueueNewOutput(&format, refill, (__bridge void *)self, NULL, NULL, 0, &_queue);
    if (!status) status = AudioQueueSetProperty(_queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
    CFRelease(uid);
    for (unsigned i = 0; !status && i < initialBuffers; i++) {
        status = AudioQueueAllocateBuffer(_queue, queueBufferFrames * format.mBytesPerFrame, &_buffers[i]);
    }
    if (status) fprintf(stderr, "Could not open BlackHole 2ch output (Core Audio status %d).\n", (int)status);
    return status == noErr;
}

- (OSStatus)enqueue:(AudioQueueBufferRef)buffer on:(AudioQueueRef)queue {
    int16_t *output = buffer->mAudioData;
    os_unfair_lock_lock(&_lock);
    unsigned available = MIN(queueBufferFrames, _count);
    for (unsigned i = 0; i < available; i++) {
        int16_t sample = _samples[(_read + i) % ringCapacity];
        output[2 * i] = sample;
        output[2 * i + 1] = sample;
    }
    _read = (_read + available) % ringCapacity;
    _count -= available;
    os_unfair_lock_unlock(&_lock);
    memset(output + 2 * available, 0, (queueBufferFrames - available) * 2 * sizeof(*output));
    buffer->mAudioDataByteSize = queueBufferFrames * 2 * sizeof(*output);
    return AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

- (BOOL)receiveFrame:(const uint8_t *)frame {
    // Each 402-byte packet carries three 10 ms LC3plus frames with 8-byte headers.
    for (unsigned offset = 18; offset <= 274; offset += 128) {
        if (memcmp(frame + offset + 4, "\x7a\x00\x78\x00", 4)) return NO;
    }
    int16_t pcm[samplesPerPacket];
    for (unsigned i = 0; i < 3; i++) {
        const uint8_t *payload = frame + 26 + i * 128;
        if (lc3_decode(_decoder, payload, 120, LC3_PCM_FORMAT_S16, pcm + i * samplesPerFrame, 1) < 0) return NO;
    }
    if (!_queue) return YES;
    os_unfair_lock_lock(&_lock);
    unsigned discarded = _count + samplesPerPacket > ringCapacity ? _count + samplesPerPacket - ringCapacity : 0;
    _read = (_read + discarded) % ringCapacity;
    _count -= discarded;
    unsigned write = (_read + _count) % ringCapacity;
    for (unsigned i = 0; i < samplesPerPacket; i++) _samples[(write + i) % ringCapacity] = pcm[i];
    _count += samplesPerPacket;
    os_unfair_lock_unlock(&_lock);

    if (!_started) {
        OSStatus status = noErr;
        for (unsigned i = 0; !status && i < initialBuffers; i++) status = [self enqueue:_buffers[i] on:_queue];
        if (!status) status = AudioQueueStart(_queue, NULL);
        if (status) {
            fprintf(stderr, "Could not start BlackHole 2ch output (Core Audio status %d).\n", (int)status);
            return NO;
        }
        _started = YES;
        puts("Mic Pro serial audio is reaching BlackHole 2ch. Select it in Doubao.");
    }
    return YES;
}
@end
