// SPDX-License-Identifier: GPL-3.0-or-later
// The assisted log of an SSTV picture. Nothing is logged
// on its own: after a picture the operator sees "Record QSO" or "Discard QSO", with the fields
// filled in from what the app knows. Every value has a source; none is a fixed default:
//  - the callsign: empty and required (no FSK ID reader yet); never guessed;
//  - the frequency: the radio's, by CAT, only when the reading is valid; else empty and required;
//    it is the reading taken while the picture was received, kept with the reception: logging
//    later never takes the radio's frequency of that moment;
//  - the band: from the frequency, with the band plan;
//  - the mode: SSTV, with no submode (ADIF 3.1.7 lists none for SSTV), and the picture's mode in the
//    comment («Martin M1»); the time: the UTC end of the reception;
//  - the RSV: empty, the operator gives it;
//  - uploading is a separate switch on the form, off by default: recording is not uploading; a QSO
//    not uploaded from its form stays pending in the Logbook, and Sync sends it like any other (SEG-9);
//  - of the station, only what is needed (SEG-19): the operator's own callsign, and their grid only
//    when the station profile has one; nothing else of the profile, and no device identifiers.
// A picture decoded from a file is practice: it is never logged. A reception is logged once at most.
#import <Foundation/Foundation.h>
#import "TX500SSTVEngine.h"
#import "TX500LogbookManager.h"
#import "TX500SSTVRecordingStore.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500SSTVLogDraft : NSObject
/// The picture it logs, while the screen still has it in memory: never held here, so forms waiting
/// their turn keep no pictures (N-memoria-disc-3). The form shows it, or its PNG (N-captura-8).
@property (nonatomic, readonly, weak, nullable) TX500SSTVPicture *picture;
/// The stored reception it logs, when there is one: its frequency and time are used.
@property (nonatomic, readonly, nullable) TX500SSTVStoredReception *reception;
@property (nonatomic, readonly, copy) NSDate *endUTC;
@property (nonatomic, readonly) BOOL fromFile;
@property (nonatomic, copy) NSString *callsign;           // empty until the operator types it
@property (nonatomic) uint64_t frequencyHz;               // 0 until known
@property (nonatomic) BOOL frequencyInvalid;               // something was typed that is not 0.5 to 56 MHz
@property (nonatomic, readonly) BOOL frequencyFromCAT;
@property (nonatomic, copy) NSString *rsv;                // empty until the operator gives it
@property (nonatomic, copy, nullable) NSString *myCallsign;
@property (nonatomic, copy, nullable) NSString *myGrid;    // only a valid Maidenhead locator is logged
@property (nonatomic) BOOL upload;                        // off by default
@property (nonatomic, readonly, copy) NSString *band;     // from the frequency; empty if none
@property (nonatomic, readonly, copy) NSString *mode;     // "SSTV"
@property (nonatomic, readonly, copy) NSString *submode;  // "Martin M1"

/// A draft for a received picture. catFrequencyHz: the radio's valid reading, or nil.
- (instancetype)initWithPicture:(TX500SSTVPicture *)picture catFrequencyHz:(nullable NSNumber *)catFrequencyHz;
/// A draft for a stored reception, with the data kept with it; the picture (the latest, if known)
/// gives the mode, else the reception's own.
- (instancetype)initWithReception:(TX500SSTVStoredReception *)reception picture:(nullable TX500SSTVPicture *)picture;
/// Why it cannot be recorded yet (nil when it can): practice, already logged, no callsign, no frequency.
- (nullable NSString *)problem;
/// The logbook record. Only when problem is nil.
- (nullable TX500LogRecord *)record;
@end

NS_ASSUME_NONNULL_END
