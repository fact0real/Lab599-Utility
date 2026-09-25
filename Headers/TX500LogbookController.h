//
//  TX500LogbookController.h
//  Lab599 Utility
//
//  Complete Voice QSO Logger, Callsign Intelligence HUD & Cloud Logbook Controller
//  Integrates SQLite3 persistence, CAT synchronization, live QRZ/HamQTH lookup,
//  and zero-click multi-cloud uploads.
//

#import <Cocoa/Cocoa.h>
#import "TX500LogbookManager.h"
#import "TX500CallsignLookupService.h"
#import "TX500CloudSyncEngine.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500LogbookController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate>

@property (nonatomic, strong, readonly) NSView *view;

// Host & Hardware Integration
@property (nonatomic, copy, nullable) NSString *(^selectedPortProvider)(void);
@property (nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property (nonatomic, copy, nullable) BOOL (^serialCommandSender)(NSString *catCommand);
@property (nonatomic, copy, nullable) void (^openSettingsHandler)(NSString * _Nullable service);

// Radio CAT Sync
- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode;

// User Actions
- (void)openCloudSettingsSheet;
- (void)syncAllPending;
- (void)exportADIF;
- (void)importADIF;

// Voice Logger Focus
- (void)focusCallsignField;
// Opens an editable draft; never saves a contact or uploads it.
- (void)prepareDraftCallsign:(NSString *)callsign frequencyHz:(uint64_t)frequency mode:(NSString *)mode;

// Table & Pill Refresh
- (void)reloadTableData;
- (void)updateCloudStatusPills;

@end

NS_ASSUME_NONNULL_END
