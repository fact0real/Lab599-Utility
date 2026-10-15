//
//  TX500CWStationController.m
//  Lab599 Utility
//
//  Complete CW Workstation & Semi-Automated QSO Studio Controller
//

#import "TX500CWStationController.h"
#import "TX500FT8AudioEngine.h"
#import "TX500LogbookManager.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const CWInputPreferenceKey = @"TX500_CW_InputDeviceUID";

// The band selector's segments, in order.
static NSArray<NSString *> *CWBandSelectorNames(void) {
    return @[@"160m", @"80m", @"40m", @"30m", @"20m", @"17m", @"15m", @"12m", @"10m", @"6m"];
}

@interface TX500CWVFOTextField : NSTextField
@property (nonatomic, copy, nullable) void (^onScrolled)(NSInteger deltaUnits);
@end

@implementation TX500CWVFOTextField
- (void)scrollWheel:(NSEvent *)event {
    if (self.onScrolled) {
        CGFloat dy = event.scrollingDeltaY;
        if (fabs(dy) > 0.1) {
            NSInteger step = (dy > 0) ? 1 : -1;
            self.onScrolled(step);
            return;
        }
    }
    [super scrollWheel:event];
}
@end

@interface TX500CWStationController ()

@property (nonatomic, strong, readwrite) NSView *view;
@property (nonatomic, strong, readwrite) TX500CWAudioDecoder *decoder;
@property (nonatomic, strong, readwrite) TX500CWKeyer *keyer;
@property (nonatomic, strong, readwrite) TX500CWQSOAssistant *assistant;
@property (nonatomic, strong, readwrite) TX500AudioEngine *audioEngine;
// The radio transmit output last named in the console (one line per change).
@property (nonatomic, assign) BOOL radioAudioTargetReported;
@property (nonatomic, copy, nullable) NSString *reportedRadioAudioTargetUID;

// Audio Monitor Controls
@property (nonatomic, strong) NSButton *monitorToggleButton;
@property (nonatomic, strong) NSSlider *monitorVolumeSlider;
@property (nonatomic, strong) NSButton *monitorMuteButton;
@property (nonatomic, strong) NSButton *cwNarrowFilterButton;
@property (nonatomic, assign, readwrite) BOOL isMonitoringAudio;

// Recording Controls
@property (nonatomic, strong) NSButton *recordButton;
@property (nonatomic, strong) NSTextField *recordStatusLabel;
@property (nonatomic, strong) NSButton *revealRecordingsButton;
@property (nonatomic, strong) NSButton *autoRecordCheckbox;
@property (nonatomic, strong, nullable) NSTimer *recordTimer;
@property (nonatomic, assign) NSTimeInterval recordSeconds;
@property (nonatomic, assign, readwrite) BOOL isRecordingAudio;

// VFO & Tuning Controls
@property (nonatomic, strong) TX500CWVFOTextField *vfoLabel;
@property (nonatomic, strong) NSTextField *vfoOffsetLabel;
@property (nonatomic, strong) NSButton *stepDownButton;
@property (nonatomic, strong) NSButton *stepUpButton;
@property (nonatomic, strong) NSSegmentedControl *vfoStepControl;
@property (nonatomic, assign) int64_t currentTuningStepHz;

// Amateur Band Selector Controls
@property (nonatomic, strong) NSSegmentedControl *bandSelectorControl;
@property (nonatomic, assign) NSTimeInterval userTuningLockoutUntil;

// Multi-Channel Roster Controls
@property (nonatomic, strong) NSSegmentedControl *rosterModeControl;
@property (nonatomic, strong) NSMutableArray<TX500CWChannelState *> *widebandChannels;

// UI Controls - Top Bar
@property (nonatomic, strong) NSButton *startStopDecoderButton;
@property (nonatomic, strong) NSPopUpButton *audioDevicePopup;
@property (nonatomic) BOOL hasLocalAudioSelection;
@property (nonatomic, strong) NSButton *simulationCheckbox;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong, nullable) NSTimer *autoCQMonitorTimer;
// The last RX; was not confirmed by the radio. Atomic: the keyer's time-out sends its RX; from its own
// queue, so this is written off the main thread too, and read on the main thread.
@property (atomic, assign) BOOL releaseNotConfirmed;
@property (nonatomic, strong) NSSlider *pitchSlider;
@property (nonatomic, strong) NSTextField *pitchValueLabel;
@property (nonatomic, strong) NSButton *afcCheckbox;
@property (nonatomic, assign) BOOL cwModeConfiguredOnRadio;
@property (nonatomic, strong) NSStepper *wpmStepper;
@property (nonatomic, strong) NSTextField *wpmLabel;
@property (nonatomic, strong) NSButton *cutNumbersCheckbox;

// UI Controls - Spectrum & Metrics
@property (nonatomic, strong) TX500CWSpectrumView *spectrumView;
@property (nonatomic, strong) NSTextField *carrierLockStatusLabel;
@property (nonatomic, strong) NSTextField *wpmMetricLabel;
@property (nonatomic, strong) NSTextField *snrMetricLabel;
@property (nonatomic, strong) NSTextField *ditDahMetricLabel;
@property (nonatomic, strong) NSTextField *activeDitDahLabel;

// UI Controls - Decoded Terminal
@property (nonatomic, strong) NSTextView *terminalTextView;
@property (nonatomic, strong) NSButton *clearTerminalButton;

// UI Controls - CQ Roster Table
@property (nonatomic, strong) NSTableView *cqRosterTableView;

// UI Controls - QSO Co-Pilot
@property (nonatomic, strong) NSTextField *qsoStateLabel;
@property (nonatomic, strong) NSButton *qsoNextActionButton;
@property (nonatomic, strong) NSButton *autoCQButton;
@property (nonatomic, strong) NSTextField *autoCQCountdownLabel;
@property (nonatomic, strong) NSTextField *txInputField;
@property (nonatomic, strong) NSButton *txSendButton;
@property (nonatomic, strong) NSButton *txTuneButton;
@property (nonatomic, strong) NSButton *txAbortButton;
@property (nonatomic, assign, readwrite) BOOL isManualTuneActive;
@property (nonatomic, assign) double manualTuneCutoffSeconds; // 0 = the 10 s default; tests shorten it
@property (nonatomic, assign) NSUInteger manualTuneGeneration;   // each Tune's cutoff stops only that Tune
@property (nonatomic, strong) NSMutableArray<NSButton *> *macroButtons;

// UI Controls - Live Transmit Telemetry (PWR & SWR)
@property (nonatomic, strong) NSTextField *txPowerLabel;
@property (nonatomic, strong) NSLevelIndicator *txPowerMeterBar;
@property (nonatomic, strong) NSTextField *txSwrLabel;
@property (nonatomic, strong) NSLevelIndicator *txSwrMeterBar;
@property (nonatomic, strong, nullable) NSTimer *txMeterPollingTimer;
@property (nonatomic, assign) BOOL txMeterPollInFlight;      // one PWR/SWR read at a time
@property (nonatomic, assign) NSUInteger txMeterSilentPolls; // polls in a row with no reply
@property (nonatomic, assign, readwrite) double liveTXPowerWatts;
@property (nonatomic, assign, readwrite) double liveTXSWR;

// UI Controls - QSO Log Table
@property (nonatomic, strong) NSTableView *logTableView;
@property (nonatomic, strong) NSButton *exportADIFButton;
@property (nonatomic, strong) NSButton *clearLogButton;

- (void)updateAudioDeviceMenu;

@end

@implementation TX500CWStationController

- (instancetype)init {
    self = [super init];
    if (self) {
        _decoder = [[TX500CWAudioDecoder alloc] init];
        NSString *savedInput = [NSUserDefaults.standardUserDefaults stringForKey:CWInputPreferenceKey];
        _hasLocalAudioSelection = savedInput.length > 0;
        if (_hasLocalAudioSelection) {
            _decoder.selectedAudioDeviceUID = savedInput;
        } else if (@available(macOS 14.2, *)) {
            _decoder.selectedAudioDeviceUID = TX500CWSystemAudioDeviceUID;
        }
        _operatingMode = @"DIG";
        _userHasChosenCustomMode = NO;
        _decoder.preserveDeviceSelection = YES;
        _keyer = [[TX500CWKeyer alloc] init];
        _assistant = [[TX500CWQSOAssistant alloc] init];
        _macroButtons = [NSMutableArray array];

        _audioEngine = [[TX500AudioEngine alloc] init];
        _currentDialFrequencyHz = 0; // unknown until the radio reports it
        _currentTuningStepHz = 100;
        _widebandChannels = [NSMutableArray array];
        _isMonitoringAudio = NO;
        _isRecordingAudio = NO;

        [_decoder setNominalWPM:(double)_keyer.wpm];

        [self buildUserInterface];
        [self setupBindings];
        // Nothing may stay keyed while the Mac sleeps: the delayed RX; blocks and the Tune cutoff
        // do not run until it wakes.
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(workspaceWillSleep:)
                                                               name:NSWorkspaceWillSleepNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [self stopAudioMonitor];
    [self stopRecordingMessage];
    [self stopStation];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

#pragma mark - Bindings & Callbacks

- (void)setupBindings {
    __weak typeof(self) weakSelf = self;

    // Decoder -> UI & Assistant
    self.decoder.onDecodedTextUpdated = ^(NSString *rawText, NSString *charBuffer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Update Terminal View
        [strongSelf.terminalTextView setString:rawText];
        [strongSelf.terminalTextView scrollRangeToVisible:NSMakeRange(rawText.length, 0)];
        strongSelf.activeDitDahLabel.stringValue = charBuffer.length > 0 ? [NSString stringWithFormat:@"[ %@ ]", charBuffer] : @"[ ]";

        // Feed to QSO Assistant for CQ & token analysis
        [strongSelf.assistant processDecodedTextStream:rawText
                                            currentWPM:strongSelf.decoder.estimatedWPM
                                                 snrDb:strongSelf.decoder.signalToNoiseRatioDb];
        // A station calling us ends Auto-CQ (the countdown timer then puts the button back).
        [strongSelf.keyer noteDecodedText:rawText];
    };

    self.decoder.onMetricsUpdated = ^(double wpm, double snrDb, float level, BOOL sig) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.wpmMetricLabel.stringValue = [NSString stringWithFormat:@"%.0f WPM", wpm];
        strongSelf.snrMetricLabel.stringValue = [NSString stringWithFormat:@"%.1f dB SNR", snrDb];
        strongSelf.ditDahMetricLabel.stringValue = [NSString stringWithFormat:@"1 : %.1f", strongSelf.decoder.ditDahRatio];
        strongSelf.carrierLockStatusLabel.stringValue = sig ? @"● RX CARRIER" : @"○ LISTENING";
        strongSelf.carrierLockStatusLabel.textColor = sig ? [NSColor colorWithSRGBRed:0.2 green:0.95 blue:0.4 alpha:1.0] : [NSColor secondaryLabelColor];

        [strongSelf.spectrumView updateWithBins:strongSelf.decoder.spectrumBins
                                     centerFreq:strongSelf.decoder.centerFrequencyHz
                                    nominalPitch:strongSelf.decoder.nominalPitchHz
                                           level:level
                                           snrDb:snrDb
                                  signalDetected:sig
                                detectedCarriers:strongSelf.decoder.detectedCarrierFrequencies];
    };

    self.decoder.onMultiChannelUpdated = ^(NSArray<TX500CWChannelState *> *channels) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.widebandChannels = [channels mutableCopy];
        if (strongSelf.rosterModeControl.selectedSegment == 0) {
            [strongSelf.cqRosterTableView reloadData];
        }
        [strongSelf.spectrumView updateWithBins:strongSelf.decoder.spectrumBins
                                     centerFreq:strongSelf.decoder.centerFrequencyHz
                                    nominalPitch:strongSelf.decoder.nominalPitchHz
                                           level:strongSelf.decoder.audioInputLevel
                                           snrDb:strongSelf.decoder.signalToNoiseRatioDb
                                  signalDetected:strongSelf.decoder.isSignalDetected
                                detectedCarriers:strongSelf.decoder.detectedCarrierFrequencies];
    };

    self.decoder.onAudioDevicesChanged = ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateAudioDeviceMenu];
    };

    self.decoder.onListeningStateChanged = ^(BOOL listening) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.startStopDecoderButton.title = listening ? @"STOP DECODER" : @"START DECODER";
        strongSelf.startStopDecoderButton.contentTintColor = listening ? NSColor.systemRedColor : NSColor.systemGreenColor;
        if (!listening) {
            if (strongSelf.isMonitoringAudio) [strongSelf stopAudioMonitor];
            if (strongSelf.isRecordingAudio) [strongSelf stopRecordingMessage];
        }
        if (strongSelf.decoderStateChangedHandler) strongSelf.decoderStateChangedHandler(listening);
    };
    self.decoder.onAudioError = ^(NSString *message) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.logHandler) strongSelf.logHandler(message);
        // The sheet below blocks ABORT and Esc until OK is clicked: stop the Tune and Auto-CQ first.
        // A message already on the air ends with its own release.
        [strongSelf stopManualTune];
        if (strongSelf.keyer.isAutoCQActive) {
            [strongSelf.keyer stopAutoCQ];
            [strongSelf stopAutoCQTimer];
            strongSelf.autoCQButton.title = @"Auto-CQ Repeater";
            if (strongSelf.logHandler) strongSelf.logHandler(@"Auto-CQ stopped: the audio input failed.");
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Audio input unavailable";
        alert.informativeText = message;
        [alert addButtonWithTitle:@"OK"];
        if (strongSelf.view.window) [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
    };

    // User click anywhere on Spectrum Waterfall tunes the radio VFO frequency
    self.spectrumView.onWaterfallFrequencyClicked = ^(double clickedAudioFreqHz) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        double nomPitch = strongSelf.decoder ? strongSelf.decoder.nominalPitchHz : 650.0;
        if (nomPitch < 300.0 || nomPitch > 1500.0) nomPitch = 650.0;

        int64_t deltaHz = (int64_t)round(clickedAudioFreqHz - nomPitch);

        // Retune radio VFO dial so clicked signal centers on the operator's nominal CW pitch
        if (llabs(deltaHz) >= 5) {
            // The step says why when it refuses (no frequency read from the radio, or FA refused) and
            // sets the tuning lockout only when the radio accepted FA.
            if (![strongSelf stepFrequencyHz:deltaHz]) return;
            if (strongSelf.logHandler) {
                strongSelf.logHandler([NSString stringWithFormat:@"[CW Waterfall] Retuned radio VFO by %+lld Hz (Clicked: %.0f Hz -> Pitch: %.0f Hz)",
                                       (long long)deltaHz, clickedAudioFreqHz, nomPitch]);
            }
        } else {
            // Already centered, align decoder tone
            [strongSelf.decoder setPitch:clickedAudioFreqHz];
            strongSelf.keyer.sidetonePitchHz = clickedAudioFreqHz;
            strongSelf.pitchSlider.doubleValue = clickedAudioFreqHz;
            strongSelf.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0fHz", clickedAudioFreqHz];
            [strongSelf updateVFOOffsetLabel];
        }
    };

    self.spectrumView.onPitchSelected = ^(double pitchHz) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pitchSlider.doubleValue = pitchHz;
        strongSelf.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0fHz", pitchHz];
        [strongSelf.decoder setPitch:pitchHz];
        strongSelf.keyer.sidetonePitchHz = pitchHz;
        [strongSelf updateVFOOffsetLabel];
    };

    // Assistant -> UI Updates
    self.assistant.onHeardStationsUpdated = ^(NSArray<TX500CWHeardStation *> *stations) {
        (void)stations;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.cqRosterTableView reloadData];
    };

    self.assistant.onQSOStateChanged = ^(TX500QSOState state, NSString *desc) {
        (void)state;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.qsoStateLabel.stringValue = desc;
        strongSelf.qsoNextActionButton.title = strongSelf.assistant.suggestedActionTitle;
        strongSelf.qsoNextActionButton.enabled = YES;
        NSString *macro = strongSelf.assistant.suggestedActionMacro;
        if (macro.length > 0 && strongSelf.txInputField.stringValue.length == 0) {
            strongSelf.txInputField.placeholderString = [NSString stringWithFormat:@"Suggested: %@", macro];
        }
    };

    // Practice / Sim is the decoder's simulation: the assistant asks it when a QSO starts and at sign-off.
    self.assistant.practiceModeActive = ^BOOL {
        typeof(self) strongSelf = weakSelf;
        return strongSelf && strongSelf.decoder.isSimulationActive;
    };
    self.assistant.onContactLogged = ^(TX500QSOContact *contact) {
        (void)contact;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.logTableView reloadData];
        if (strongSelf.logHandler && [contact.notes hasPrefix:@"Practice / Sim"]) {
            strongSelf.logHandler([NSString stringWithFormat:@"Practice / Sim: QSO with %@ kept in this session only; nothing is saved to the Logbook or uploaded.",
                                   contact.callsign]);
        } else if (strongSelf.logHandler && contact.frequencyMHz <= 0.0) {
            strongSelf.logHandler([NSString stringWithFormat:@"QSO with %@ kept in this session only: frequency not read from the radio, so it was not saved to the Logbook or uploaded.",
                                   contact.callsign]);
        } else if (strongSelf.logHandler) {
            strongSelf.logHandler([NSString stringWithFormat:@"✔ Logged QSO with %@ (%@, %@)",
                                   contact.callsign, contact.band.length ? contact.band : @"band unknown", contact.mode]);
        }
    };

    // Keyer -> Serial Sender & Log
    self.keyer.serialCommandSender = ^BOOL(NSString *catCommand) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.decoder.isSimulationActive) { strongSelf.releaseNotConfirmed = NO; return YES; }
        BOOL ok = NO;
        if (strongSelf && strongSelf.serialCommandSender) {
            ok = strongSelf.serialCommandSender(catCommand);
        }
        // The keyer's releases ignore the answer: keep it, so the pane says when RX was not confirmed.
        if ([catCommand hasPrefix:@"RX"]) strongSelf.releaseNotConfirmed = !ok;
        if (!ok && [catCommand containsString:@"TX;"]) [strongSelf noteTransmitRefused];
        return ok;
    };
    // The same Practice / Sim decision for the keyer's audio: in practice it never opens or feeds
    // the radio output. (The CAT gate above returns YES on purpose, so it cannot serve for this.)
    self.keyer.practiceModeActive = ^BOOL {
        typeof(self) strongSelf = weakSelf;
        return strongSelf && strongSelf.decoder.isSimulationActive;
    };

    self.keyer.logHandler = ^(NSString *line) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.logHandler) {
            strongSelf.logHandler(line);
        }
    };

    self.keyer.onTransmitStateChanged = ^(BOOL transmitting, NSString *text) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (transmitting) {
            strongSelf.txAbortButton.enabled = YES;
            strongSelf.txSendButton.enabled = NO;
            strongSelf.txTuneButton.title = @"■ TX ON";
            strongSelf.txTuneButton.contentTintColor = [NSColor systemRedColor];
            strongSelf.txTuneButton.enabled = NO;
            strongSelf.carrierLockStatusLabel.stringValue = @"● TX ON THE AIR";
            strongSelf.carrierLockStatusLabel.textColor = [NSColor systemRedColor];
            [strongSelf startTXMeterPolling];
        } else {
            strongSelf.txAbortButton.enabled = strongSelf.isManualTuneActive;
            strongSelf.txSendButton.enabled = YES;
            strongSelf.txTuneButton.title = strongSelf.isManualTuneActive ? @"■ RX (Stop)" : @"TX (Tune)";
            strongSelf.txTuneButton.contentTintColor = strongSelf.isManualTuneActive ? [NSColor systemRedColor] : nil;
            strongSelf.txTuneButton.enabled = YES;
            strongSelf.carrierLockStatusLabel.stringValue = strongSelf.isManualTuneActive ? @"● TX (TUNING)" : @"○ LISTENING";
            strongSelf.carrierLockStatusLabel.textColor = strongSelf.isManualTuneActive ? [NSColor systemRedColor] : [NSColor secondaryLabelColor];
            if (!strongSelf.isManualTuneActive) {
                [strongSelf stopTXMeterPolling];
            }
            if (!strongSelf.isManualTuneActive && strongSelf.releaseNotConfirmed) [strongSelf showReleaseNotConfirmed];
        }
        (void)text;
    };

    // The keyer's hard time-out has already silenced and released the radio: put the Tune
    // controls back (stopManualTransmit re-sends RX; only while a Tune is active) and say so.
    self.keyer.onTransmitTimedOut = ^(NSTimeInterval limitSeconds) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf stopManualTune];
        if (strongSelf.logHandler) strongSelf.logHandler([NSString stringWithFormat:@"CW Station: transmit time-out after %.0f s; keyer and Tune stopped.", limitSeconds]);
    };
}

#pragma mark - Radio Mode & Lifecycle

- (void)updateKeyerCommandsForCurrentMode {
    if ([self.operatingMode isEqualToString:@"CW"]) {
        self.keyer.txPrefixCommand = @"MD6;TX;";
        self.keyer.rxSuffixCommand = @"RX;MD3;";
    } else if ([self.operatingMode isEqualToString:@"CW-R"]) {
        self.keyer.txPrefixCommand = @"MD6;TX;";
        self.keyer.rxSuffixCommand = @"RX;MD7;";
    } else if ([self.operatingMode isEqualToString:@"USB"]) {
        // CW keys only in DIG (the station core refuses TX; in any other mode): USB and LSB key
        // from DIG and go back to their mode after the release, as CW and CW-R do.
        self.keyer.txPrefixCommand = @"MD6;TX;";
        self.keyer.rxSuffixCommand = @"RX;MD2;";
    } else if ([self.operatingMode isEqualToString:@"LSB"]) {
        self.keyer.txPrefixCommand = @"MD6;TX;";
        self.keyer.rxSuffixCommand = @"RX;MD1;";
    } else {
        self.keyer.txPrefixCommand = @"TX;";
        self.keyer.rxSuffixCommand = @"RX;";
    }
}

+ (nullable NSString *)pairedRadioOutputUIDForInputUID:(nullable NSString *)inputUID
                                         inputDevices:(NSArray<NSDictionary<NSString *, NSString *> *> *)inputs
                                        outputDevices:(NSArray<TX500AudioDeviceItem *> *)outputs {
    if (inputUID.length == 0 || [inputUID isEqualToString:TX500CWSystemAudioDeviceUID]) return nil;
    NSDictionary<NSString *, NSString *> *input = nil;
    for (NSDictionary<NSString *, NSString *> *device in inputs) {
        if ([device[@"uid"] isEqualToString:inputUID]) { input = device; break; }
    }
    // Only a radio audio interface has a pair: the radio's own USB codec (isPreferredUSBAudio), or a
    // USB device whose name is one of the decoder's radio interfaces (Digirig, SignaLink, C-Media,
    // "codec"). A headset's output is never the radio's, and "USB" in a name is not enough.
    BOOL radioInterface = [input[@"isPreferredUSBAudio"] isEqualToString:@"YES"];
    if (!radioInterface && [input[@"isUSB"] isEqualToString:@"YES"]) {
        NSString *lower = [input[@"name"] lowercaseString] ?: @"";
        for (NSString *word in @[@"digirig", @"signalink", @"signallink", @"c-media", @"codec"]) {
            if ([lower containsString:word]) { radioInterface = YES; break; }
        }
    }
    if (!radioInterface) return nil;
    // Some interfaces expose a single UID for both directions.
    for (TX500AudioDeviceItem *dev in outputs) {
        if ([dev.uid isEqualToString:inputUID]) return dev.uid;
    }
    // Apple USB Audio: the input and output endpoints share the prefix up to the last colon.
    NSString *prefix = @"AppleUSBAudioEngine:";
    if (![inputUID hasPrefix:prefix]) return nil;
    NSRange lastColon = [inputUID rangeOfString:@":" options:NSBackwardsSearch];
    if (lastColon.location == NSNotFound || lastColon.location <= prefix.length) return nil;
    NSString *family = [inputUID substringToIndex:lastColon.location + 1];
    NSString *match = nil;
    for (TX500AudioDeviceItem *dev in outputs) {
        if (![dev.uid hasPrefix:family]) continue;
        if (match) return nil; // two outputs in the family: an ambiguous pair is no pair
        match = dev.uid;
    }
    return match;
}

// Finds the radio's own output from the chosen CW input. The profile's Radio transmit output
// (keyer.radioOutputDeviceUID, written by the host) is never changed here: it wins when set.
- (void)updateKeyerRadioOutputDevice {
    NSArray<TX500AudioDeviceItem *> *outputs = self.audioEngine.outputDevices;
    self.keyer.pairedRadioOutputDeviceUID =
        [TX500CWStationController pairedRadioOutputUIDForInputUID:self.decoder.selectedAudioDeviceUID
                                                     inputDevices:self.decoder.availableAudioInputDevices
                                                    outputDevices:outputs];
    NSString *target = [self.keyer radioAudioTargetUID];
    BOOL same = (target == nil && self.reportedRadioAudioTargetUID == nil) ||
                [target isEqualToString:self.reportedRadioAudioTargetUID];
    if ((self.radioAudioTargetReported && same) || !self.logHandler) return;
    self.radioAudioTargetReported = YES;
    self.reportedRadioAudioTargetUID = target;
    if (target.length) {
        NSString *name = nil;
        for (TX500AudioDeviceItem *dev in outputs) {
            if ([dev.uid isEqualToString:target]) { name = dev.name; break; }
        }
        self.logHandler([NSString stringWithFormat:@"[CW Station] Radio transmit output: %@ (%@)",
                         name.length ? name : @"not in the output list now", target]);
    } else {
        self.logHandler(@"[CW Station] No radio transmit output: choose it in Station (Radio transmit output), or pick the radio's USB input above.");
    }
}

- (void)prepareRadioForCWMode {
    [self updateKeyerRadioOutputDevice];
    if (!self.userHasChosenCustomMode) {
        self.operatingMode = @"DIG";
        if (self.modePopup && self.modePopup.selectedItem.tag != 6) {
            [self.modePopup selectItemWithTag:6];
        }
    }
    // DIG, by default or chosen in the menu, keys with a plain TX;: MD6; goes out once per entry,
    // and again after a TX; was refused. The other modes carry MD6; in their own TX prefix.
    if ([self.operatingMode isEqualToString:@"DIG"] && !self.cwModeConfiguredOnRadio) {
        if (self.serialCommandSender) {
            BOOL sent = self.serialCommandSender(@"MD6;");
            if (sent) {
                self.cwModeConfiguredOnRadio = YES;
                if (self.logHandler) {
                    self.logHandler(@"[CW Station] Transceiver configured for DIG mode (MD6;).");
                }
            }
        }
    }
    [self updateKeyerCommandsForCurrentMode];
}

// A refused TX; (the mode knob turned to CW, FM or anything else inside the tab, a radio slow to
// apply MD6;, VOX on) clears the MD6; latch, so the next Send or Tune sets DIG first.
- (void)noteTransmitRefused {
    self.cwModeConfiguredOnRadio = NO;
    if (self.logHandler) self.logHandler(@"CW Station: TX; refused: DIG (MD6;) will be set again on the next Send or Tune.");
}

- (void)modePopupChanged:(NSPopUpButton *)sender {
    NSInteger tag = sender.selectedItem.tag;
    self.userHasChosenCustomMode = YES;
    self.cwModeConfiguredOnRadio = (tag == 6 || tag == 3);
    if (tag == 3) self.operatingMode = @"CW";
    else if (tag == 7) self.operatingMode = @"CW-R";
    else if (tag == 2) self.operatingMode = @"USB";
    else if (tag == 1) self.operatingMode = @"LSB";
    else if (tag == 6) self.operatingMode = @"DIG";

    [self updateKeyerCommandsForCurrentMode];

    NSString *cmd = [NSString stringWithFormat:@"MD%ld;", (long)tag];
    if (self.serialCommandSender) {
        self.serialCommandSender(cmd);
    }
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[CW Station] Mode set to %@ (%@).", sender.selectedItem.title, cmd]);
    }
}

- (void)startStation {
    [self prepareRadioForCWMode];
    [self.decoder refreshAudioDevices];
    [self updateAudioDeviceMenu];
}

- (void)stopStation {
    [self stopManualTune];
    [self stopTXMeterPolling];
    // Another tab may change the radio's mode (an FM preset in Voice): each entry sets DIG again.
    // In Practice MD6; still goes out on entry, as before.
    self.cwModeConfiguredOnRadio = NO;
    [self stopAutoCQTimer];
    [self.decoder stopListening];
    // Practice ends here (Esc, leaving CW Station, Quit): the practice QSO must not reach the air
    // or the Logbook afterwards, and the box must not stay ticked. A real QSO is left alone.
    if (self.decoder.isSimulationActive) [self.assistant resetQSOState];
    [self.decoder stopSimulation];
    self.simulationCheckbox.state = NSControlStateValueOff;
    if (self.keyer.isTransmitting) {
        [self.keyer abortTransmission];
    }
    [self.keyer stopAutoCQ];
    self.startStopDecoderButton.title = @"START DECODER";
    self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
}

- (void)workspaceWillSleep:(NSNotification *)note {
    (void)note;
    BOOL onAir = self.keyer.isTransmitting || self.keyer.isAutoCQActive || self.isManualTuneActive;
    [self stopStation];
    if (onAir && self.logHandler) self.logHandler(@"CW Station: stopped for system sleep (RX; sent).");
}

- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode {
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now < self.userTuningLockoutUntil) {
        // Discard stale in-flight serial poll replies while user tuning command is settling
        return;
    }
    // 0 Hz means the radio did not answer FA;. A frequency known before is kept; with none,
    // the frequency and band stay unknown (never a guessed one).
    if (freqHz == 0 && self.currentDialFrequencyHz > 0) {
        if (self.logHandler)
            self.logHandler([NSString stringWithFormat:@"Radio frequency unavailable: keeping the last known %.3f MHz.",
                             (double)self.currentDialFrequencyHz / 1e6]);
    } else {
        [self applyDialFrequencyHz:freqHz];
        if (freqHz == 0 && self.logHandler)
            self.logHandler(@"Radio frequency unavailable: CW frequency and band stay unknown. A QSO is kept in this session only until the radio answers.");
    }

    if (!self.userHasChosenCustomMode) {
        // Automatically ensure DIG/CW mode unless the user explicitly selected another mode
        // The default keying needs DIG: a reading in any other mode (CW and CW-R too) sets it again.
        if (mode.length > 0 && ![mode isEqualToString:@"DIG"]) {
            // The radio is in another mode now: MD6; must go out again, whatever was sent before.
            self.cwModeConfiguredOnRadio = NO;
            [self prepareRadioForCWMode];
        }
    } else if (mode.length > 0 && [@[@"CW", @"CW-R", @"USB", @"LSB", @"DIG"] containsObject:mode]) {
        // FM, AM and the undocumented modes are not in the mode menu: a reading in one of them keeps
        // the operator's choice and its keying (the CW and CW-R prefixes set DIG before TX;).
        self.operatingMode = mode;
        if ([mode isEqualToString:@"CW"]) [self.modePopup selectItemWithTag:3];
        else if ([mode isEqualToString:@"CW-R"]) [self.modePopup selectItemWithTag:7];
        else if ([mode isEqualToString:@"USB"]) [self.modePopup selectItemWithTag:2];
        else if ([mode isEqualToString:@"LSB"]) [self.modePopup selectItemWithTag:1];
        else if ([mode isEqualToString:@"DIG"]) [self.modePopup selectItemWithTag:6];
        [self updateKeyerCommandsForCurrentMode];
    }
}

// Shows a dial frequency on the VFO, the band selector and the QSO assistant. 0 Hz is unknown.
// The band comes from the Logbook band table; "HF" is its answer for a frequency in no band,
// so the band stays unknown there too (never 20m by default).
- (void)applyDialFrequencyHz:(uint64_t)freqHz {
    self.currentDialFrequencyHz = freqHz;
    self.assistant.currentFrequencyHz = freqHz;
    NSString *band = freqHz > 0 ? [TX500LogRecord bandForFrequencyHz:freqHz] : @"";
    if ([band isEqualToString:@"HF"]) band = @"";
    self.assistant.currentBand = band;

    if (self.vfoLabel) self.vfoLabel.stringValue = [self vfoTextForFrequencyHz:freqHz];
    if (self.bandSelectorControl) {
        NSUInteger bandIndex = [CWBandSelectorNames() indexOfObject:band];
        self.bandSelectorControl.selectedSegment = (bandIndex != NSNotFound && (NSInteger)bandIndex < self.bandSelectorControl.segmentCount) ? (NSInteger)bandIndex : -1;
    }
    [self updateVFOOffsetLabel];
}

- (NSString *)vfoTextForFrequencyHz:(uint64_t)freqHz {
    if (freqHz == 0) return @"--.---.--- MHz";
    return [NSString stringWithFormat:@"%.3f.%03llu MHz", (double)freqHz / 1e6, (unsigned long long)(freqHz % 1000)];
}

- (void)updateVFOOffsetLabel {
    if (!self.vfoOffsetLabel) return;
    uint64_t dial = self.currentDialFrequencyHz;
    double pitch = self.decoder ? self.decoder.nominalPitchHz : 650.0;
    if (dial == 0) {
        self.vfoOffsetLabel.stringValue = [NSString stringWithFormat:@"Pitch: +%.0fHz | RF: unknown", pitch];
        return;
    }
    uint64_t rf = dial + (uint64_t)round(pitch);
    self.vfoOffsetLabel.stringValue = [NSString stringWithFormat:@"Pitch: +%.0fHz | RF: %.3f.%03llu MHz",
                                       pitch, (double)rf / 1e6, (unsigned long long)(rf % 1000)];
}

// The pane shows the new frequency only once the radio has accepted FA: a refused FA (the radio
// still in TX, or another owner keying) leaves the dial, the band and the assistant as they were.
- (BOOL)tuneToFrequencyHz:(uint64_t)freqHz {
    if (freqHz < 1000000 || freqHz > 60000000) return NO;
    NSString *cmd = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)freqHz];
    BOOL accepted = self.serialCommandSender && self.serialCommandSender(cmd);
    if (!accepted) {
        if (self.logHandler)
            self.logHandler([NSString stringWithFormat:@"[CW Station] VFO not retuned to %.4f MHz: the radio refused the frequency change.", (double)freqHz / 1e6]);
        return NO;
    }
    self.userTuningLockoutUntil = [NSDate timeIntervalSinceReferenceDate] + 1.5;
    [self applyDialFrequencyHz:freqHz];
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[CW Station] Tuned VFO to %.4f MHz (%@)", (double)freqHz / 1e6, cmd]);
    }
    return YES;
}

- (BOOL)stepFrequencyHz:(int64_t)stepHz {
    // A step needs the dial frequency: never step from a guessed one.
    if (self.currentDialFrequencyHz == 0) {
        if (self.logHandler)
            self.logHandler(@"[CW Station] VFO not stepped: the radio frequency is unknown. Pick a band, or reopen the CW tab to read it from the radio.");
        return NO;
    }
    uint64_t current = self.currentDialFrequencyHz;
    int64_t target = (int64_t)current + stepHz;
    if (target < 1000000) target = 1000000;
    if (target > 60000000) target = 60000000;
    return [self tuneToFrequencyHz:(uint64_t)target];
}

- (void)selectAmateurBand:(NSString *)band {
    uint64_t f = 14025000;
    NSInteger bandIndex = 4;
    if ([band isEqualToString:@"160m"]) { f = 1810000; bandIndex = 0; }
    else if ([band isEqualToString:@"80m"]) { f = 3520000; bandIndex = 1; }
    else if ([band isEqualToString:@"40m"]) { f = 7020000; bandIndex = 2; }
    else if ([band isEqualToString:@"30m"]) { f = 10110000; bandIndex = 3; }
    else if ([band isEqualToString:@"20m"]) { f = 14025000; bandIndex = 4; }
    else if ([band isEqualToString:@"17m"]) { f = 18075000; bandIndex = 5; }
    else if ([band isEqualToString:@"15m"]) { f = 21025000; bandIndex = 6; }
    else if ([band isEqualToString:@"12m"]) { f = 24895000; bandIndex = 7; }
    else if ([band isEqualToString:@"10m"]) { f = 28025000; bandIndex = 8; }
    else if ([band isEqualToString:@"6m"]) { f = 50090000; bandIndex = 9; }

    self.userTuningLockoutUntil = [NSDate timeIntervalSinceReferenceDate] + 1.5;
    self.currentDialFrequencyHz = f;
    self.assistant.currentBand = band;
    self.assistant.currentFrequencyHz = f;
    if (self.vfoLabel) {
        self.vfoLabel.stringValue = [NSString stringWithFormat:@"%.3f.%03llu MHz", (double)f / 1e6, (unsigned long long)(f % 1000)];
    }
    if (self.bandSelectorControl && bandIndex >= 0 && bandIndex < self.bandSelectorControl.segmentCount) {
        self.bandSelectorControl.selectedSegment = bandIndex;
    }
    [self updateVFOOffsetLabel];

    [self tuneToFrequencyHz:f];
    [self prepareRadioForCWMode];
}

- (void)vfoStepControlChanged:(NSSegmentedControl *)sender {
    NSInteger sel = sender.selectedSegment;
    if (sel == 0) self.currentTuningStepHz = 10;
    else if (sel == 1) self.currentTuningStepHz = 100;
    else if (sel == 2) self.currentTuningStepHz = 500;
    else if (sel == 3) self.currentTuningStepHz = 1000;
    else if (sel == 4) self.currentTuningStepHz = 5000;
}

- (void)stepDownClicked:(id)sender {
    (void)sender;
    int64_t step = self.currentTuningStepHz > 0 ? self.currentTuningStepHz : 100;
    [self stepFrequencyHz:-step];
}

- (void)stepUpClicked:(id)sender {
    (void)sender;
    int64_t step = self.currentTuningStepHz > 0 ? self.currentTuningStepHz : 100;
    [self stepFrequencyHz:step];
}

- (void)bandSelectorChanged:(NSSegmentedControl *)sender {
    NSInteger sel = sender.selectedSegment;
    NSArray<NSString *> *names = CWBandSelectorNames();
    if (sel >= 0 && sel < (NSInteger)names.count) {
        [self selectAmateurBand:names[sel]];
    }
}

#pragma mark - Audio Monitor & Recording

- (void)startAudioMonitor {
    if (self.decoder.selectedAudioDeviceUID.length > 0 &&
        ![self.decoder.selectedAudioDeviceUID isEqualToString:TX500CWSystemAudioDeviceUID]) {
        self.audioEngine.selectedInputDeviceUID = self.decoder.selectedAudioDeviceUID;
    }
    self.audioEngine.masterVolume = self.monitorVolumeSlider ? self.monitorVolumeSlider.floatValue : 1.0f;
    self.audioEngine.isMuted = self.monitorMuteButton ? (self.monitorMuteButton.state == NSControlStateValueOn) : NO;
    if (self.cwNarrowFilterButton && self.cwNarrowFilterButton.state == NSControlStateValueOn) {
        [self.audioEngine applyPreset:TX500AudioFilterPresetCWNarrow];
    } else {
        [self.audioEngine applyPreset:TX500AudioFilterPresetFlat];
    }
    NSError *err = nil;
    BOOL ok = [self.audioEngine startMonitoring:&err];
    if (ok) {
        _isMonitoringAudio = YES;
        self.monitorToggleButton.title = @"🔊 Monitor: ON";
        self.monitorToggleButton.contentTintColor = [NSColor systemGreenColor];
        if (self.logHandler) {
            self.logHandler(@"[CW Station] RX Audio Monitor enabled (output to Mac speakers/headphones).");
        }
    } else {
        _isMonitoringAudio = NO;
        self.monitorToggleButton.title = @"🔈 Monitor: OFF";
        self.monitorToggleButton.contentTintColor = [NSColor secondaryLabelColor];
        if (err && self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[CW Station] Audio monitor failed: %@", err.localizedDescription]);
        }
    }
}

- (void)stopAudioMonitor {
    [self.audioEngine stopMonitoring];
    _isMonitoringAudio = NO;
    self.monitorToggleButton.title = @"🔈 Monitor: OFF";
    self.monitorToggleButton.contentTintColor = [NSColor secondaryLabelColor];
    if (self.logHandler) {
        self.logHandler(@"[CW Station] RX Audio Monitor stopped.");
    }
}

- (void)toggleAudioMonitor {
    if (self.isMonitoringAudio) {
        [self stopAudioMonitor];
    } else {
        [self startAudioMonitor];
    }
}

- (void)monitorVolumeChanged:(NSSlider *)sender {
    self.audioEngine.masterVolume = sender.floatValue;
}

- (void)monitorMuteClicked:(NSButton *)sender {
    self.audioEngine.isMuted = (sender.state == NSControlStateValueOn);
    sender.contentTintColor = self.audioEngine.isMuted ? [NSColor systemRedColor] : [NSColor controlTextColor];
}

- (void)cwFilterClicked:(NSButton *)sender {
    if (sender.state == NSControlStateValueOn) {
        [self.audioEngine applyPreset:TX500AudioFilterPresetCWNarrow];
    } else {
        [self.audioEngine applyPreset:TX500AudioFilterPresetFlat];
    }
}

- (void)startRecordingMessage {
    if (self.isRecordingAudio) return;
    NSError *err = nil;
    BOOL ok = [self.audioEngine startRecordingWithError:&err];
    if (ok) {
        _isRecordingAudio = YES;
        self.recordSeconds = 0;
        self.recordButton.title = @"■ STOP REC";
        self.recordButton.contentTintColor = [NSColor systemRedColor];
        self.recordStatusLabel.stringValue = @"● REC 00:00";
        self.recordStatusLabel.textColor = [NSColor systemRedColor];

        __weak typeof(self) weakSelf = self;
        [self.recordTimer invalidate];
        self.recordTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isRecordingAudio) {
                [timer invalidate];
                return;
            }
            strongSelf.recordSeconds += 1.0;
            NSInteger mins = (NSInteger)strongSelf.recordSeconds / 60;
            NSInteger secs = (NSInteger)strongSelf.recordSeconds % 60;
            strongSelf.recordStatusLabel.stringValue = [NSString stringWithFormat:@"● REC %02ld:%02ld", (long)mins, (long)secs];
        }];

        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[CW Station] Audio recording started: %@", self.audioEngine.currentRecordingPath.lastPathComponent ?: @"CW.wav"]);
        }
    } else if (err && self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[CW Station] Failed to start recording: %@", err.localizedDescription]);
    }
}

- (void)stopRecordingMessage {
    if (!self.isRecordingAudio) return;
    [self.recordTimer invalidate];
    self.recordTimer = nil;
    NSString *path = self.audioEngine.currentRecordingPath;
    [self.audioEngine stopRecording];
    _isRecordingAudio = NO;

    self.recordButton.title = @"● REC";
    self.recordButton.contentTintColor = [NSColor systemRedColor];
    self.recordStatusLabel.textColor = [NSColor secondaryLabelColor];
    if (path.length > 0) {
        self.recordStatusLabel.stringValue = [NSString stringWithFormat:@"Saved: %@", path.lastPathComponent];
        self.revealRecordingsButton.hidden = NO;
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[CW Station] Recording saved: %@", path]);
        }
    } else {
        self.recordStatusLabel.stringValue = @"";
    }
}

- (void)toggleRecording {
    if (self.isRecordingAudio) {
        [self stopRecordingMessage];
    } else {
        [self startRecordingMessage];
    }
}

- (void)revealRecordingsClicked:(id)sender {
    (void)sender;
    [self.audioEngine revealRecordingsInFinder];
}

- (void)rosterModeChanged:(NSSegmentedControl *)sender {
    (void)sender;
    [self.cqRosterTableView reloadData];
}

#pragma mark - UI Building

- (NSView *)createCardView {
    NSView *v = [[NSView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.wantsLayer = YES;
    v.layer.cornerRadius = 8.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.22].CGColor;
    v.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.06].CGColor;
    return v;
}

- (void)buildUserInterface {
    self.view = [[NSView alloc] initWithFrame:NSZeroRect];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *vfoCard = [self buildVFOBandControlBar];
    NSView *topCard = [self buildTopControlBar];
    NSView *scopeCard = [self buildSpectrumAndMetricsRow];
    NSView *middleCard = [self buildMiddleWorkstation];
    NSView *bottomCard = [self buildBottomLogSection];

    NSStackView *rootStack = [NSStackView stackViewWithViews:@[vfoCard, topCard, scopeCard, middleCard, bottomCard]];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    rootStack.spacing = 8;
    rootStack.alignment = NSLayoutAttributeLeading;
    rootStack.distribution = NSStackViewDistributionFill;
    [self.view addSubview:rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [rootStack.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [rootStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [rootStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [rootStack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [vfoCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [topCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [scopeCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [middleCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [bottomCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor]
    ]];
}

#pragma mark - VFO & Amateur Band Bar

- (NSView *)buildVFOBandControlBar {
    NSView *container = [self createCardView];

    // Row 1: VFO Readout, Step Buttons, Step Selector, Pitch Offset
    NSTextField *vfoTitle = [NSTextField labelWithString:@"VFO A:"];
    vfoTitle.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightBold];
    vfoTitle.textColor = [NSColor secondaryLabelColor];
    vfoTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.vfoLabel = [[TX500CWVFOTextField alloc] init];
    self.vfoLabel.font = [NSFont monospacedDigitSystemFontOfSize:15.0 weight:NSFontWeightBold];
    self.vfoLabel.textColor = [NSColor colorWithSRGBRed:0.25 green:0.95 blue:0.4 alpha:1.0];
    self.vfoLabel.backgroundColor = [NSColor colorWithCalibratedWhite:0.04 alpha:0.95];
    self.vfoLabel.drawsBackground = YES;
    self.vfoLabel.bordered = YES;
    self.vfoLabel.alignment = NSTextAlignmentCenter;
    self.vfoLabel.editable = NO;
    self.vfoLabel.stringValue = [self vfoTextForFrequencyHz:self.currentDialFrequencyHz];
    self.vfoLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.vfoLabel.widthAnchor constraintEqualToConstant:140].active = YES;
    [self.vfoLabel.heightAnchor constraintEqualToConstant:24].active = YES;
    self.vfoLabel.toolTip = @"Transceiver VFO Dial Frequency. Scroll mouse wheel here to tune frequency up/down by selected step!";

    __weak typeof(self) weakSelf = self;
    self.vfoLabel.onScrolled = ^(NSInteger deltaUnits) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        int64_t step = (int64_t)deltaUnits * (strongSelf.currentTuningStepHz > 0 ? strongSelf.currentTuningStepHz : 100);
        [strongSelf stepFrequencyHz:step];
    };

    self.stepDownButton = [NSButton buttonWithTitle:@"◀ -" target:self action:@selector(stepDownClicked:)];
    self.stepDownButton.bezelStyle = NSBezelStyleRounded;
    self.stepDownButton.controlSize = NSControlSizeSmall;
    self.stepDownButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.stepDownButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stepDownButton.widthAnchor constraintEqualToConstant:40].active = YES;
    self.stepDownButton.toolTip = @"Step frequency down by current step";

    self.stepUpButton = [NSButton buttonWithTitle:@"+ ▶" target:self action:@selector(stepUpClicked:)];
    self.stepUpButton.bezelStyle = NSBezelStyleRounded;
    self.stepUpButton.controlSize = NSControlSizeSmall;
    self.stepUpButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.stepUpButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.stepUpButton.widthAnchor constraintEqualToConstant:40].active = YES;
    self.stepUpButton.toolTip = @"Step frequency up by current step";

    self.vfoStepControl = [NSSegmentedControl segmentedControlWithLabels:@[@"10Hz", @"100Hz", @"500Hz", @"1kHz", @"5kHz"]
                                                            trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                  target:self
                                                                  action:@selector(vfoStepControlChanged:)];
    self.vfoStepControl.controlSize = NSControlSizeSmall;
    self.vfoStepControl.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.vfoStepControl.selectedSegment = 1; // 100Hz
    self.vfoStepControl.translatesAutoresizingMaskIntoConstraints = NO;
    self.vfoStepControl.toolTip = @"Tuning step resolution for mouse scroll and +/- buttons";

    self.vfoOffsetLabel = [NSTextField labelWithString:@""];
    self.vfoOffsetLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.vfoOffsetLabel.textColor = [NSColor secondaryLabelColor];
    [self updateVFOOffsetLabel];
    self.vfoOffsetLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *spacer1 = [NSView new];
    spacer1.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer1 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *r1 = [NSStackView stackViewWithViews:@[
        vfoTitle, self.vfoLabel, self.stepDownButton, self.stepUpButton, self.vfoStepControl, self.vfoOffsetLabel, spacer1
    ]];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.alignment = NSLayoutAttributeCenterY;
    r1.spacing = 8;

    // Row 2: Amateur CW Sub-Bands (160m to 6m)
    NSTextField *bandTitle = [NSTextField labelWithString:@"CW Bands:"];
    bandTitle.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    bandTitle.textColor = [NSColor secondaryLabelColor];
    bandTitle.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray<NSString *> *bands = @[
        @"160m (1.810)", @"80m (3.520)", @"40m (7.020)", @"30m (10.110)",
        @"20m (14.025)", @"17m (18.075)", @"15m (21.025)", @"12m (24.895)",
        @"10m (28.025)", @"6m (50.090)"
    ];
    self.bandSelectorControl = [NSSegmentedControl segmentedControlWithLabels:bands
                                                                 trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                       target:self
                                                                       action:@selector(bandSelectorChanged:)];
    self.bandSelectorControl.controlSize = NSControlSizeSmall;
    self.bandSelectorControl.font = [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightMedium];
    self.bandSelectorControl.selectedSegment = -1; // no band until the radio reports a frequency
    self.bandSelectorControl.translatesAutoresizingMaskIntoConstraints = NO;

    [self.bandSelectorControl setToolTip:@"160m CW Sub-band: 1.800 – 1.840 MHz (QRP: 1.810 MHz)" forSegment:0];
    [self.bandSelectorControl setToolTip:@"80m CW Sub-band: 3.500 – 3.570 MHz (QRP: 3.560 MHz)" forSegment:1];
    [self.bandSelectorControl setToolTip:@"40m CW Sub-band: 7.000 – 7.040 MHz (QRP: 7.030 MHz)" forSegment:2];
    [self.bandSelectorControl setToolTip:@"30m CW Sub-band: 10.100 – 10.130 MHz (QRP: 10.116 MHz)" forSegment:3];
    [self.bandSelectorControl setToolTip:@"20m CW Sub-band: 14.000 – 14.070 MHz (QRP: 14.060 MHz)" forSegment:4];
    [self.bandSelectorControl setToolTip:@"17m CW Sub-band: 18.068 – 18.095 MHz (QRP: 18.086 MHz)" forSegment:5];
    [self.bandSelectorControl setToolTip:@"15m CW Sub-band: 21.000 – 21.070 MHz (QRP: 21.060 MHz)" forSegment:6];
    [self.bandSelectorControl setToolTip:@"12m CW Sub-band: 24.890 – 24.915 MHz (QRP: 24.906 MHz)" forSegment:7];
    [self.bandSelectorControl setToolTip:@"10m CW Sub-band: 28.000 – 28.070 MHz (QRP: 28.060 MHz)" forSegment:8];
    [self.bandSelectorControl setToolTip:@"6m CW Sub-band: 50.000 – 50.100 MHz (Calling: 50.090 MHz)" forSegment:9];

    NSView *spacer2 = [NSView new];
    spacer2.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer2 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *r2 = [NSStackView stackViewWithViews:@[bandTitle, self.bandSelectorControl, spacer2]];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.alignment = NSLayoutAttributeCenterY;
    r2.spacing = 8;

    NSStackView *vfoStack = [NSStackView stackViewWithViews:@[r1, r2]];
    vfoStack.translatesAutoresizingMaskIntoConstraints = NO;
    vfoStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vfoStack.alignment = NSLayoutAttributeLeading;
    vfoStack.spacing = 5;
    [container addSubview:vfoStack];

    [NSLayoutConstraint activateConstraints:@[
        [vfoStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vfoStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vfoStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [vfoStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [r1.widthAnchor constraintEqualToAnchor:vfoStack.widthAnchor],
        [r2.widthAnchor constraintEqualToAnchor:vfoStack.widthAnchor],
        [container.heightAnchor constraintEqualToConstant:62]
    ]];

    [self updateVFOOffsetLabel];
    return container;
}

#pragma mark - Top Control Bar (Hardware, Monitor, Keyer & Recording)

- (NSView *)buildTopControlBar {
    NSView *container = [self createCardView];

    // Left group: Decoder toggle, Audio device, Practice Mode
    self.startStopDecoderButton = [NSButton buttonWithTitle:@"START DECODER" target:self action:@selector(toggleDecoder:)];
    self.startStopDecoderButton.bezelStyle = NSBezelStyleRounded;
    self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
    self.startStopDecoderButton.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightBold];
    self.startStopDecoderButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.startStopDecoderButton.widthAnchor constraintEqualToConstant:125].active = YES;

    self.audioDevicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.audioDevicePopup.toolTip = @"Choose and save the CW input here. System Audio (Direct) receives audio playing on this Mac. Microphone and USB inputs receive external radio audio.";
    self.audioDevicePopup.controlSize = NSControlSizeSmall;
    self.audioDevicePopup.font = [NSFont systemFontOfSize:11];
    self.audioDevicePopup.target = self;
    self.audioDevicePopup.action = @selector(audioDeviceChanged:);
    self.audioDevicePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.audioDevicePopup.widthAnchor constraintEqualToConstant:150].active = YES;
    [self updateAudioDeviceMenu];

    // Radio Mode selector
    NSTextField *modeTitle = [NSTextField labelWithString:@"Mode:"];
    modeTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    modeTitle.textColor = [NSColor secondaryLabelColor];
    modeTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modePopup.controlSize = NSControlSizeSmall;
    self.modePopup.font = [NSFont systemFontOfSize:11];
    self.modePopup.target = self;
    self.modePopup.action = @selector(modePopupChanged:);
    self.modePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modePopup.widthAnchor constraintEqualToConstant:145].active = YES;

    NSMenuItem *itemDIG = [[NSMenuItem alloc] initWithTitle:@"DIG (Soundcard CW)" action:nil keyEquivalent:@""];
    itemDIG.tag = 6;
    [self.modePopup.menu addItem:itemDIG];
    NSMenuItem *itemCW = [[NSMenuItem alloc] initWithTitle:@"CW (Paddle Key)" action:nil keyEquivalent:@""];
    itemCW.tag = 3;
    [self.modePopup.menu addItem:itemCW];
    NSMenuItem *itemCWR = [[NSMenuItem alloc] initWithTitle:@"CW-R" action:nil keyEquivalent:@""];
    itemCWR.tag = 7;
    [self.modePopup.menu addItem:itemCWR];
    NSMenuItem *itemUSB = [[NSMenuItem alloc] initWithTitle:@"USB" action:nil keyEquivalent:@""];
    itemUSB.tag = 2;
    [self.modePopup.menu addItem:itemUSB];
    NSMenuItem *itemLSB = [[NSMenuItem alloc] initWithTitle:@"LSB" action:nil keyEquivalent:@""];
    itemLSB.tag = 1;
    [self.modePopup.menu addItem:itemLSB];
    [self.modePopup selectItemWithTag:6];

    self.simulationCheckbox = [NSButton checkboxWithTitle:@"Practice/Sim" target:self action:@selector(toggleSimulation:)];
    self.simulationCheckbox.controlSize = NSControlSizeSmall;
    self.simulationCheckbox.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.simulationCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

    // Audio Monitor group (Speaker passthrough & volume)
    self.monitorToggleButton = [NSButton buttonWithTitle:@"🔈 Monitor: OFF" target:self action:@selector(toggleAudioMonitor)];
    self.monitorToggleButton.bezelStyle = NSBezelStyleRounded;
    self.monitorToggleButton.controlSize = NSControlSizeSmall;
    self.monitorToggleButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.monitorToggleButton.contentTintColor = [NSColor secondaryLabelColor];
    self.monitorToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.monitorToggleButton.toolTip = @"Stream incoming CW audio live through Mac speakers or headphones";

    self.monitorVolumeSlider = [[NSSlider alloc] init];
    self.monitorVolumeSlider.controlSize = NSControlSizeSmall;
    self.monitorVolumeSlider.minValue = 0.0;
    self.monitorVolumeSlider.maxValue = 1.5;
    self.monitorVolumeSlider.floatValue = 1.0;
    self.monitorVolumeSlider.target = self;
    self.monitorVolumeSlider.action = @selector(monitorVolumeChanged:);
    self.monitorVolumeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.monitorVolumeSlider.widthAnchor constraintEqualToConstant:60].active = YES;
    self.monitorVolumeSlider.toolTip = @"Audio monitor output volume";

    self.monitorMuteButton = [NSButton buttonWithTitle:@"Mute" target:self action:@selector(monitorMuteClicked:)];
    self.monitorMuteButton.bezelStyle = NSBezelStyleInline;
    self.monitorMuteButton.controlSize = NSControlSizeSmall;
    self.monitorMuteButton.font = [NSFont systemFontOfSize:10];
    self.monitorMuteButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.cwNarrowFilterButton = [NSButton checkboxWithTitle:@"200Hz Filter" target:self action:@selector(cwFilterClicked:)];
    self.cwNarrowFilterButton.controlSize = NSControlSizeSmall;
    self.cwNarrowFilterButton.font = [NSFont systemFontOfSize:10.5];
    self.cwNarrowFilterButton.state = NSControlStateValueOn;
    self.cwNarrowFilterButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.cwNarrowFilterButton.toolTip = @"DSP 200 Hz steep bandpass filter centered at Morse pitch";

    // Separators
    NSBox *div1 = [NSBox new]; div1.boxType = NSBoxSeparator; div1.translatesAutoresizingMaskIntoConstraints = NO;
    [div1.heightAnchor constraintEqualToConstant:16].active = YES;
    NSBox *div2 = [NSBox new]; div2.boxType = NSBoxSeparator; div2.translatesAutoresizingMaskIntoConstraints = NO;
    [div2.heightAnchor constraintEqualToConstant:16].active = YES;
    NSBox *div3 = [NSBox new]; div3.boxType = NSBoxSeparator; div3.translatesAutoresizingMaskIntoConstraints = NO;
    [div3.heightAnchor constraintEqualToConstant:16].active = YES;

    NSView *spacerR1 = [NSView new];
    spacerR1.translatesAutoresizingMaskIntoConstraints = NO;
    [spacerR1 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *r1 = [NSStackView stackViewWithViews:@[
        self.startStopDecoderButton,
        self.audioDevicePopup,
        modeTitle,
        self.modePopup,
        self.simulationCheckbox,
        div1,
        self.monitorToggleButton,
        self.monitorVolumeSlider,
        self.monitorMuteButton,
        self.cwNarrowFilterButton,
        spacerR1
    ]];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.alignment = NSLayoutAttributeCenterY;
    r1.spacing = 6;

    // Row 2: Per-Message Recording + Pitch + Speed
    self.recordButton = [NSButton buttonWithTitle:@"● REC" target:self action:@selector(toggleRecording)];
    self.recordButton.bezelStyle = NSBezelStyleRounded;
    self.recordButton.controlSize = NSControlSizeSmall;
    self.recordButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.recordButton.contentTintColor = [NSColor systemRedColor];
    self.recordButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.recordButton.widthAnchor constraintEqualToConstant:65].active = YES;
    self.recordButton.toolTip = @"Record Morse audio transmissions to WAV file";

    self.recordStatusLabel = [NSTextField labelWithString:@""];
    self.recordStatusLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightBold];
    self.recordStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.recordStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.revealRecordingsButton = [NSButton buttonWithTitle:@"Recordings ↗" target:self action:@selector(revealRecordingsClicked:)];
    self.revealRecordingsButton.bezelStyle = NSBezelStyleInline;
    self.revealRecordingsButton.controlSize = NSControlSizeSmall;
    self.revealRecordingsButton.font = [NSFont systemFontOfSize:9.5];
    self.revealRecordingsButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.revealRecordingsButton.toolTip = @"Open recordings directory in Finder";

    self.autoRecordCheckbox = [NSButton checkboxWithTitle:@"Auto-REC QSO" target:nil action:nil];
    self.autoRecordCheckbox.controlSize = NSControlSizeSmall;
    self.autoRecordCheckbox.font = [NSFont systemFontOfSize:10.5];
    self.autoRecordCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.autoRecordCheckbox.toolTip = @"Automatically record audio during each active QSO";

    // Pitch & AFC group
    NSTextField *pitchTitle = [NSTextField labelWithString:@"Pitch:"];
    pitchTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    pitchTitle.textColor = [NSColor secondaryLabelColor];
    pitchTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.pitchSlider = [[NSSlider alloc] init];
    self.pitchSlider.controlSize = NSControlSizeSmall;
    self.pitchSlider.minValue = 300.0;
    self.pitchSlider.maxValue = 1500.0;
    self.pitchSlider.doubleValue = self.decoder.nominalPitchHz;
    self.pitchSlider.target = self;
    self.pitchSlider.action = @selector(pitchSliderChanged:);
    self.pitchSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pitchSlider.widthAnchor constraintEqualToConstant:65].active = YES;

    self.pitchValueLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0fHz", self.decoder.nominalPitchHz]];
    self.pitchValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.pitchValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pitchValueLabel.widthAnchor constraintEqualToConstant:50].active = YES;

    self.afcCheckbox = [NSButton checkboxWithTitle:@"AFC" target:self action:@selector(toggleAFC:)];
    self.afcCheckbox.controlSize = NSControlSizeSmall;
    self.afcCheckbox.font = [NSFont systemFontOfSize:11];
    self.afcCheckbox.state = self.decoder.afcEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.afcCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

    // Speed group
    NSTextField *wpmTitle = [NSTextField labelWithString:@"Speed:"];
    wpmTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    wpmTitle.textColor = [NSColor secondaryLabelColor];
    wpmTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.wpmLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld WPM", (long)self.keyer.wpm]];
    self.wpmLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
    self.wpmLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.wpmLabel.widthAnchor constraintEqualToConstant:50].active = YES;

    self.wpmStepper = [[NSStepper alloc] init];
    self.wpmStepper.controlSize = NSControlSizeSmall;
    self.wpmStepper.minValue = 3;
    self.wpmStepper.maxValue = 45;
    self.wpmStepper.integerValue = self.keyer.wpm;
    self.wpmStepper.target = self;
    self.wpmStepper.action = @selector(wpmStepperChanged:);
    self.wpmStepper.translatesAutoresizingMaskIntoConstraints = NO;

    self.cutNumbersCheckbox = [NSButton checkboxWithTitle:@"Cut 5NN" target:self action:@selector(toggleCutNumbers:)];
    self.cutNumbersCheckbox.controlSize = NSControlSizeSmall;
    self.cutNumbersCheckbox.font = [NSFont systemFontOfSize:11];
    self.cutNumbersCheckbox.state = self.keyer.useCutNumbers ? NSControlStateValueOn : NSControlStateValueOff;
    self.cutNumbersCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *spacerR2 = [NSView new];
    spacerR2.translatesAutoresizingMaskIntoConstraints = NO;
    [spacerR2 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *r2 = [NSStackView stackViewWithViews:@[
        self.recordButton, self.recordStatusLabel, self.revealRecordingsButton, self.autoRecordCheckbox,
        div2,
        pitchTitle, self.pitchSlider, self.pitchValueLabel, self.afcCheckbox,
        div3,
        wpmTitle, self.wpmLabel, self.wpmStepper, self.cutNumbersCheckbox,
        spacerR2
    ]];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.alignment = NSLayoutAttributeCenterY;
    r2.spacing = 6;

    NSStackView *stack = [NSStackView stackViewWithViews:@[r1, r2]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    [container addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [r1.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [r2.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [container.heightAnchor constraintEqualToConstant:68]
    ]];

    return container;
}

#pragma mark - Spectrum & Metrics Row

- (NSView *)buildSpectrumAndMetricsRow {
    NSView *container = [self createCardView];

    self.spectrumView = [[TX500CWSpectrumView alloc] initWithFrame:NSMakeRect(0, 0, 520, 155)];
    self.spectrumView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.spectrumView];

    // Right side metrics box
    NSView *metricCard = [NSView new];
    metricCard.translatesAutoresizingMaskIntoConstraints = NO;
    metricCard.wantsLayer = YES;
    metricCard.layer.cornerRadius = 6.0;
    metricCard.layer.borderWidth = 1.0;
    metricCard.layer.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18].CGColor;
    metricCard.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:0.6].CGColor;
    [container addSubview:metricCard];

    self.carrierLockStatusLabel = [NSTextField labelWithString:@"○ LISTENING"];
    self.carrierLockStatusLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightBold];
    self.carrierLockStatusLabel.textColor = [NSColor secondaryLabelColor];
    self.carrierLockStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.wpmMetricLabel = [NSTextField labelWithString:@"25 WPM"];
    self.wpmMetricLabel.font = [NSFont monospacedDigitSystemFontOfSize:13.0 weight:NSFontWeightBold];
    self.wpmMetricLabel.textColor = [NSColor systemOrangeColor];
    self.wpmMetricLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.snrMetricLabel = [NSTextField labelWithString:@"0.0 dB SNR"];
    self.snrMetricLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    self.snrMetricLabel.textColor = [NSColor labelColor];
    self.snrMetricLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.ditDahMetricLabel = [NSTextField labelWithString:@"Ratio: 1 : 3.0"];
    self.ditDahMetricLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightRegular];
    self.ditDahMetricLabel.textColor = [NSColor secondaryLabelColor];
    self.ditDahMetricLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.activeDitDahLabel = [NSTextField labelWithString:@"[ ]"];
    self.activeDitDahLabel.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightBold];
    self.activeDitDahLabel.textColor = [NSColor systemGreenColor];
    self.activeDitDahLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *metricsStack = [NSStackView stackViewWithViews:@[
        self.carrierLockStatusLabel,
        self.wpmMetricLabel,
        self.snrMetricLabel,
        self.ditDahMetricLabel,
        self.activeDitDahLabel
    ]];
    metricsStack.translatesAutoresizingMaskIntoConstraints = NO;
    metricsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    metricsStack.alignment = NSLayoutAttributeLeading;
    metricsStack.spacing = 3;
    [metricCard addSubview:metricsStack];

    [NSLayoutConstraint activateConstraints:@[
        [metricsStack.leadingAnchor constraintEqualToAnchor:metricCard.leadingAnchor constant:8],
        [metricsStack.trailingAnchor constraintEqualToAnchor:metricCard.trailingAnchor constant:-8],
        [metricsStack.centerYAnchor constraintEqualToAnchor:metricCard.centerYAnchor],

        [self.spectrumView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:6],
        [self.spectrumView.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],
        [self.spectrumView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-5],
        [self.spectrumView.trailingAnchor constraintEqualToAnchor:metricCard.leadingAnchor constant:-8],

        [metricCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [metricCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],
        [metricCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-5],
        [metricCard.widthAnchor constraintEqualToConstant:150],

        [container.heightAnchor constraintEqualToConstant:165]
    ]];

    return container;
}

#pragma mark - Middle Workstation: Split Terminal & Co-Pilot

- (NSView *)buildMiddleWorkstation {
    NSView *container = [self createCardView];

    NSView *terminalColumn = [self buildTerminalColumn];
    [container addSubview:terminalColumn];

    NSView *rightColumn = [self buildRightCoPilotColumn];
    [container addSubview:rightColumn];

    [NSLayoutConstraint activateConstraints:@[
        [terminalColumn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [terminalColumn.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [terminalColumn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [terminalColumn.widthAnchor constraintEqualToAnchor:container.widthAnchor multiplier:0.48],

        [rightColumn.leadingAnchor constraintEqualToAnchor:terminalColumn.trailingAnchor constant:10],
        [rightColumn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [rightColumn.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [rightColumn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],

        [container.heightAnchor constraintEqualToConstant:280]
    ]];

    return container;
}

- (NSView *)buildTerminalColumn {
    NSView *col = [NSView new];
    col.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"Decoded Morse Stream (Terminal):"];
    title.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [col addSubview:title];

    self.clearTerminalButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearTerminal:)];
    self.clearTerminalButton.bezelStyle = NSBezelStyleInline;
    self.clearTerminalButton.controlSize = NSControlSizeSmall;
    self.clearTerminalButton.font = [NSFont systemFontOfSize:10.5];
    self.clearTerminalButton.translatesAutoresizingMaskIntoConstraints = NO;
    [col addSubview:self.clearTerminalButton];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.terminalTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 350, 200)];
    self.terminalTextView.editable = NO;
    self.terminalTextView.backgroundColor = [NSColor colorWithCalibratedWhite:0.06 alpha:1.0];
    self.terminalTextView.textColor = [NSColor colorWithSRGBRed:0.2 green:0.9 blue:0.4 alpha:1.0];
    self.terminalTextView.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    scroll.documentView = self.terminalTextView;
    [col addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:col.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:col.topAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.clearTerminalButton.leadingAnchor constant:-6],

        [self.clearTerminalButton.trailingAnchor constraintEqualToAnchor:col.trailingAnchor],
        [self.clearTerminalButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [scroll.leadingAnchor constraintEqualToAnchor:col.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:col.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:col.bottomAnchor]
    ]];

    return col;
}

- (NSView *)buildRightCoPilotColumn {
    NSView *col = [NSView new];
    col.translatesAutoresizingMaskIntoConstraints = NO;

    // ── 1. Roster Mode Switcher & Table ───────────────────────────────
    self.rosterModeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"⚡ 3kHz Passband Channels", @"📡 Detected CQs"]
                                                               trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                     target:self
                                                                     action:@selector(rosterModeChanged:)];
    self.rosterModeControl.controlSize = NSControlSizeSmall;
    self.rosterModeControl.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.rosterModeControl.selectedSegment = 0;
    self.rosterModeControl.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rosterModeControl setToolTip:@"Switch between wideband Morse signals detected across 3 kHz IF passband and parsed CQ stations" forSegment:0];
    [self.rosterModeControl setToolTip:@"Stations actively calling CQ or TEST" forSegment:1];

    NSScrollView *rosterScroll = [[NSScrollView alloc] init];
    rosterScroll.borderType = NSBezelBorder;
    rosterScroll.hasVerticalScroller = YES;
    rosterScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [rosterScroll.heightAnchor constraintEqualToConstant:76].active = YES;

    self.cqRosterTableView = [[NSTableView alloc] init];
    self.cqRosterTableView.dataSource = self;
    self.cqRosterTableView.delegate = self;
    self.cqRosterTableView.rowHeight = 22;
    self.cqRosterTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *colCall = [[NSTableColumn alloc] initWithIdentifier:@"call"];
    colCall.title = @"Signal / Call"; colCall.width = 85; colCall.minWidth = 60;
    colCall.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colCall];

    NSTableColumn *colWpm = [[NSTableColumn alloc] initWithIdentifier:@"wpm"];
    colWpm.title = @"WPM"; colWpm.width = 44; colWpm.minWidth = 36;
    colWpm.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colWpm];

    NSTableColumn *colSnr = [[NSTableColumn alloc] initWithIdentifier:@"snr"];
    colSnr.title = @"SNR"; colSnr.width = 44; colSnr.minWidth = 36;
    colSnr.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colSnr];

    NSTableColumn *colAction = [[NSTableColumn alloc] initWithIdentifier:@"action"];
    colAction.title = @"Action"; colAction.width = 95; colAction.minWidth = 80;
    colAction.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colAction];

    rosterScroll.documentView = self.cqRosterTableView;

    // ── 2. Co-Pilot Card ──────────────────────────────────────────────
    NSView *coPilotCard = [NSView new];
    coPilotCard.translatesAutoresizingMaskIntoConstraints = NO;
    coPilotCard.wantsLayer = YES;
    coPilotCard.layer.cornerRadius = 6.0;
    coPilotCard.layer.borderWidth = 1.0;
    coPilotCard.layer.borderColor = [NSColor controlAccentColor].CGColor;
    coPilotCard.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.06].CGColor;
    // Allow coPilotCard to expand vertically and fill remaining space
    [coPilotCard setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationVertical];

    self.qsoStateLabel = [NSTextField labelWithString:@"Monitoring traffic. Ready to respond or call CQ."];
    self.qsoStateLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.qsoStateLabel.textColor = [NSColor labelColor];
    self.qsoStateLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.qsoNextActionButton = [NSButton buttonWithTitle:@"▶ Start Calling CQ (F1)" target:self action:@selector(advanceQSOAction:)];
    self.qsoNextActionButton.bezelStyle = NSBezelStyleRounded;
    self.qsoNextActionButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.qsoNextActionButton.contentTintColor = [NSColor controlAccentColor];
    self.qsoNextActionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.qsoNextActionButton.heightAnchor constraintEqualToConstant:28].active = YES;

    self.autoCQButton = [NSButton buttonWithTitle:@"Auto-CQ Repeater" target:self action:@selector(toggleAutoCQ:)];
    self.autoCQButton.bezelStyle = NSBezelStyleRounded;
    self.autoCQButton.controlSize = NSControlSizeSmall;
    self.autoCQButton.font = [NSFont systemFontOfSize:10.5];
    self.autoCQButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.autoCQCountdownLabel = [NSTextField labelWithString:@""];
    self.autoCQCountdownLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightBold];
    self.autoCQCountdownLabel.textColor = [NSColor systemRedColor];
    self.autoCQCountdownLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *cqRow = [NSStackView stackViewWithViews:@[self.autoCQButton, self.autoCQCountdownLabel]];
    cqRow.translatesAutoresizingMaskIntoConstraints = NO;
    cqRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cqRow.spacing = 6;
    cqRow.alignment = NSLayoutAttributeCenterY;

    [self.macroButtons removeAllObjects];
    NSMutableArray *m1 = [NSMutableArray array];
    NSMutableArray *m2 = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.keyer.macroList.count; i++) {
        TX500CWMacro *m = self.keyer.macroList[i];
        NSButton *btn = [NSButton buttonWithTitle:m.label target:self action:@selector(macroButtonClicked:)];
        btn.tag = i;
        btn.bezelStyle = NSBezelStyleRounded;
        btn.controlSize = NSControlSizeSmall;
        btn.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn.heightAnchor constraintEqualToConstant:22].active = YES;
        [self.macroButtons addObject:btn];
        if (i < 4) [m1 addObject:btn]; else [m2 addObject:btn];
    }
    NSStackView *macroRow1 = [NSStackView stackViewWithViews:m1];
    macroRow1.translatesAutoresizingMaskIntoConstraints = NO;
    macroRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    macroRow1.distribution = NSStackViewDistributionFillEqually;
    macroRow1.spacing = 4;

    NSStackView *macroRow2 = [NSStackView stackViewWithViews:m2];
    macroRow2.translatesAutoresizingMaskIntoConstraints = NO;
    macroRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    macroRow2.distribution = NSStackViewDistributionFillEqually;
    macroRow2.spacing = 4;

    self.txInputField = [[NSTextField alloc] init];
    self.txInputField.controlSize = NSControlSizeSmall;
    self.txInputField.font = [NSFont systemFontOfSize:11];
    self.txInputField.placeholderString = @"Type Morse message...";
    self.txInputField.target = self;
    self.txInputField.action = @selector(txSendClicked:);
    self.txInputField.translatesAutoresizingMaskIntoConstraints = NO;

    self.txSendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(txSendClicked:)];
    self.txSendButton.bezelStyle = NSBezelStyleRounded;
    self.txSendButton.controlSize = NSControlSizeSmall;
    self.txSendButton.font = [NSFont systemFontOfSize:11];
    self.txSendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txSendButton.widthAnchor constraintEqualToConstant:50].active = YES;

    self.txTuneButton = [NSButton buttonWithTitle:@"TX (Tune)" target:self action:@selector(txTuneClicked:)];
    self.txTuneButton.bezelStyle = NSBezelStyleRounded;
    self.txTuneButton.controlSize = NSControlSizeSmall;
    self.txTuneButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.txTuneButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txTuneButton.widthAnchor constraintEqualToConstant:78].active = YES;
    self.txTuneButton.toolTip = @"Toggle transceiver TX mode for antenna tuning or carrier test. Click again to return to RX.";

    self.txAbortButton = [NSButton buttonWithTitle:@"ABORT" target:self action:@selector(txAbortClicked:)];
    self.txAbortButton.bezelStyle = NSBezelStyleRounded;
    self.txAbortButton.controlSize = NSControlSizeSmall;
    self.txAbortButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    self.txAbortButton.contentTintColor = [NSColor systemRedColor];
    self.txAbortButton.target = self;
    self.txAbortButton.action = @selector(txAbortClicked:);
    self.txAbortButton.enabled = NO;
    self.txAbortButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txAbortButton.widthAnchor constraintEqualToConstant:60].active = YES;

    NSStackView *txRow = [NSStackView stackViewWithViews:@[self.txInputField, self.txSendButton, self.txTuneButton, self.txAbortButton]];
    txRow.translatesAutoresizingMaskIntoConstraints = NO;
    txRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    txRow.spacing = 4;
    txRow.alignment = NSLayoutAttributeCenterY;

    self.txPowerLabel = [NSTextField labelWithString:@"⚡ PWR: 0.0 W"];
    self.txPowerLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
    self.txPowerLabel.textColor = [NSColor secondaryLabelColor];

    self.txPowerMeterBar = [[NSLevelIndicator alloc] init];
    self.txPowerMeterBar.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
    self.txPowerMeterBar.minValue = 0.0;
    self.txPowerMeterBar.maxValue = 10.0;
    self.txPowerMeterBar.warningValue = 8.5;
    self.txPowerMeterBar.criticalValue = 10.0;
    self.txPowerMeterBar.doubleValue = 0.0;
    self.txPowerMeterBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txPowerMeterBar.widthAnchor constraintEqualToConstant:70].active = YES;

    self.txSwrLabel = [NSTextField labelWithString:@"📶 SWR: 1.0:1"];
    self.txSwrLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
    self.txSwrLabel.textColor = [NSColor secondaryLabelColor];

    self.txSwrMeterBar = [[NSLevelIndicator alloc] init];
    self.txSwrMeterBar.levelIndicatorStyle = NSLevelIndicatorStyleContinuousCapacity;
    self.txSwrMeterBar.minValue = 1.0;
    self.txSwrMeterBar.maxValue = 5.0;
    self.txSwrMeterBar.warningValue = 2.0;
    self.txSwrMeterBar.criticalValue = 3.0;
    self.txSwrMeterBar.doubleValue = 1.0;
    self.txSwrMeterBar.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txSwrMeterBar.widthAnchor constraintEqualToConstant:60].active = YES;

    NSStackView *txMeterRow = [NSStackView stackViewWithViews:@[
        self.txPowerLabel, self.txPowerMeterBar,
        self.txSwrLabel, self.txSwrMeterBar
    ]];
    txMeterRow.translatesAutoresizingMaskIntoConstraints = NO;
    txMeterRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    txMeterRow.spacing = 8;
    txMeterRow.alignment = NSLayoutAttributeCenterY;

    NSStackView *coPilotStack = [NSStackView stackViewWithViews:@[
        self.qsoStateLabel, self.qsoNextActionButton, cqRow, macroRow1, macroRow2, txRow, txMeterRow
    ]];
    coPilotStack.translatesAutoresizingMaskIntoConstraints = NO;
    coPilotStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    coPilotStack.alignment = NSLayoutAttributeLeading;
    coPilotStack.spacing = 5;
    [coPilotCard addSubview:coPilotStack];

    // ── 3. Vertical NSStackView for entire column ─────────────────────
    // Using NSStackView guarantees that rosterModeControl, rosterScroll, and coPilotCard
    // are placed in distinct non-overlapping slots — no z-ordering issues possible.
    NSStackView *colStack = [NSStackView stackViewWithViews:@[self.rosterModeControl, rosterScroll, coPilotCard]];
    colStack.translatesAutoresizingMaskIntoConstraints = NO;
    colStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    colStack.alignment = NSLayoutAttributeLeading;
    colStack.spacing = 5;
    colStack.distribution = NSStackViewDistributionFill;
    [col addSubview:colStack];

    [NSLayoutConstraint activateConstraints:@[
        // colStack fills col
        [colStack.leadingAnchor constraintEqualToAnchor:col.leadingAnchor],
        [colStack.trailingAnchor constraintEqualToAnchor:col.trailingAnchor],
        [colStack.topAnchor constraintEqualToAnchor:col.topAnchor],
        [colStack.bottomAnchor constraintEqualToAnchor:col.bottomAnchor],

        // All managed views fill the full width of colStack
        [self.rosterModeControl.widthAnchor constraintEqualToAnchor:colStack.widthAnchor],
        [rosterScroll.widthAnchor constraintEqualToAnchor:colStack.widthAnchor],
        [coPilotCard.widthAnchor constraintEqualToAnchor:colStack.widthAnchor],

        // coPilotStack pinned inside coPilotCard
        [coPilotStack.leadingAnchor constraintEqualToAnchor:coPilotCard.leadingAnchor constant:8],
        [coPilotStack.trailingAnchor constraintEqualToAnchor:coPilotCard.trailingAnchor constant:-8],
        [coPilotStack.topAnchor constraintEqualToAnchor:coPilotCard.topAnchor constant:6],
        [coPilotStack.bottomAnchor constraintEqualToAnchor:coPilotCard.bottomAnchor constant:-6],

        // Width constraints for coPilotStack children
        [self.qsoNextActionButton.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
        [macroRow1.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
        [macroRow2.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
        [txRow.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
    ]];

    return col;
}


#pragma mark - Bottom QSO Log Section


- (NSView *)buildBottomLogSection {
    NSView *container = [self createCardView];

    NSTextField *logTitle = [NSTextField labelWithString:@"Station Logbook (ADIF Records):"];
    logTitle.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    logTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:logTitle];

    self.exportADIFButton = [NSButton buttonWithTitle:@"Export ADIF (.adi)..." target:self action:@selector(exportADIFClicked:)];
    self.exportADIFButton.bezelStyle = NSBezelStyleRounded;
    self.exportADIFButton.controlSize = NSControlSizeSmall;
    self.exportADIFButton.font = [NSFont systemFontOfSize:11];
    self.exportADIFButton.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.exportADIFButton];

    self.clearLogButton = [NSButton buttonWithTitle:@"Clear Log" target:self action:@selector(clearLogClicked:)];
    self.clearLogButton.bezelStyle = NSBezelStyleRounded;
    self.clearLogButton.controlSize = NSControlSizeSmall;
    self.clearLogButton.font = [NSFont systemFontOfSize:11];
    self.clearLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.clearLogButton];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.logTableView = [[NSTableView alloc] init];
    self.logTableView.dataSource = self;
    self.logTableView.delegate = self;
    self.logTableView.rowHeight = 18;
    self.logTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"logCall"]; c1.title = @"Callsign"; c1.width = 90; c1.minWidth = 75;
    NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"logBand"]; c2.title = @"Band"; c2.width = 55; c2.minWidth = 45;
    NSTableColumn *c3 = [[NSTableColumn alloc] initWithIdentifier:@"logFreq"]; c3.title = @"Freq (MHz)"; c3.width = 80; c3.minWidth = 70;
    NSTableColumn *c4 = [[NSTableColumn alloc] initWithIdentifier:@"logMode"]; c4.title = @"Mode"; c4.width = 50; c4.minWidth = 40;
    NSTableColumn *c5 = [[NSTableColumn alloc] initWithIdentifier:@"logSent"]; c5.title = @"Sent"; c5.width = 50; c5.minWidth = 40;
    NSTableColumn *c6 = [[NSTableColumn alloc] initWithIdentifier:@"logRcvd"]; c6.title = @"Rcvd"; c6.width = 50; c6.minWidth = 40;
    NSTableColumn *c7 = [[NSTableColumn alloc] initWithIdentifier:@"logTime"]; c7.title = @"UTC Time"; c7.width = 130; c7.minWidth = 100;

    for (NSTableColumn *c in @[c1, c2, c3, c4, c5, c6, c7]) {
        c.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        [self.logTableView addTableColumn:c];
    }

    scroll.documentView = self.logTableView;
    [container addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [logTitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [logTitle.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],

        [self.exportADIFButton.trailingAnchor constraintEqualToAnchor:self.clearLogButton.leadingAnchor constant:-6],
        [self.exportADIFButton.centerYAnchor constraintEqualToAnchor:logTitle.centerYAnchor],

        [self.clearLogButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.clearLogButton.centerYAnchor constraintEqualToAnchor:logTitle.centerYAnchor],

        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:logTitle.bottomAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-5],
        [container.heightAnchor constraintEqualToConstant:96]
    ]];

    return container;
}

#pragma mark - Actions

- (void)toggleDecoder:(id)sender {
    (void)sender;
    // In Practice / Sim this button says "STOP SIMULATION": stop the simulation and untick the box,
    // as unticking it does, without listening or sending anything to the radio.
    if (self.decoder.isSimulationActive) {
        self.simulationCheckbox.state = NSControlStateValueOff;
        [self toggleSimulation:self.simulationCheckbox];
        return;
    }
    if (self.decoder.isListening) {
        [self.decoder stopListening];
        self.startStopDecoderButton.title = @"START DECODER";
        self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
        if (self.logHandler) self.logHandler(@"CW Audio Decoder stopped.");
    } else {
        [self prepareRadioForCWMode];
        [self.decoder startListening];
        if (self.decoder.isListening && self.logHandler)
            self.logHandler(@"CW Audio Decoder active: listening on selected audio stream.");
    }
    // Notify host so it can update the status bar pill (CW Decoding / Radio Ready)
    if (self.decoderStateChangedHandler) self.decoderStateChangedHandler(self.decoder.isListening);
}

- (void)toggleSimulation:(NSButton *)sender {
    // A Tune keyed before the box was ticked, or still on when it is unticked, is released through
    // the host sender first; the keyer's RX; below would be swallowed by the gate.
    [self stopManualTune];
    [self.keyer stopAutoCQ]; [self.keyer abortTransmission];
    // A QSO never carries over between practice and the air.
    [self.assistant resetQSOState];
    if (sender.state == NSControlStateValueOn) {
        [self.decoder startSimulation];
        self.startStopDecoderButton.title = @"STOP SIMULATION";
        self.startStopDecoderButton.contentTintColor = [NSColor systemRedColor];
        if (self.logHandler) self.logHandler(@"CW Simulation / Practice Mode active.");
    } else {
        [self.decoder stopSimulation];
        self.startStopDecoderButton.title = @"START DECODER";
        self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
        if (self.logHandler) self.logHandler(@"CW Simulation stopped.");
    }
}

- (void)pitchSliderChanged:(NSSlider *)sender {
    [self.decoder setPitch:sender.doubleValue];
    self.keyer.sidetonePitchHz = sender.doubleValue;
    self.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0fHz", sender.doubleValue];
}

- (void)toggleAFC:(NSButton *)sender {
    self.decoder.afcEnabled = (sender.state == NSControlStateValueOn);
}

- (void)wpmStepperChanged:(NSStepper *)sender {
    self.keyer.wpm = sender.integerValue;
    self.wpmLabel.stringValue = [NSString stringWithFormat:@"%ld WPM", (long)sender.integerValue];
    [self.decoder setNominalWPM:(double)sender.integerValue];
}

- (void)toggleCutNumbers:(NSButton *)sender {
    self.keyer.useCutNumbers = (sender.state == NSControlStateValueOn);
}

- (void)updateAudioDeviceMenu {
    if (!self.audioDevicePopup) return;
    [self.audioDevicePopup removeAllItems];
    NSArray<NSDictionary<NSString *, NSString *> *> *devices = self.decoder.availableAudioInputDevices;
    self.audioDevicePopup.enabled = YES;
    NSMenuItem *selectedItem = nil;
    for (NSInteger i = 0; i < (NSInteger)devices.count; i++) {
        NSDictionary *d = devices[i];
        NSString *disp = d[@"displayName"] ?: d[@"name"] ?: [NSString stringWithFormat:@"Audio Device %ld", (long)i];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:disp action:@selector(audioDeviceChanged:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = d[@"uid"];
        [self.audioDevicePopup.menu addItem:item];
        if (self.decoder.selectedAudioDeviceUID && [d[@"uid"] isEqualToString:self.decoder.selectedAudioDeviceUID]) {
            selectedItem = item;
        }
    }

    [self.audioDevicePopup.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"🔄 Refresh Audio Devices..." action:@selector(refreshAudioDevicesClicked:) keyEquivalent:@""];
    refreshItem.target = self;
    refreshItem.representedObject = @"__REFRESH__";
    [self.audioDevicePopup.menu addItem:refreshItem];

    if (selectedItem) {
        [self.audioDevicePopup selectItem:selectedItem];
    } else {
        // Never display a different device as selected when the saved route is absent.
        NSString *title = self.decoder.selectedAudioDeviceUID.length ? @"Selected input unavailable — choose input…" : @"Choose audio input…";
        NSMenuItem *missing = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        missing.enabled = NO;
        [self.audioDevicePopup.menu insertItem:missing atIndex:0];
        [self.audioDevicePopup selectItem:missing];
    }
}

- (void)applyStationInputDeviceUID:(NSString *)uid {
    if (self.hasLocalAudioSelection || !uid.length || self.decoder.isListening || self.decoder.isSimulationActive) return;
    // Cancel any pending permission request before replacing an inherited route.
    if (![self.decoder.selectedAudioDeviceUID isEqualToString:uid]) [self.decoder stopListening];
    self.decoder.preserveDeviceSelection = YES;
    self.decoder.selectedAudioDeviceUID = uid;
    [self updateKeyerRadioOutputDevice];
    [self updateAudioDeviceMenu];
}

- (void)refreshAudioDevicesClicked:(id)sender {
    (void)sender;
    [self.decoder refreshAudioDevices];
    [self updateKeyerRadioOutputDevice];
    [self updateAudioDeviceMenu];
    if (self.logHandler) {
        self.logHandler(@"[CW Audio] Audio devices refreshed. USB interfaces re-enumerated.");
    }
}

- (void)audioDeviceChanged:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:NSMenuItem.class] ? sender :
        ([sender isKindOfClass:NSPopUpButton.class] ? [sender selectedItem] : nil);
    if (!item) return;
    NSString *uid = item.representedObject;
    if ([uid isEqualToString:@"__REFRESH__"]) {
        [self refreshAudioDevicesClicked:sender];
        return;
    }
    if (uid.length) {
        BOOL changed = ![self.decoder.selectedAudioDeviceUID isEqualToString:uid];
        BOOL resume = self.decoder.isListening && !self.decoder.isSimulationActive;
        if (changed && !self.decoder.isSimulationActive) [self.decoder stopListening];
        self.hasLocalAudioSelection = YES;
        self.decoder.preserveDeviceSelection = YES;
        self.decoder.selectedAudioDeviceUID = uid;
        [self updateKeyerRadioOutputDevice];
        [NSUserDefaults.standardUserDefaults setObject:uid forKey:CWInputPreferenceKey];
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"Selected audio input device: %@", item.title]);
        }
        if (changed && resume) [self.decoder startListening];
        [self updateAudioDeviceMenu];
    }
}

- (void)clearTerminal:(id)sender {
    (void)sender;
    [self.decoder clearBuffer];
    [self.terminalTextView setString:@""];
}

- (void)advanceQSOAction:(id)sender {
    (void)sender;
    __weak typeof(self) weakSelf = self;
    [self.assistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && macroToTransmit.length > 0) {
            [strongSelf stopManualTune];
            [strongSelf prepareRadioForCWMode];
            // A step the keyer refuses (no callsign) leaves the field alone; the console says why.
            if (![strongSelf.keyer templateNeedsMissingCallsign:macroToTransmit])
                strongSelf.txInputField.stringValue = macroToTransmit;
            [strongSelf.keyer transmitText:macroToTransmit
                                targetCall:strongSelf.assistant.activeTargetCallsign
                                       rst:strongSelf.assistant.activeRstSent
                                      name:strongSelf.assistant.activeName
                                       qth:strongSelf.assistant.activeQTH];
        }
    }];
}

- (void)startAutoCQTimer {
    [self.autoCQMonitorTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.autoCQMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer * _Nonnull timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.keyer.isAutoCQActive) {
            [timer invalidate];
            if (strongSelf) {
                strongSelf.autoCQCountdownLabel.stringValue = @"";
                strongSelf.autoCQButton.title = @"Auto-CQ Repeater";
            }
            return;
        }
        NSInteger cd = strongSelf.keyer.autoCQCountdown;
        if (cd > 0) {
            TX500CWKeyer *k = strongSelf.keyer;
            strongSelf.autoCQCountdownLabel.stringValue = k.autoCQMaximumCalls > 0
                ? [NSString stringWithFormat:@"[%lds · %ld/%ld]", (long)cd, (long)k.autoCQCallsSent, (long)k.autoCQMaximumCalls]
                : [NSString stringWithFormat:@"[%lds · %ld]", (long)cd, (long)k.autoCQCallsSent];
        } else {
            strongSelf.autoCQCountdownLabel.stringValue = @"[TX]";
        }
    }];
}

- (void)stopAutoCQTimer {
    [self.autoCQMonitorTimer invalidate];
    self.autoCQMonitorTimer = nil;
    self.autoCQCountdownLabel.stringValue = @"";
}

- (void)toggleAutoCQ:(id)sender {
    (void)sender;
    if (self.keyer.isAutoCQActive) {
        [self.keyer stopAutoCQ];
        [self stopAutoCQTimer];
        self.autoCQButton.title = @"Auto-CQ Repeater";
        self.autoCQCountdownLabel.stringValue = @"";
    } else {
        [self stopManualTune];
        [self prepareRadioForCWMode];
        [self.keyer startAutoCQWithTemplate:@"CQ CQ DE {MYCALL} {MYCALL} K" targetCall:@""];
        if (!self.keyer.isAutoCQActive) return; // blocked: no callsign set
        self.autoCQButton.title = @"Stop Auto-CQ";
        [self startAutoCQTimer];
    }
}

- (void)macroButtonClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.keyer.macroList.count) return;
    [self stopManualTune];
    [self prepareRadioForCWMode];
    TX500CWMacro *m = self.keyer.macroList[idx];
    NSString *expanded = [self.keyer expandTemplate:m.templateString
                                          targetCall:self.assistant.activeTargetCallsign
                                                 rst:self.assistant.activeRstSent
                                                name:self.assistant.activeName
                                                 qth:self.assistant.activeQTH];
    // A macro the keyer refuses (no callsign) leaves the field alone, so Send cannot key it without one.
    if (![self.keyer templateNeedsMissingCallsign:m.templateString])
        self.txInputField.stringValue = expanded;
    [self.keyer triggerMacroAtIndex:idx
                         targetCall:self.assistant.activeTargetCallsign
                                rst:self.assistant.activeRstSent
                               name:self.assistant.activeName
                                qth:self.assistant.activeQTH];
}

- (void)txSendClicked:(id)sender {
    (void)sender;
    NSString *txt = self.txInputField.stringValue;
    if (txt.length == 0) return;
    [self stopManualTune];
    [self prepareRadioForCWMode];
    [self.keyer transmitText:txt
                  targetCall:self.assistant.activeTargetCallsign
                         rst:self.assistant.activeRstSent
                        name:self.assistant.activeName
                         qth:self.assistant.activeQTH];
    self.txInputField.stringValue = @"";
}

- (void)txTuneClicked:(id)sender {
    (void)sender;
    [self toggleManualTransmit];
}

- (void)toggleManualTransmit {
    if (!self.isManualTuneActive) {
        // Practice / Sim keys nothing: no MD6;, no TX; and no carrier.
        if (self.decoder.isSimulationActive) {
            if (self.logHandler) self.logHandler(@"Practice / Sim: TX (Tune) does not key the radio.");
            return;
        }
        // Auto-CQ keys the radio again between its calls: no Tune under it.
        if (self.keyer.isAutoCQActive) {
            if (self.logHandler) self.logHandler(@"CW Station: stop Auto-CQ before tuning.");
            return;
        }
        // A message on the air ends with its own release: a Tune on top of it would send a second
        // TX; and its stop or cutoff would send RX; in the middle of the message.
        if (self.keyer.isTransmitting) {
            if (self.logHandler) self.logHandler(@"CW Station: stop the message (ABORT) before tuning.");
            return;
        }
        [self prepareRadioForCWMode];
        // No TX; before the radio's audio output is open and running: the carrier needs it.
        if (![self.keyer ensureRadioAudioReady]) {
            if (self.logHandler) self.logHandler(@"CW Station: TX (Tune) not started: the radio audio output is not available.");
            return;
        }
        NSString *txCmd = self.keyer.txPrefixCommand.length > 0 ? self.keyer.txPrefixCommand : @"TX;";
        if (self.serialCommandSender) {
            BOOL ok = self.serialCommandSender(txCmd);
            if (ok) {
                self.isManualTuneActive = YES;
                NSUInteger generation = ++self.manualTuneGeneration;
                self.txTuneButton.title = @"■ RX (Stop)";
                self.txTuneButton.contentTintColor = [NSColor systemRedColor];
                self.txAbortButton.enabled = YES;
                self.carrierLockStatusLabel.stringValue = @"● TX (TUNING)";
                self.carrierLockStatusLabel.textColor = [NSColor systemRedColor];
                [self startTXMeterPolling];
                // Automatic safety cutoff for Tune, armed before the carrier so nothing below can skip it
                double cutoff = self.manualTuneCutoffSeconds > 0 ? self.manualTuneCutoffSeconds : 10.0;
                __weak typeof(self) weakSelf = self;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(cutoff * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    typeof(self) strongSelf = weakSelf;
                    if (strongSelf && strongSelf.isManualTuneActive && generation == strongSelf.manualTuneGeneration) {
                        [strongSelf stopManualTransmit];
                        if (strongSelf.logHandler) {
                            strongSelf.logHandler(@"CW Station: Manual Tune 10-second safety cutoff triggered.");
                        }
                    }
                });
                [self.keyer startContinuousCarrierWithPitchHz:self.keyer.sidetonePitchHz];
                if (self.logHandler) {
                    self.logHandler(@"CW Station: Transceiver keyed to TX (Manual Tune)");
                }
            } else {
                if (self.logHandler) {
                    self.logHandler(@"CW Station: Could not key transceiver to TX (check CAT connection)");
                }
                [self noteTransmitRefused];
            }
        }
    } else {
        [self stopManualTransmit];
    }
}

- (void)stopManualTune {
    [self stopManualTransmit];
}

- (void)stopManualTransmit {
    if (self.isManualTuneActive) {
        self.isManualTuneActive = NO;
        self.txTuneButton.title = @"TX (Tune)";
        self.txTuneButton.contentTintColor = nil;
        self.txAbortButton.enabled = self.keyer.isTransmitting;
        self.carrierLockStatusLabel.stringValue = @"○ LISTENING";
        self.carrierLockStatusLabel.textColor = [NSColor secondaryLabelColor];
        [self.keyer stopContinuousCarrier];
        [self stopTXMeterPolling];
        NSString *rxCmd = self.keyer.rxSuffixCommand.length > 0 ? self.keyer.rxSuffixCommand : @"RX;";
        BOOL released = self.serialCommandSender && self.serialCommandSender(rxCmd);
        self.releaseNotConfirmed = !released;
        if (!released) {
            [self showReleaseNotConfirmed];
        } else if (self.logHandler) {
            self.logHandler(@"CW Station: Transceiver returned to RX");
        }
    }
}

// The radio did not confirm RX: say so, and keep ABORT usable (it sends RX; again).
- (void)showReleaseNotConfirmed {
    self.carrierLockStatusLabel.stringValue = @"● TX? RX NOT CONFIRMED";
    self.carrierLockStatusLabel.textColor = [NSColor systemRedColor];
    self.txAbortButton.enabled = YES;
    if (self.logHandler)
        self.logHandler(@"CW Station: RX NOT confirmed by the radio: press ABORT again, or Esc (Stop all), and check the radio's PTT.");
}

#pragma mark - Live Transmit Telemetry Polling (PWR & SWR)

- (void)startTXMeterPolling {
    [self.txMeterPollingTimer invalidate];
    self.txMeterPollingTimer = nil;
    __weak typeof(self) weakSelf = self;
    self.txMeterPollingTimer = [NSTimer scheduledTimerWithTimeInterval:0.18 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf pollTXMeters];
    }];
    self.txMeterSilentPolls = 0;
    [self pollTXMeters];
}

- (void)stopTXMeterPolling {
    [self.txMeterPollingTimer invalidate];
    self.txMeterPollingTimer = nil;
    self.txMeterSilentPolls = 0;
    self.txPowerLabel.stringValue = @"⚡ PWR: 0.0 W";
    self.txPowerLabel.textColor = [NSColor secondaryLabelColor];
    self.txPowerMeterBar.doubleValue = 0.0;
    self.txSwrLabel.stringValue = @"📶 SWR: 1.0:1";
    self.txSwrLabel.textColor = [NSColor secondaryLabelColor];
    self.txSwrMeterBar.doubleValue = 1.0;
    self.liveTXPowerWatts = 0.0;
    self.liveTXSWR = 1.0;
}

- (void)pollTXMeters {
    if (!self.keyer.isTransmitting && !self.isManualTuneActive) {
        [self stopTXMeterPolling];
        return;
    }
    // Practice / Sim puts nothing on the air: the PWR and SWR meters are not read from the radio.
    if (self.decoder.isSimulationActive) return;
    if (!self.catQueryHandler) return;
    // One read at a time: a radio that is slow to answer, or does not answer, must not
    // queue reads ahead of the RX; that ends the transmission. The flag is cleared only
    // when the read returns (below), also after a stop, so a new transmission never
    // starts a second read beside one still waiting.
    if (self.txMeterPollInFlight) return;
    self.txMeterPollInFlight = YES;

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *pwrReply = nil;
        NSString *swrReply = nil;
        if (strongSelf.keyer.isTransmitting || strongSelf.isManualTuneActive) {
            pwrReply = strongSelf.catQueryHandler(@"RM0;RM;", 0.2);
            // The transmission may have ended during the first read: no second read then.
            if (strongSelf.keyer.isTransmitting || strongSelf.isManualTuneActive) {
                swrReply = strongSelf.catQueryHandler(@"RM1;RM;", 0.2);
            }
        }

        NSInteger pwrDots = -1;
        if (pwrReply.length >= 7) {
            NSRange r = [pwrReply rangeOfString:@"RM0"];
            if (r.location != NSNotFound && pwrReply.length >= r.location + 7) {
                NSString *dotsStr = [pwrReply substringWithRange:NSMakeRange(r.location + 3, 4)];
                pwrDots = dotsStr.integerValue;
            }
        }

        NSInteger swrDots = -1;
        if (swrReply.length >= 7) {
            NSRange r = [swrReply rangeOfString:@"RM1"];
            if (r.location != NSNotFound && swrReply.length >= r.location + 7) {
                NSString *dotsStr = [swrReply substringWithRange:NSMakeRange(r.location + 3, 4)];
                swrDots = dotsStr.integerValue;
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) uiSelf = weakSelf;
            if (!uiSelf) return;
            uiSelf.txMeterPollInFlight = NO;
            if (!uiSelf.keyer.isTransmitting && !uiSelf.isManualTuneActive) return;
            [uiSelf updateLiveTXPowerDots:pwrDots swrDots:swrDots];
            if (pwrDots >= 0 || swrDots >= 0) {
                uiSelf.txMeterSilentPolls = 0;
            } else if (pwrReply == nil && swrReply == nil) {
                // Three silent polls in a row: stop asking until the next transmission.
                // The meters keep what they show; the transmission itself is not touched.
                uiSelf.txMeterSilentPolls++;
                if (uiSelf.txMeterSilentPolls >= 3 && uiSelf.txMeterPollingTimer) {
                    [uiSelf.txMeterPollingTimer invalidate];
                    uiSelf.txMeterPollingTimer = nil;
                    if (uiSelf.logHandler) {
                        uiSelf.logHandler(@"[CW Station] PWR/SWR meters: no reply from the radio; polling stopped until the next transmission.");
                    }
                }
            }
        });
    });
}

- (void)updateLiveTXPowerDots:(NSInteger)pwrDots swrDots:(NSInteger)swrDots {
    if (pwrDots >= 0) {
        double clampedDots = (double)MAX(0, MIN(30, pwrDots));
        double watts = (clampedDots / 30.0) * 10.0;
        self.liveTXPowerWatts = watts;
        self.txPowerLabel.stringValue = [NSString stringWithFormat:@"⚡ PWR: %.1f W", watts];
        self.txPowerMeterBar.doubleValue = watts;
        if (watts > 0.2) {
            self.txPowerLabel.textColor = [NSColor systemOrangeColor];
        } else {
            self.txPowerLabel.textColor = [NSColor systemYellowColor];
        }
    }

    if (swrDots >= 0) {
        double swr = 1.0;
        if (swrDots <= 0) swr = 1.0;
        else if (swrDots == 1) swr = 1.3;
        else if (swrDots == 2) swr = 1.6;
        else if (swrDots == 3) swr = 1.9;
        else if (swrDots == 4) swr = 2.3;
        else if (swrDots == 5) swr = 2.8;
        else if (swrDots == 6) swr = 3.5;
        else if (swrDots == 7) swr = 4.5;
        else swr = 5.0 + (double)(swrDots - 7) * 0.5;

        self.liveTXSWR = swr;
        if (swr >= 5.0) {
            self.txSwrLabel.stringValue = @"📶 SWR: >5.0";
        } else {
            self.txSwrLabel.stringValue = [NSString stringWithFormat:@"📶 SWR: %.1f:1", swr];
        }
        self.txSwrMeterBar.doubleValue = MIN(5.0, MAX(1.0, swr));

        if (swr <= 1.5) {
            self.txSwrLabel.textColor = [NSColor systemGreenColor];
        } else if (swr <= 2.5) {
            self.txSwrLabel.textColor = [NSColor systemYellowColor];
        } else {
            self.txSwrLabel.textColor = [NSColor systemRedColor];
        }
    }
}

- (void)txAbortClicked:(id)sender {
    (void)sender;
    [self stopManualTune];
    [self stopAutoCQTimer];
    [self.keyer abortTransmission];
    [self.keyer stopAutoCQ];
    self.autoCQButton.title = @"Auto-CQ Repeater";
}

- (void)exportADIFClicked:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Station Log (ADIF)";
    panel.nameFieldStringValue = @"Lab599_CW_Logbook.adi";
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"adi"] ?: UTTypePlainText];
    }

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            BOOL ok = [self.assistant exportADIFToFileURL:panel.URL error:&err];
            if (ok && self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"Exported %lu contacts to %@",
                                 (unsigned long)self.assistant.loggedContacts.count, panel.URL.path]);
            }
        }
    }];
}

- (void)clearLogClicked:(id)sender {
    (void)sender;
    [self.assistant clearLog];
    [self.logTableView reloadData];
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.cqRosterTableView) {
        if (self.rosterModeControl && self.rosterModeControl.selectedSegment == 0) {
            return self.widebandChannels.count;
        } else {
            return self.assistant.heardStations.count;
        }
    } else if (tableView == self.logTableView) {
        return self.assistant.loggedContacts.count;
    }
    return 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.cqRosterTableView) {
        if (self.rosterModeControl && self.rosterModeControl.selectedSegment == 0) {
            NSArray<TX500CWChannelState *> *channels = self.widebandChannels;
            if (row < 0 || row >= (NSInteger)channels.count) return nil;
            TX500CWChannelState *ch = channels[row];

            if ([tableColumn.identifier isEqualToString:@"call"]) {
                NSTextField *tf = [tableView makeViewWithIdentifier:@"chCallCell" owner:self];
                if (!tf) {
                    tf = [NSTextField labelWithString:@""];
                    tf.identifier = @"chCallCell";
                    tf.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBold];
                    tf.textColor = [NSColor systemCyanColor];
                }
                if (ch.extractedCallsign.length > 0) {
                    tf.stringValue = [NSString stringWithFormat:@"%@ (%.0fHz)", ch.extractedCallsign, ch.frequencyHz];
                    tf.textColor = [NSColor systemYellowColor];
                } else {
                    tf.stringValue = [NSString stringWithFormat:@"%.0f Hz", ch.frequencyHz];
                    tf.textColor = [NSColor systemCyanColor];
                }
                return tf;
            } else if ([tableColumn.identifier isEqualToString:@"wpm"]) {
                NSTextField *tf = [tableView makeViewWithIdentifier:@"chWpmCell" owner:self];
                if (!tf) {
                    tf = [NSTextField labelWithString:@""];
                    tf.identifier = @"chWpmCell";
                    tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
                }
                tf.stringValue = [NSString stringWithFormat:@"%.0f", ch.estimatedWPM];
                return tf;
            } else if ([tableColumn.identifier isEqualToString:@"snr"]) {
                NSTextField *tf = [tableView makeViewWithIdentifier:@"chSnrCell" owner:self];
                if (!tf) {
                    tf = [NSTextField labelWithString:@""];
                    tf.identifier = @"chSnrCell";
                    tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
                }
                tf.stringValue = [NSString stringWithFormat:@"%.0fdB", ch.snrDb];
                return tf;
            } else if ([tableColumn.identifier isEqualToString:@"action"]) {
                NSButton *btn = [tableView makeViewWithIdentifier:@"chActionCell" owner:self];
                if (!btn) {
                    btn = [NSButton buttonWithTitle:@"" target:self action:@selector(rosterWidebandAnswerClicked:)];
                    btn.identifier = @"chActionCell";
                    btn.bezelStyle = NSBezelStyleRounded;
                    btn.controlSize = NSControlSizeSmall;
                    btn.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
                    btn.contentTintColor = [NSColor systemGreenColor];
                }
                if (ch.extractedCallsign.length > 0) {
                    btn.title = [NSString stringWithFormat:@"Answer %@", ch.extractedCallsign];
                } else {
                    btn.title = [NSString stringWithFormat:@"Tune %.0fHz", ch.frequencyHz];
                }
                btn.tag = row;
                return btn;
            }
        } else {
            NSArray<TX500CWHeardStation *> *stations = self.assistant.heardStations;
            if (row < 0 || row >= (NSInteger)stations.count) return nil;
            TX500CWHeardStation *st = stations[row];

            if ([tableColumn.identifier isEqualToString:@"call"]) {
                NSTextField *tf = [tableView makeViewWithIdentifier:@"callCell" owner:self];
                if (!tf) {
                    tf = [NSTextField labelWithString:@""];
                    tf.identifier = @"callCell";
                    tf.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightBold];
                    tf.textColor = [NSColor systemYellowColor];
                }
                tf.stringValue = st.callsign;
                return tf;
            } else if ([tableColumn.identifier isEqualToString:@"wpm"]) {
                NSTextField *tf = [tableView makeViewWithIdentifier:@"wpmCell" owner:self];
                if (!tf) {
                    tf = [NSTextField labelWithString:@""];
                    tf.identifier = @"wpmCell";
                    tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
                }
                tf.stringValue = [NSString stringWithFormat:@"%.0f", st.wpm];
                return tf;
            } else if ([tableColumn.identifier isEqualToString:@"snr"]) {
                NSTextField *tf = [tableView makeViewWithIdentifier:@"snrCell" owner:self];
                if (!tf) {
                    tf = [NSTextField labelWithString:@""];
                    tf.identifier = @"snrCell";
                    tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
                }
                tf.stringValue = [NSString stringWithFormat:@"%.0fdB", st.snrDb];
                return tf;
            } else if ([tableColumn.identifier isEqualToString:@"action"]) {
                NSButton *btn = [tableView makeViewWithIdentifier:@"actionCell" owner:self];
                if (!btn) {
                    btn = [NSButton buttonWithTitle:@"" target:self action:@selector(rosterAnswerClicked:)];
                    btn.identifier = @"actionCell";
                    btn.bezelStyle = NSBezelStyleRounded;
                    btn.controlSize = NSControlSizeSmall;
                    btn.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
                    btn.contentTintColor = [NSColor systemGreenColor];
                }
                btn.title = [NSString stringWithFormat:@"Answer %@", st.callsign];
                btn.tag = row;
                return btn;
            }
        }
    } else if (tableView == self.logTableView) {
        NSArray<TX500QSOContact *> *contacts = self.assistant.loggedContacts;
        if (row < 0 || row >= (NSInteger)contacts.count) return nil;
        TX500QSOContact *c = contacts[row];

        NSTextField *tf = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = tableColumn.identifier;
            tf.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        }
        if ([tableColumn.identifier isEqualToString:@"logCall"]) {
            tf.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBold];
            tf.stringValue = c.callsign ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logBand"]) {
            tf.stringValue = c.band ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logFreq"]) {
            tf.stringValue = c.frequencyMHz > 0.0 ? [NSString stringWithFormat:@"%.4f", c.frequencyMHz] : @"—";
        } else if ([tableColumn.identifier isEqualToString:@"logMode"]) {
            tf.stringValue = c.mode ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logSent"]) {
            tf.stringValue = c.rstSent ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logRcvd"]) {
            tf.stringValue = c.rstRcvd ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logTime"]) {
            tf.stringValue = [NSString stringWithFormat:@"%@ %@", c.qsoDate ?: @"", c.timeOn ?: @""];
        }
        return tf;
    }
    return nil;
}

- (void)rosterAnswerClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    NSArray<TX500CWHeardStation *> *stations = self.assistant.heardStations;
    if (row < 0 || row >= (NSInteger)stations.count) return;
    [self stopManualTune];
    [self prepareRadioForCWMode];
    TX500CWHeardStation *st = stations[row];

    [self.assistant selectAndAnswerStation:st];
    self.keyer.wpm = (NSInteger)st.wpm;
    self.wpmStepper.integerValue = self.keyer.wpm;
    self.wpmLabel.stringValue = [NSString stringWithFormat:@"%ld WPM", (long)self.keyer.wpm];
    [self.decoder setNominalWPM:st.wpm];

    // Through the keyer's template, so it refuses {MYCALL} while no callsign is set.
    NSString *answerTemplate = @"{CALL} DE {MYCALL} K";
    if (![self.keyer templateNeedsMissingCallsign:answerTemplate])
        self.txInputField.stringValue = [self.keyer expandTemplate:answerTemplate targetCall:st.callsign rst:@"599" name:@"" qth:@""];

    // Trigger immediate transmission of answer
    [self.keyer transmitText:answerTemplate
                  targetCall:st.callsign
                         rst:@"599"
                        name:@""
                         qth:@""];
}

- (void)rosterWidebandAnswerClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    if (row < 0 || row >= (NSInteger)self.widebandChannels.count) return;
    TX500CWChannelState *ch = self.widebandChannels[row];
    [self answerWidebandChannel:ch];
}

- (void)answerWidebandChannel:(TX500CWChannelState *)channel {
    if (!channel) return;
    [self stopManualTune];
    [self prepareRadioForCWMode];
    double freq = channel.frequencyHz;

    // 1. Tune receiver pitch or radio VFO
    if (freq <= 1500.0) {
        [self.decoder setPitch:freq];
        self.keyer.sidetonePitchHz = freq;
        self.pitchSlider.doubleValue = freq;
        self.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0fHz", freq];
    } else {
        // Frequency is higher than 1500 Hz: shift radio dial VFO so it centers at 650 Hz
        if (self.currentDialFrequencyHz == 0) {
            // No retune without a frequency read from the radio, so no answer off the station either.
            if (self.logHandler)
                self.logHandler([NSString stringWithFormat:@"[CW Station] Cannot retune to answer at %.0f Hz: the radio frequency is unknown. Pick a band, or reopen the CW tab to read it from the radio.", freq]);
            return;
        }
        int64_t delta = (int64_t)round(freq - 650.0);
        // A refused retune leaves the radio where it was: an answer now would go out off the station.
        if (![self stepFrequencyHz:delta]) {
            if (self.logHandler)
                self.logHandler([NSString stringWithFormat:@"[CW Station] Could not retune to answer %@ at %.0f Hz: the radio refused the frequency change.", channel.extractedCallsign.length ? channel.extractedCallsign : @"the carrier", freq]);
            return;
        }
        [self.decoder setPitch:650.0];
        self.keyer.sidetonePitchHz = 650.0;
        self.pitchSlider.doubleValue = 650.0;
        self.pitchValueLabel.stringValue = @"650Hz";
    }
    [self updateVFOOffsetLabel];

    // 2. Set decoder & keyer WPM to match this station
    if (channel.estimatedWPM >= 5.0 && channel.estimatedWPM <= 45.0) {
        self.keyer.wpm = (NSInteger)channel.estimatedWPM;
        self.wpmStepper.integerValue = self.keyer.wpm;
        self.wpmLabel.stringValue = [NSString stringWithFormat:@"%ld WPM", (long)self.keyer.wpm];
        [self.decoder setNominalWPM:channel.estimatedWPM];
    }

    // 3. If a callsign was recognized on this channel, initiate response
    BOOL missingCallsign = NO;
    if (channel.extractedCallsign.length > 0) {
        TX500CWHeardStation *st = [[TX500CWHeardStation alloc] init];
        st.callsign = channel.extractedCallsign;
        st.wpm = channel.estimatedWPM;
        st.snrDb = channel.snrDb;
        st.timestamp = [NSDate date];
        [self.assistant selectAndAnswerStation:st];

        // Through the keyer's template, as the roster's Answer, so it refuses {MYCALL} while no callsign is set.
        NSString *answerTemplate = @"{CALL} DE {MYCALL} K";
        missingCallsign = [self.keyer templateNeedsMissingCallsign:answerTemplate];
        if (!missingCallsign)
            self.txInputField.stringValue = [self.keyer expandTemplate:answerTemplate targetCall:channel.extractedCallsign rst:@"599" name:@"" qth:@""];
        [self.keyer transmitText:answerTemplate
                      targetCall:channel.extractedCallsign
                             rst:@"599"
                            name:@""
                             qth:@""];
    }

    if (self.logHandler) {
        if (missingCallsign) {
            self.logHandler([NSString stringWithFormat:@"[CW Station] Tuned to %@ at %.0f Hz; no answer sent without your callsign.", channel.extractedCallsign, freq]);
        } else if (channel.extractedCallsign.length > 0) {
            self.logHandler([NSString stringWithFormat:@"[CW Station] Tuned & answered %@ at %.0f Hz.", channel.extractedCallsign, freq]);
        } else {
            self.logHandler([NSString stringWithFormat:@"[CW Station] Tuned receiver to carrier at %.0f Hz.", freq]);
        }
    }
}

@end
