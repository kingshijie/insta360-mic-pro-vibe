#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreAudio/CoreAudio.h>
#import "bridge.h"

static NSString *const enabledKey = @"BridgeEnabled";
static NSString *const loginSetupKey = @"LoginAgentConfigured";
static NSString *const doublePressKey = @"ReturnOnDoublePress";
static NSString *const languageKey = @"AppLanguage";
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
@property (strong) NSButton *doublePressToggle;
@property (strong) NSTextField *doublePressHint;
@property (strong) NSTextField *languageLabel;
@property (strong) NSPopUpButton *languagePicker;
@property (strong) NSBundle *translationBundle;
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
@property (nonatomic, copy) NSString *detailKey;
@property (copy) NSString *detailArgument;
@property (copy) NSString *lastStatus;
@end

@implementation MenuApp

- (NSString *)localized:(NSString *)english {
    return [self.translationBundle localizedStringForKey:english value:english table:nil] ?: english;
}

- (void)loadLanguage {
    NSString *language = [NSUserDefaults.standardUserDefaults stringForKey:languageKey];
    NSString *path = [language isEqualToString:@"zh-Hans"]
        ? [NSBundle.mainBundle pathForResource:@"zh-Hans" ofType:@"lproj"] : nil;
    self.translationBundle = path ? [NSBundle bundleWithPath:path] : nil;
}

- (NSString *)localizedDetail {
    NSString *message = [self localized:self.detailKey];
    return self.detailArgument ? [NSString stringWithFormat:message, self.detailArgument] : message;
}

- (void)setDetailKey:(NSString *)key {
    _detailKey = [key copy];
    self.detailArgument = nil;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    [prefs registerDefaults:@{enabledKey: @YES, doublePressKey: @YES, languageKey: @"en"}];
    [self loadLanguage];
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
    self.bridge.inject = NO;
    self.channel.delegate = nil;
    [self.channel closeChannel];
    self.channel = nil;
    self.bridge = nil;
    self.ready = NO;
}

- (BOOL)useInput:(AudioDeviceID)device {
    OSStatus result = setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, device);
    if (result) {
        self.detailKey = @"Could not switch the system microphone (%@).";
        self.detailArgument = [NSString stringWithFormat:@"%d", (int)result];
    }
    return result == noErr;
}

- (BOOL)restoreBuiltInInput {
    AudioDeviceID current = defaultDevice(kAudioHardwarePropertyDefaultInputDevice);
    if (current && current != self.blackHole && !isMic(audioName(current))) return YES;
    if (self.builtInMic) return [self useInput:self.builtInMic];
    self.detailKey = @"Could not find the Mac's built-in microphone.";
    return NO;
}

- (BOOL)keepMicOffSystemOutput {
    AudioObjectPropertySelector outputs[] = {
        kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice
    };
    for (NSUInteger i = 0; i < sizeof(outputs) / sizeof(*outputs); i++) {
        if (!isMic(audioName(defaultDevice(outputs[i])))) continue;
        if (self.speakers && !setDefaultDevice(outputs[i], self.speakers)) continue;
        self.detailKey = @"Could not switch system audio output from Mic Pro to the speakers.";
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
            self.detailKey = self.mic.isConnected
                ? @"No audio received. Retrying. Restart Mic Pro if the problem persists."
                : @"Bluetooth disconnected. Reconnecting…";
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
            self.detailKey = @"Connecting to Mic Pro…";
            IOReturn result = [self.mic openConnection:self withPageTimeout:0x2000 authenticationRequired:YES];
            if (result != kIOReturnSuccess && !self.mic.isConnected) {
                self.connecting = NO;
                self.detailKey = @"Could not connect. Make sure Mic Pro is on and nearby.";
            }
        }
    }
    if (!self.ready) [self restoreBuiltInInput];
    [self updateStatusAppearance];
    NSString *status = [NSString stringWithFormat:@"enabled=%d bluetooth=%d connected=%d blackHole=%d accessibility=%d ready=%d input=%@",
        self.enabled, self.bluetoothOn, self.mic.isConnected, self.blackHole != 0, self.accessible, self.ready,
        audioName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice)) ?: @"none"];
    if (![status isEqualToString:self.lastStatus]) {
        NSLog(@"%@", status);
        self.lastStatus = status;
    }
    if (self.settings.isVisible) [self updateLoginSettings];
}

- (void)updateStatusAppearance {
    NSString *name = [self localized:@"Vibe Mic Pro"];
    [self.statusItem.button setAccessibilityLabel:name];
    self.statusItem.button.image = (self.ready ? self.statusIcon : self.idleIcon) ?:
        [NSImage imageWithSystemSymbolName:(self.ready ? @"mic.fill" : @"mic.slash")
                  accessibilityDescription:name];
    self.statusItem.button.toolTip = self.ready ? [self localized:@"Vibe Mic Pro is ready"] : [self localized:@"Vibe Mic Pro · Show status"];
}

- (void)connectionComplete:(IOBluetoothDevice *)device status:(IOReturn)status {
    if (![device.addressString isEqualToString:self.mic.addressString]) return;
    self.connecting = NO;
    if (device.isConnected) self.nextAttempt = 0;
    else self.detailKey = @"Could not connect. Make sure Mic Pro is on and nearby.";
    [self refresh];
}

- (void)startBridge {
    Bridge *bridge = [Bridge new];
    bridge.returnOnDoublePress = [NSUserDefaults.standardUserDefaults boolForKey:doublePressKey];
    bridge.pending = [NSMutableData data];
    bridge.serialAudio = [SerialAudio new];
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    self.nextAttempt = now + 5;
    if (!bridge.serialAudio || ![bridge.serialAudio openLoopback]) {
        self.detailKey = @"BlackHole is installed, but its audio output could not be opened.";
        return;
    }
    IOBluetoothRFCOMMChannel *channel = nil;
    IOReturn result = [self.mic openRFCOMMChannelAsync:&channel withChannelID:serialChannel delegate:bridge];
    if (result != kIOReturnSuccess || !channel) {
        self.detailKey = @"Could not open the Mic Pro audio channel (%@).";
        self.detailArgument = [NSString stringWithFormat:@"0x%x", result];
        return;
    }
    self.bridge = bridge;
    self.channel = channel;
    self.channelDeadline = now + 9;
    self.detailKey = @"Waiting for Mic Pro audio…";
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
    [self addItem:self.ready ? [self localized:@"Vibe Mic Pro · Ready"] : [self localized:@"Vibe Mic Pro · Not ready"] action:NULL];
    [menu addItem:NSMenuItem.separatorItem];
    NSString *bluetooth = !self.bluetoothOn ? [self localized:@"Bluetooth · Turn On"] :
        self.mic.isConnected ? [self localized:@"Mic Pro · Connected"] :
        self.connecting ? [self localized:@"Mic Pro · Connecting"] :
        self.mic ? [self localized:@"Mic Pro · Connect"] : [self localized:@"Mic Pro · Pair in System Settings"];
    [self addItem:bluetooth action:self.bluetoothOn && self.mic.isConnected ? NULL : @selector(connectMic:)];
    [self addItem:self.blackHole ? [self localized:@"BlackHole 2ch · Installed"] : [self localized:@"BlackHole 2ch · Install"]
            action:self.blackHole ? NULL : @selector(installBlackHole:)];
    [self addItem:self.accessible ? [self localized:@"Accessibility · Allowed"] : [self localized:@"Accessibility · Allow"]
            action:self.accessible ? NULL : @selector(enableAccessibility:)];
    NSString *input = self.ready ? [self localized:@"Mic Pro (via BlackHole)"] : audioName(defaultDevice(kAudioHardwarePropertyDefaultInputDevice));
    [self addItem:[NSString stringWithFormat:[self localized:@"Current input · %@"], input ?: [self localized:@"None"]] action:NULL];
    [self addItem:[self localized:@"Doubao Settings · Right Option / Automatic microphone"] action:@selector(openDoubao:)];
    if (!self.ready && self.detailKey.length && self.enabled && self.blackHole && self.accessible && self.mic) {
        [self addItem:[self localizedDetail] action:NULL];
    }
    [menu addItem:NSMenuItem.separatorItem];
    [self addItem:!self.enabled ? [self localized:@"Enable Dictation"] : self.ready ? [self localized:@"Pause Dictation"] : [self localized:@"Check and Reconnect"]
            action:self.ready ? @selector(pause:) : @selector(enable:)];
    if (self.enabled && !self.ready) [self addItem:[self localized:@"Pause Auto-Connect"] action:@selector(pause:)];
    [self addItem:[self localized:@"Settings…"] action:@selector(showSettings:)];
    [self addItem:[self localized:@"Quit"] action:@selector(quit:)];
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
            NSLog(@"Doubao settings: %@", error);
            [self showError:[self localized:@"Could not open Doubao Input Method settings."]];
        });
    }];
}

- (void)showSettings:(id)sender {
    if (!self.settings) {
        self.settings = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 440, 220)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        self.settings.releasedWhenClosed = NO;
        self.languageLabel = [NSTextField labelWithString:@""];
        self.languagePicker = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [self.languagePicker addItemsWithTitles:@[@"English", @"简体中文"]];
        [self.languagePicker itemAtIndex:0].representedObject = @"en";
        [self.languagePicker itemAtIndex:1].representedObject = @"zh-Hans";
        self.languagePicker.target = self;
        self.languagePicker.action = @selector(changeLanguage:);
        [self.languagePicker selectItemAtIndex:self.translationBundle ? 1 : 0];
        NSStackView *languageRow = [NSStackView stackViewWithViews:@[self.languageLabel, self.languagePicker]];
        languageRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        languageRow.alignment = NSLayoutAttributeCenterY;

        self.loginToggle = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleLogin:)];
        self.loginStatus = [NSTextField wrappingLabelWithString:@""];
        self.loginStatus.textColor = NSColor.secondaryLabelColor;
        self.doublePressToggle = [NSButton checkboxWithTitle:@""
                                                      target:self action:@selector(toggleDoublePress:)];
        self.doublePressToggle.state = [NSUserDefaults.standardUserDefaults boolForKey:doublePressKey]
            ? NSControlStateValueOn : NSControlStateValueOff;
        self.doublePressHint = [NSTextField wrappingLabelWithString:@""];
        self.doublePressHint.textColor = NSColor.secondaryLabelColor;
        NSStackView *stack = [NSStackView stackViewWithViews:@[languageRow, self.loginToggle, self.loginStatus,
                                                             self.doublePressToggle, self.doublePressHint]];
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
            [self.loginStatus.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
            [self.doublePressHint.widthAnchor constraintLessThanOrEqualToAnchor:stack.widthAnchor],
        ]];
        [self.settings center];
    }
    [self updateSettingsLanguage];
    [NSApp activateIgnoringOtherApps:YES];
    [self.settings makeKeyAndOrderFront:nil];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)flag {
    [self showSettings:nil];
    return NO;
}

- (void)updateSettingsLanguage {
    self.settings.title = [self localized:@"Vibe Mic Pro Settings"];
    self.languageLabel.stringValue = [self localized:@"Language"];
    [self.languagePicker setAccessibilityLabel:self.languageLabel.stringValue];
    self.loginToggle.title = [self localized:@"Launch at Login"];
    self.doublePressToggle.title = [self localized:@"Double-press the power button to send Return"];
    self.doublePressHint.stringValue = [self localized:@"Wait for the text before double-pressing. This also toggles noise reduction."];
    [self updateLoginSettings];
}

- (void)changeLanguage:(NSPopUpButton *)sender {
    [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject forKey:languageKey];
    [self loadLanguage];
    [self updateSettingsLanguage];
    [self updateStatusAppearance];
}

- (void)updateLoginSettings {
    BOOL enabled = [NSFileManager.defaultManager fileExistsAtPath:loginAgentURL().path];
    self.loginToggle.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginStatus.stringValue = enabled ? [self localized:@"Starts when you log in and connects when Mic Pro is on."]
        : [self localized:@"Open Vibe Mic Pro from Applications when needed."];
}

- (void)toggleLogin:(NSButton *)sender {
    NSError *error = nil;
    BOOL changed = setLoginEnabled(sender.state == NSControlStateValueOn, &error);
    [self updateLoginSettings];
    if (!changed) {
        NSLog(@"Login item: %@", error);
        [self showError:[self localized:@"Could not update the login setting."]];
    }
}

- (void)toggleDoublePress:(NSButton *)sender {
    BOOL enabled = sender.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:doublePressKey];
    self.bridge.returnOnDoublePress = enabled;
}

- (void)showError:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = [self localized:@"Vibe Mic Pro"];
    alert.informativeText = message;
    [alert addButtonWithTitle:[self localized:@"OK"]];
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
