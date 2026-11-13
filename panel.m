#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import "bridge.h"

static NSString *const enabledKey = @"BridgeEnabled";
static NSString *const loginSetupKey = @"LoginAgentConfigured";
static NSString *const loginLabel = @"local.mc110.dictation.login";

static NSURL *loginAgentURL(void) {
    NSURL *home = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    return [home URLByAppendingPathComponent:@"Library/LaunchAgents/local.mc110.dictation.login.plist"];
}

static BOOL setLoginEnabled(BOOL enabled, NSError **error) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *url = loginAgentURL();
    if (!enabled) {
        return ![files fileExistsAtPath:url.path] || [files removeItemAtURL:url error:error];
    }
    if (![files createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES
                           attributes:nil error:error]) return NO;
    NSDictionary *job = @{
        @"Label": loginLabel,
        @"ProgramArguments": @[@"/usr/bin/open", @"-g", NSBundle.mainBundle.bundlePath],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @"Aqua",
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:job format:NSPropertyListXMLFormat_v1_0
                                                            options:0 error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}

static AudioObjectPropertyAddress audioProperty(AudioObjectPropertySelector selector) {
    return (AudioObjectPropertyAddress){selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
}

static NSString *audioName(AudioDeviceID device) {
    CFStringRef name = NULL;
    UInt32 size = sizeof(name);
    AudioObjectPropertyAddress address = audioProperty(kAudioObjectPropertyName);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &name)) return nil;
    return CFBridgingRelease(name);
}

static AudioDeviceID defaultDevice(AudioObjectPropertySelector selector) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = audioProperty(selector);
    AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    return device;
}

static OSStatus setDefaultDevice(AudioObjectPropertySelector selector, AudioDeviceID device) {
    if (device == defaultDevice(selector)) return noErr;
    AudioObjectPropertyAddress address = audioProperty(selector);
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(device), &device);
}

static BOOL isBuiltInDeviceWithStreams(AudioDeviceID device, AudioObjectPropertyScope scope) {
    UInt32 transport = 0;
    UInt32 size = sizeof(transport);
    AudioObjectPropertyAddress address = audioProperty(kAudioDevicePropertyTransportType);
    if (AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport) ||
        transport != kAudioDeviceTransportTypeBuiltIn) return NO;
    address.mSelector = kAudioDevicePropertyStreams;
    address.mScope = scope;
    return !AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size) && size > 0;
}

static void findAudioDevices(AudioDeviceID *blackHole, AudioDeviceID *speakers, AudioDeviceID *builtInMic) {
    *blackHole = *speakers = *builtInMic = kAudioObjectUnknown;
    AudioObjectPropertyAddress address = audioProperty(kAudioHardwarePropertyDevices);
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) || !size) return;
    NSMutableData *list = [NSMutableData dataWithLength:size];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, list.mutableBytes)) return;
    const AudioDeviceID *devices = list.bytes;
    for (NSUInteger i = 0; i < size / sizeof(*devices); i++) {
        NSString *name = audioName(devices[i]);
        if ([name isEqualToString:@"BlackHole 2ch"]) *blackHole = devices[i];
        if (!*builtInMic && isBuiltInDeviceWithStreams(devices[i], kAudioDevicePropertyScopeInput)) {
            *builtInMic = devices[i];
        }
        if (!*speakers && isBuiltInDeviceWithStreams(devices[i], kAudioDevicePropertyScopeOutput)) {
            *speakers = devices[i];
        }
    }
}

static BOOL isMic(NSString *name) {
    return [name hasPrefix:@"Insta360 Mic Pro TX"];
}

static void openSettings(NSString *page) {
    NSURL *url = [NSURL URLWithString:[@"x-apple.systempreferences:" stringByAppendingString:page]];
    [NSWorkspace.sharedWorkspace openURL:url];
}

@interface MenuApp : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSImage *statusIcon;
@property (strong) NSImage *idleIcon;
@property (strong) NSMenu *menu;
@property (strong) NSWindow *settings;
@property (strong) NSButton *loginToggle;
@property (strong) NSTextField *loginStatus;
@property (strong) NSTimer *timer;
@property (strong) IOBluetoothDevice *mic;
@property (strong) IOBluetoothRFCOMMChannel *channel;
@property (strong) Bridge *bridge;
@property BOOL enabled;
@property BOOL connecting;
@property BOOL bluetoothOn;
@property BOOL accessible;
@property BOOL ready;
@property AudioDeviceID blackHole;
@property AudioDeviceID speakers;
@property AudioDeviceID builtInMic;
@property NSTimeInterval nextAttempt;
@property NSTimeInterval connectionDeadline;
@property NSTimeInterval channelDeadline;
@property (copy) NSString *detail;
@property (copy) NSString *lastStatus;
@end

@implementation MenuApp

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    [prefs registerDefaults:@{enabledKey: @YES}];
    self.enabled = [prefs boolForKey:enabledKey];
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    NSImage *icon = [NSBundle.mainBundle imageForResource:@"MicProStatus"];
    if (icon) {
        NSSize size = NSMakeSize(20, 20);
        icon.size = size;
        self.statusIcon = icon;
        self.idleIcon = [NSImage imageWithSize:size flipped:NO drawingHandler:^BOOL(NSRect bounds) {
            [icon drawInRect:bounds fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:0.45];
            return YES;
        }];
    }
    self.menu = [NSMenu new];
    self.menu.delegate = self;
    self.menu.autoenablesItems = NO;
    self.statusItem.menu = self.menu;
    [self.statusItem.button setAccessibilityLabel:@"Mic Pro 听写"];
    if (![prefs boolForKey:loginSetupKey]) {
        NSError *error = nil;
        if (setLoginEnabled(YES, &error)) [prefs setBool:YES forKey:loginSetupKey];
        else NSLog(@"Login item: %@", error.localizedDescription);
    }
    [self refresh];
    self.timer = [NSTimer timerWithTimeInterval:2 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate];
    [self closeBridge];
    [self restoreBuiltInInput];
}

- (void)tick:(NSTimer *)timer { [self refresh]; }

- (void)closeBridge {
    self.channel.delegate = nil;
    [self.channel closeChannel];
    self.channel = nil;
    self.bridge = nil;
    self.ready = NO;
}

- (BOOL)useInput:(AudioDeviceID)device {
    OSStatus result = setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, device);
    if (result) self.detail = [NSString stringWithFormat:@"切换系统麦克风失败（%d）", (int)result];
    return result == noErr;
}

- (BOOL)restoreBuiltInInput {
    AudioDeviceID current = defaultDevice(kAudioHardwarePropertyDefaultInputDevice);
    if (current && current != self.blackHole && !isMic(audioName(current))) return YES;
    if (self.builtInMic) return [self useInput:self.builtInMic];
    self.detail = @"找不到 Mac 内置麦克风。";
    return NO;
}

- (BOOL)keepMicOffSystemOutput {
    AudioObjectPropertySelector outputs[] = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice
    };
    for (NSUInteger i = 0; i < sizeof(outputs) / sizeof(*outputs); i++) {
        if (!isMic(audioName(defaultDevice(outputs[i])))) continue;
        if (self.speakers && !setDefaultDevice(outputs[i], self.speakers)) continue;
        self.detail = @"无法将系统输出从 Mic Pro 切回扬声器。";
        return NO;
    }
    return YES;
}

- (void)refresh {
    AudioDeviceID blackHole, speakers, builtInMic;
    findAudioDevices(&blackHole, &speakers, &builtInMic);
    self.blackHole = blackHole;
    self.speakers = speakers;
    self.builtInMic = builtInMic;
    self.accessible = CGPreflightPostEventAccess();
    self.bluetoothOn = IOBluetoothHostController.defaultController.powerState == kBluetoothHCIPowerStateON;
    if (self.bluetoothOn && !self.channel && !self.connecting && !self.mic.isConnected) {
        NSArray *devices = IOBluetoothDevice.pairedDevices;
        self.mic = nil;
        for (IOBluetoothDevice *device in devices) {
            if (!isMic(device.name)) continue;
            if (!self.mic || device.isConnected) self.mic = device;
            if (device.isConnected) break;
        }
    }

    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (self.connecting && (self.mic.isConnected || now >= self.connectionDeadline || !self.bluetoothOn)) {
        self.connecting = NO;
    }
    if (!self.enabled || !self.bluetoothOn || !self.accessible || !self.blackHole || !self.mic) {
        [self closeBridge];
    } else if (self.bridge) {
        BOOL audioFresh = self.bridge.lastSerialAudio > 0 && now - self.bridge.lastSerialAudio < 5;
        if (!self.mic.isConnected || self.bridge.finished ||
            (!audioFresh && now > self.channelDeadline)) {
            self.detail = self.mic.isConnected
                ? @"未收到串口音频，正在重试。持续无声时请重启 Mic Pro。"
                : @"蓝牙已断开，正在重连。";
            [self closeBridge];
            self.nextAttempt = now + 5;
        } else {
            self.ready = audioFresh && [self keepMicOffSystemOutput] && [self useInput:self.blackHole];
            self.bridge.inject = self.ready;
        }
    } else if (now >= self.nextAttempt && !self.connecting) {
        if (self.mic.isConnected) {
            if ([self restoreBuiltInInput] && [self keepMicOffSystemOutput]) [self startBridge];
            else self.nextAttempt = now + 5;
        } else {
            self.connecting = YES;
            self.connectionDeadline = now + 8;
            self.nextAttempt = now + 12;
            self.detail = @"正在连接 Mic Pro。";
            IOReturn result = [self.mic openConnection:self withPageTimeout:0x2000 authenticationRequired:YES];
            if (result != kIOReturnSuccess && !self.mic.isConnected) {
                self.connecting = NO;
                self.detail = @"连接暂未成功。请确认 Mic Pro 已开机并在附近。";
            }
        }
    }
    if (!self.ready) [self restoreBuiltInInput];
    self.statusItem.button.image = (self.ready ? self.statusIcon : self.idleIcon) ?:
        [NSImage imageWithSystemSymbolName:(self.ready ? @"mic.fill" : @"mic.slash")
                  accessibilityDescription:@"Mic Pro 听写"];
    self.statusItem.button.toolTip = self.ready ? @"Mic Pro 听写已就绪" : @"Mic Pro 听写 · 点击查看状态";
    NSString *status = [NSString stringWithFormat:@"enabled=%d bluetooth=%d connected=%d blackHole=%d accessibility=%d ready=%d input=%@",
        self.enabled, self.bluetoothOn, self.mic.isConnected, self.blackHole != 0, self.accessible, self.ready,
        audioName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) ?: @"无"];
    if (![status isEqualToString:self.lastStatus]) {
        NSLog(@"%@", status);
        self.lastStatus = status;
    }
    if (self.settings.isVisible) [self updateLoginSettings];
}

- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (![device.addressString isEqualToString:self.mic.addressString]) return;
    self.connecting = NO;
    if (device.isConnected) self.nextAttempt = 0;
    else self.detail = @"连接暂未成功。请确认 Mic Pro 已开机并在附近。";
    [self refresh];
}

- (void)startBridge {
    Bridge *bridge = [Bridge new];
    bridge.pending = [NSMutableData data];
    bridge.serialAudio = [SerialAudio new];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    self.nextAttempt = now + 5;
    if (!bridge.serialAudio || ![bridge.serialAudio openLoopback]) {
        self.detail = @"BlackHole 已安装，但无法打开音频输出。";
        return;
    }
    IOBluetoothRFCOMMChannel *channel = nil;
    IOReturn result = [self.mic openRFCOMMChannelAsync:&channel withChannelID:serialChannel delegate:bridge];
    if (result != kIOReturnSuccess || !channel) {
        self.detail = [NSString stringWithFormat:@"无法打开 Mic Pro 音频通道（0x%x）。", result];
        return;
    }
    self.bridge = bridge;
    self.channel = channel;
    self.channelDeadline = now + 9;
    self.detail = @"正在等待 Mic Pro 音频。";
}

- (void)addItem:(NSString *)title action:(SEL)action {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self;
    item.enabled = action != NULL;
    [self.menu addItem:item];
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [self refresh];
    [menu removeAllItems];
    [self addItem:self.ready ? @"Mic Pro 听写 · 已就绪" : @"Mic Pro 听写 · 未就绪" action:NULL];
    [menu addItem:NSMenuItem.separatorItem];
    NSString *bluetooth = !self.bluetoothOn ? @"蓝牙 · 启用" :
        self.mic.isConnected ? @"Mic Pro · 已连接" :
        self.connecting ? @"Mic Pro · 正在连接" :
        self.mic ? @"Mic Pro · 连接" : @"Mic Pro · 前往配对";
    [self addItem:bluetooth action:self.bluetoothOn && self.mic.isConnected ? NULL : @selector(connectMic:)];
    [self addItem:self.blackHole ? @"BlackHole 2ch · 已安装" : @"BlackHole 2ch · 安装"
            action:self.blackHole ? NULL : @selector(installBlackHole:)];
    [self addItem:self.accessible ? @"辅助功能 · 已启用" : @"辅助功能 · 启用"
            action:self.accessible ? NULL : @selector(enableAccessibility:)];
    NSString *input = self.ready ? @"Mic Pro（经 BlackHole）" : audioName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice));
    [self addItem:[@"当前输入 · " stringByAppendingString:input ?: @"无"] action:NULL];
    [self addItem:@"豆包设置 · 右 Option 免按 / 自动检测" action:@selector(openDoubao:)];
    if (!self.ready && self.detail.length && self.enabled && self.blackHole && self.accessible && self.mic) {
        [self addItem:self.detail action:NULL];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:!self.enabled ? @"启用听写" : self.ready ? @"暂停听写" : @"重新检查并连接"
            action:self.ready ? @selector(pause:) : @selector(enable:)];
    if (self.enabled && !self.ready) [self addItem:@"暂停自动连接" action:@selector(pause:)];
    [self addItem:@"设置…" action:@selector(showSettings:)];
    [self addItem:@"退出" action:@selector(quit:)];
}

- (void)enable:(id)sender {
    self.enabled = YES;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:enabledKey];
    self.nextAttempt = 0;
    [self refresh];
    if (!self.accessible) [self enableAccessibility:nil];
    else if (!self.bluetoothOn || !self.mic) [self connectMic:nil];
    else if (!self.blackHole) [self installBlackHole:nil];
}

- (void)pause:(id)sender {
    self.enabled = NO;
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:enabledKey];
    [self refresh];
}

- (void)connectMic:(id)sender {
    if (!self.bluetoothOn || !self.mic) {
        openSettings(@"com.apple.BluetoothSettings");
        return;
    }
    self.enabled = YES;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:enabledKey];
    self.nextAttempt = 0;
    [self refresh];
    if (!self.accessible) [self enableAccessibility:nil];
    else if (!self.blackHole) [self installBlackHole:nil];
}

- (void)enableAccessibility:(id)sender {
    AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)@{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES});
    openSettings(@"com.apple.preference.security?Privacy_Accessibility");
}

- (void)installBlackHole:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://existential.audio/blackhole/"]];
}

- (void)openDoubao:(id)sender {
    NSString *path = @"/Library/Input Methods/DoubaoIme.app/Contents/Applications/DoubaoImeSettings.app";
    NSURL *url = [NSURL fileURLWithPath:path];
    [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:NSWorkspaceOpenConfiguration.configuration
                                   completionHandler:^(__unused NSRunningApplication *app, NSError *error) {
        if (error) dispatch_async(dispatch_get_main_queue(), ^{
            [self showError:error.localizedDescription];
        });
    }];
}

- (void)showSettings:(id)sender {
    if (!self.settings) {
        self.settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 400, 122)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        self.settings.releasedWhenClosed = NO;
        self.settings.title = @"Mic Pro 听写设置";
        self.loginToggle = [NSButton checkboxWithTitle:@"登录后自动启动" target:self action:@selector(toggleLogin:)];
        self.loginStatus = [NSTextField wrappingLabelWithString:@""];
        self.loginStatus.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack = [NSStackView stackViewWithViews:@[self.loginToggle, self.loginStatus]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 9;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        NSView *content = self.settings.contentView;
        [content addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:22],
            [stack.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-22],
            [stack.topAnchor constraintEqualToAnchor:content.topAnchor constant:22],
        ]];
        [self.settings center];
    }
    [self updateLoginSettings];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settings makeKeyAndOrderFront:nil];
}

- (void)updateLoginSettings {
    BOOL enabled = [NSFileManager.defaultManager fileExistsAtPath:loginAgentURL().path];
    self.loginToggle.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginStatus.stringValue = enabled ? @"登录 macOS 后启动，并在 Mic Pro 开机时自动连接。"
        : @"你仍可从「应用程序」打开 Mic Pro 听写。";
}

- (void)toggleLogin:(NSButton *)sender {
    NSError *error = nil;
    BOOL changed = setLoginEnabled(sender.state == NSControlStateValueOn, &error);
    [self updateLoginSettings];
    if (!changed) [self showError:error.localizedDescription ?: @"无法更新登录自启动。"];
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Mic Pro 听写";
    alert.informativeText = message;
    [alert runModal];
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MenuApp *delegate = [MenuApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
