#import <Cocoa/Cocoa.h>
#import "TX500CWStationController.h"

@interface TX500CWStationController (SelectionTests)
- (void)audioDeviceChanged:(id)sender;
- (void)updateAudioDeviceMenu;
@end

// Exercise selection and restart decisions without recording audio or requesting TCC access.
@interface SelectionDecoder : TX500CWAudioDecoder
@property BOOL testListening;
@property NSUInteger starts;
@property NSUInteger stops;
@end
@implementation SelectionDecoder
- (NSArray *)availableAudioInputDevices {
    return @[@{@"uid": TX500CWSystemAudioDeviceUID, @"displayName": @"System Audio (Direct)"},
             @{@"uid": @"test-usb", @"displayName": @"Test USB input"}];
}
- (BOOL)isListening { return self.testListening; }
- (void)startListening { self.starts++; self.testListening = YES; }
- (void)stopListening { self.stops++; self.testListening = NO; }
- (void)refreshAudioDevices {}
@end

static NSUInteger checks;
static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static NSPopUpButton *Popup(TX500CWStationController *c) { return [c valueForKey:@"audioDevicePopup"]; }
static NSMenuItem *Item(TX500CWStationController *c, NSString *uid) {
    for (NSMenuItem *item in Popup(c).itemArray) if ([item.representedObject isEqual:uid]) return item;
    return nil;
}

int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSString *key = @"TX500_CW_InputDeviceUID";
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        TX500CWStationController *c = [TX500CWStationController new];
        if (@available(macOS 14.2, *)) {
            Check([c.decoder.selectedAudioDeviceUID isEqual:TX500CWSystemAudioDeviceUID], @"System Audio is the initial CW input");
        }
        NSString *initial = c.decoder.selectedAudioDeviceUID;
        [c applyStationInputDeviceUID:@""];
        Check([c.decoder.selectedAudioDeviceUID isEqual:initial], @"Empty station profile cannot erase the CW default");
        [c applyStationInputDeviceUID:@"test-usb"];
        Check([c.decoder.selectedAudioDeviceUID isEqual:@"test-usb"], @"A configured station supplies an initial default");

        SelectionDecoder *decoder = [SelectionDecoder new];
        decoder.selectedAudioDeviceUID = @"test-usb";
        [c setValue:decoder forKey:@"decoder"];
        [c updateAudioDeviceMenu];
        NSMenuItem *system = Item(c, TX500CWSystemAudioDeviceUID);
        Check(system != nil, @"System Audio menu entry exists");
        Check([NSApp sendAction:system.action to:system.target from:system], @"Native menu item action dispatch succeeds");
        Check([decoder.selectedAudioDeviceUID isEqual:TX500CWSystemAudioDeviceUID], @"Menu item selects the direct system audio route");
        Check([Popup(c).selectedItem.representedObject isEqual:decoder.selectedAudioDeviceUID], @"Visible selection matches decoder route");
        Check(decoder.starts == 0 && decoder.stops == 1, @"Idle selection cancels pending capture without starting capture");
        Check(decoder.preserveDeviceSelection, @"Selection remains explicit across device refresh");
        [c applyStationInputDeviceUID:@"test-usb"];
        [c applyStationInputDeviceUID:@""];
        Check([decoder.selectedAudioDeviceUID isEqual:TX500CWSystemAudioDeviceUID], @"Station changes cannot overwrite a local CW selection");
        Check([[NSUserDefaults.standardUserDefaults stringForKey:key] isEqual:TX500CWSystemAudioDeviceUID], @"Selection is persisted");
        TX500CWStationController *reopened = [TX500CWStationController new];
        Check([reopened.decoder.selectedAudioDeviceUID isEqual:TX500CWSystemAudioDeviceUID], @"Recreated controller restores System Audio");
        [reopened applyStationInputDeviceUID:@"another-profile"];
        Check([reopened.decoder.selectedAudioDeviceUID isEqual:TX500CWSystemAudioDeviceUID], @"Restored selection still overrides profiles");

        decoder.testListening = YES;
        [Popup(c) selectItem:Item(c, @"test-usb")];
        [NSApp sendAction:Popup(c).action to:Popup(c).target from:Popup(c)];
        Check([decoder.selectedAudioDeviceUID isEqual:@"test-usb"], @"Popup sender also selects correctly");
        Check(decoder.starts == 1 && decoder.stops == 2, @"Live input changes stop and restart exactly once");
        [c audioDeviceChanged:Popup(c)];
        Check(decoder.starts == 1 && decoder.stops == 2, @"Reselecting current input does not interrupt audio");
        decoder.isSimulationActive = YES;
        [c audioDeviceChanged:Item(c, TX500CWSystemAudioDeviceUID)];
        Check(decoder.starts == 1 && decoder.stops == 2, @"Practice selection does not start real capture");
        decoder.isSimulationActive = NO;
        decoder.testListening = NO;
        decoder.selectedAudioDeviceUID = @"disconnected-device";
        [c updateAudioDeviceMenu];
        Check([Popup(c).title containsString:@"unavailable"], @"Disconnected route is shown as unavailable");
        Check(Popup(c).selectedItem.representedObject == nil, @"Unavailable route never masquerades as another device");
        [c audioDeviceChanged:Item(c, @"__REFRESH__")];
        Check([decoder.selectedAudioDeviceUID isEqual:@"disconnected-device"], @"Refresh cannot silently change route");
        [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
        NSLog(@"PASS: %lu CW audio selection checks (no audio capture).", (unsigned long)checks);
    }
    return 0;
}
