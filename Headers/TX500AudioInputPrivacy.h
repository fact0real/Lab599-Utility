#import <Cocoa/Cocoa.h>
#import <CoreAudio/CoreAudio.h>

// Only called for an explicitly selected, enumerated input, before opening an audio queue.
// Built-in inputs hear the room. Permission is per start, never persisted or inferred from macOS consent.
static inline BOOL TX500ConfirmSelectedInput(NSString *uid, NSError **error) {
    CFStringRef uidRef=(__bridge CFStringRef)uid;
    AudioValueTranslation translation={&uidRef,sizeof(uidRef),NULL,0};
    AudioDeviceID device=kAudioObjectUnknown;
    translation.mOutputData=&device; translation.mOutputDataSize=sizeof(device);
    AudioObjectPropertyAddress address={kAudioHardwarePropertyDeviceForUID,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 size=sizeof(translation);
    if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&address,0,NULL,&size,&translation)!=noErr || device==kAudioObjectUnknown) {
        if(error) *error=[NSError errorWithDomain:@"TX500AudioErrorDomain" code:2 userInfo:@{NSLocalizedDescriptionKey:@"The selected receive input is unavailable. Choose a connected input in Station Profiles."}];
        return NO;
    }
    UInt32 transport=0; size=sizeof(transport);
    address.mSelector=kAudioDevicePropertyTransportType;
    if(AudioObjectGetPropertyData(device,&address,0,NULL,&size,&transport)!=noErr) {
        if(error) *error=[NSError errorWithDomain:@"TX500AudioErrorDomain" code:3 userInfo:@{NSLocalizedDescriptionKey:@"The selected input could not be identified. Choose the radio input in Station Profiles."}];
        return NO;
    }
    if(transport!=kAudioDeviceTransportTypeBuiltIn) return YES;
    BOOL accepted=NO;
    if(NSThread.isMainThread && !NSProcessInfo.processInfo.environment[@"TX500_TEST_MODE"].boolValue) {
        NSAlert *alert=[NSAlert new];
        alert.messageText=@"Open the Mac's own microphone?";
        alert.informativeText=@"This built-in input hears the room, not the radio. Listening or recording will capture that sound. Use the radio's input for radio reception.";
        [alert addButtonWithTitle:@"Cancel"];
        [alert addButtonWithTitle:@"Open the Mac's microphone"];
        accepted=[alert runModal]==NSAlertSecondButtonReturn;
    }
    if(!accepted && error) *error=[NSError errorWithDomain:@"TX500AudioErrorDomain" code:4 userInfo:@{NSLocalizedDescriptionKey:@"The Mac's microphone was not opened. Choose the radio's input, or confirm opening the built-in input from the listening screen."}];
    return accepted;
}
