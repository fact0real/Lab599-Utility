// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500SSTVOptionNotes.h"

@implementation TX500SSTVOptionNotes

+ (NSArray<NSString *> *)modeTitles {
    return @[@"Auto (VIS)", @"Martin M1", @"Martin M2", @"Scottie S1", @"Scottie S2", @"Robot 36", @"PD 90", @"PD 120"];
}

+ (NSString *)noteForMode:(TX500SSTVModeChoice)mode {
    switch (mode) {
    case TX500SSTVModeAuto:
        return @"Good for: everyday listening: the VIS header names the mode and the leader tone sets the tuning · "
               @"Not good for: a picture joined in the middle, after its header: choose its mode by hand.";
    case TX500SSTVModeMartin1:
        return @"Good for: best Martin quality, true RGB colour, usual in Europe · "
               @"Not good for: speed (114 s, nearly twice M2); needs an exact line rate or the picture slants.";
    case TX500SSTVModeMartin2:
        return @"Good for: true colour (RGB) in 58 s, the fastest RGB mode in MMSSTV's mode table; commonly used in Europe · "
               @"Not good for: fine detail (colour line half M1's; width 320 or 160 columns, sources disagree); needs an exact line rate.";
    case TX500SSTVModeScottie1:
        return @"Good for: practically Martin M1 quality in 110 s, true colour; Scottie modes are popular in the US (Barber, 2000) and almost all signals in Japan were S1 (JE3HHT's observation, 2002) · "
               @"Not good for: speed; its extra 9 ms first-line sync and mid-line sync have caused considerable confusion (Barber).";
    case TX500SSTVModeScottie2:
        return @"Good for: most frequent mode in a single-station 2014 HF sample, a limited study (52% in the article's list); 71 s in true colour · "
               @"Not good for: fine detail (colour line 64% of S1's; width 320 or 160 columns, sources disagree); Scottie's extra first-line sync and mid-line sync have caused considerable confusion (Barber).";
    case TX500SSTVModeRobot36:
        return @"Good for: the fastest of the modes here (36 s; Robot 12/24 are faster but not listed); short ISS/satellite passes over FM (ARISS announced it for 2026) · "
               @"Not good for: HF SSB: colour shifts beyond ±50 Hz mistuning, weak against noise and interference.";
    case TX500SSTVModePD90:
        return @"Good for: better than Martin M1/Scottie S1 in less time (90 s, 532 µs per pixel) · "
               @"Not good for: mistuning (YCrCb colour needs accurate tuning); less robust to interference than RGB.";
    case TX500SSTVModePD120:
        return @"Good for: fastest high-res mode (640 px wide, 126 s); ARISS announced it for ISS events in 2025 (Series 26 in April, and a July event) · "
               @"Not good for: top quality (190 µs per pixel, the shortest in the sources); mistuning.";
    }
    return @"";
}

+ (NSArray<NSString *> *)colourScaleTitles { return @[@"Studio (Barber)", @"Full range"]; }

+ (NSString *)noteForColourScale:(TX500SSTVColourScale)scale {
    if (scale == TX500SSTVColourScaleFull)
        return @"Robot and PD only. Good for: senders that use the full 0-255 range (Open-SSTV does) · "
               @"Not good for: senders that follow Barber's studio scale: their pictures look flat.";
    return @"Robot and PD only. Good for: senders that follow Barber's studio scale (16-235), the standard · "
           @"Not good for: senders that use the full 0-255 range: blacks and whites come out clipped.";
}

+ (NSString *)noteForInputKind:(TX500SSTVInputKind)kind {
    switch (kind) {
    case TX500SSTVInputRadio:
        return @"Good for: the TX-500's receive audio, as set in the Station screen; the default every session · "
               @"Not good for: nothing yet if the Station screen names no radio input: choose it there first.";
    case TX500SSTVInputOther:
        return @"Good for: another radio or sound interface on this Mac, chosen by you · "
               @"Not good for: the TX-500 when the Station screen already names its input: use the first choice.";
    case TX500SSTVInputBuiltIn:
        return @"Good for: nothing on the air, unless the radio's audio really reaches it · "
               @"Not good for: listening to the radio: it hears the room. Used only when you choose it, never on its own, and it asks before it opens.";
    case TX500SSTVInputVirtual:
        return @"Good for: the audio of another program on this Mac (a virtual cable, an SDR program), chosen by you · "
               @"Not good for: the radio itself: use the first choice.";
    }
    return @"";
}

+ (NSString *)noteForUploadNow:(BOOL)ticked {
    return ticked
        ? @"Upload now. Good for: the QSO goes at once to the cloud logs enabled and configured in the Logbook's Settings "
          @"(QRZ, Club Log, eQSL, LoTW) · Not good for: a QSO you want to check first: leave it unticked."
        : @"Not now (the default): the QSO is saved in the Logbook and stays pending there. Good for: checking it first; "
          @"Sync All or Sync Selected in the Logbook sends it later · Not good for: having it in the cloud logs at once: tick it.";
}

+ (NSString *)noteForRecordOrDiscard {
    return @"Record or discard: your call. Record QSO · Good for: a picture that is part of a contact with that station, "
           @"even one that began in another mode or by appointment (phone, CW, a VARA chat, a satellite QSO) · Not good for: "
           @"a picture you only received, with no contact (from the ISS, for example): that is a reception. Discard QSO · "
           @"Good for: a reception: nothing goes into the Logbook · Not good for: a contact: it would be missing from the "
           @"Logbook (while its reception is in the list, Record QSO… on its row can still log it).";
}

+ (NSArray<NSNumber *> *)diskShares { return @[@0.0, @0.005, @0.01, @0.02, @0.05]; }
+ (NSInteger)defaultDiskIndex { return 2; }
+ (NSArray<NSString *> *)diskTitles {
    return @[@"Off", @"0.5 % of the disk", @"1 % of the disk", @"2 % of the disk", @"5 % of the disk"];
}

+ (NSString *)noteForDiskShareAtIndex:(NSInteger)index {
    switch (index) {
    case 0: return @"Good for: no disk use: nothing is saved (no recordings, no pictures), except a reception you mark Keep: that one only, by your choice · "
                   @"Not good for: once the app quits, a picture can no longer be decoded again.";
    case 1: return @"Good for: small or nearly full disks · "
                   @"Not good for: long sessions: the oldest recordings make room first (never those marked Keep).";
    case 2: return @"Good for: most stations; the default · "
                   @"Not good for: a contest weekend on a small disk: mark the ones you want to keep.";
    case 3: return @"Good for: contests and long expeditions · Not good for: small disks.";
    case 4: return @"Good for: weeks of listening with nobody there · "
                   @"Not good for: a disk with little free space: it never takes more than a tenth of the free space plus what the recordings already use, and then says so.";
    }
    return @"";
}

+ (NSArray<NSArray<NSString *> *> *)faxOptionsFor:(NSString *)selector {
    if ([selector isEqualToString:@"deviation"]) return @[
        @[@"±400 Hz", (@"Good for: HF stations: the WMO's figure for HF · "
                      @"Not good for: stations at ±425 Hz (DWD): the greys come out a little off, and the phasing check says so.")],
        @[@"±425 Hz", @"Good for: the DWD (Germany) · Not good for: WMO-standard HF stations."],
        @[@"±300 Hz", @"Good for: some press stations (JVFAX manual) · Not good for: WMO-standard stations."],
        @[@"±150 Hz", @"Good for: LF stations (the WMO's figure for LF) · Not good for: HF stations."]];
    if ([selector isEqualToString:@"lpm"]) return @[
        @[@"120", (@"Good for: most of the DWD and NOAA schedules (120 LPM, IOC 576) · "
                  @"Not good for: stations at 60, 90 or 240: the phasing check says the speed does not fit.")],
        @[@"60", @"Good for: stations that send at 60 (a WMO speed) · Not good for: the usual 120."],
        @[@"90", @"Good for: stations that send at 90 (a WMO speed) · Not good for: the usual 120."],
        @[@"240", @"Good for: stations that send at 240 (a WMO speed) · Not good for: the usual 120."]];
    if ([selector isEqualToString:@"ioc"]) return @[
        @[@"576", @"Good for: the IOC most used (576, then 288) · Not good for: stations that send at IOC 288."],
        @[@"288", @"Good for: the few stations that send at IOC 288 · Not good for: IOC 576 charts: wrong aspect ratio."]];
    if ([selector isEqualToString:@"width"]) return @[
        @[@"1810 points", (@"Good for: the standard: π × 576 = 1809.6, to the nearest whole point · "
                          @"Not good for: comparing pixel by pixel with fldigi's files, which are 1809 wide.")],
        @[@"1809 points (fldigi)", @"Good for: comparing with fldigi, which saves 1809 · Not good for: the standard width."]];
    if ([selector isEqualToString:@"lineStart"]) return @[
        @[@"Standard (WMO)", (@"Good for: stations that follow the WMO: the line starts at the leading edge of the white phasing pulse, "
                             @"so each line begins with the dead sector, a mostly white band of about 81 of the 1810 points · "
                             @"Not good for: pictures sent by fldigi: they come out 45 points (12.5 ms) to one side.")],
        @[@"fldigi (centre of phasing band)", (@"Good for: pictures sent by fldigi, which starts its lines in the middle of the phasing band "
                                              @"(12.5 ms later at 120 LPM) · Not good for: WMO stations: 45 points to the other side.")],
        @[@"Auto-align (picture seam)", (@"Good for: unknown senders whose charts have no dead sector (the white band at the line start): "
                                        @"the receiver finds where the lines really start from the picture itself · "
                                        @"Not good for: charts with a dead sector, where it does no more than Standard (the phasing and the dead sector "
                                        @"set the margin); charts with a frame or long straight lines near the edge, which can fool it (not tested against that yet).")]];
    return @[];
}

+ (NSArray<NSString *> *)scottieLayoutTitles { return @[@"Auto", @"Barber", @"Open-SSTV"]; }

+ (NSString *)noteForScottieLayout:(TX500SSTVScottieLayout)layout {
    switch (layout) {
    case TX500SSTVScottieLayoutAuto:
        return @"Good for: any Scottie sender: the receiver tells Barber's timing from Open-SSTV's by itself · "
               @"Not good for: a Scottie picture with a black right edge, which can be taken for Open-SSTV's timing.";
    case TX500SSTVScottieLayoutBarber:
        return @"Good for: senders that follow Barber's Scottie timing · "
               @"Not good for: Open-SSTV's pictures: its colour scans are 1.1 % shorter.";
    case TX500SSTVScottieLayoutOpen:
        return @"Good for: pictures from Open-SSTV · "
               @"Not good for: senders that follow Barber's timing.";
    }
    return @"";
}

@end
