//
//  TX500LogbookManager.m
//  Lab599 Utility
//
//  Production-Grade SQLite3 Logbook & ADIF 3.1 Subsystem
//

#import "TX500LogbookManager.h"
#import "TX500FT8AutoEngine.h"
#import "TX500CWQSOAssistant.h"
#import <sqlite3.h>

NSString * const TX500LogbookDidChangeNotification = @"TX500LogbookDidChangeNotification";

@implementation TX500LogRecord

- (instancetype)init {
    self = [super init];
    if (self) {
        _uuid = [[NSUUID UUID] UUIDString];
        _callsign = @"";
        
        NSDate *now = [NSDate date];
        NSDateFormatter *dfDate = [[NSDateFormatter alloc] init];
        dfDate.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        dfDate.dateFormat = @"yyyyMMdd";
        _qsoDate = [dfDate stringFromDate:now];
        
        NSDateFormatter *dfTime = [[NSDateFormatter alloc] init];
        dfTime.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        dfTime.dateFormat = @"HHmmss";
        _timeOn = [dfTime stringFromDate:now];
        _timeOff = _timeOn;
        
        _stationProfile=[[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TX500_ActiveStationProfile"] copy];
        _band = @"20m";
        _frequencyHz = 14200000;
        _mode = @"USB";
        _rstSent = @"59";
        _rstRcvd = @"59";
        _powerWatts = 10;
        
        _qrzStatus = @"NONE";
        _lotwStatus = @"NONE";
        _clublogStatus = @"NONE";
        _eqslStatus = @"NONE";
        
        NSTimeInterval t = [now timeIntervalSince1970];
        _createdTimestamp = t;
        _updatedTimestamp = t;
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone {
    TX500LogRecord *copy = [[[self class] allocWithZone:zone] init];
    copy.uuid = [self.uuid copy];
    copy.callsign = [self.callsign copy];
    copy.qsoDate = [self.qsoDate copy];
    copy.timeOn = [self.timeOn copy];
    copy.timeOff = [self.timeOff copy];
    copy.band = [self.band copy];
    copy.frequencyHz = self.frequencyHz;
    copy.mode = [self.mode copy];
    copy.submode = [self.submode copy];
    copy.rstSent = [self.rstSent copy];
    copy.rstRcvd = [self.rstRcvd copy];
    copy.name = [self.name copy];
    copy.email = [self.email copy];
    copy.qth = [self.qth copy];
    copy.state = [self.state copy];
    copy.country = [self.country copy];
    copy.grid = [self.grid copy];
    copy.notes = [self.notes copy];
    copy.powerWatts = self.powerWatts;
    copy.stationProfile=[self.stationProfile copy];
    copy.myCall = [self.myCall copy];
    copy.myGrid = [self.myGrid copy];
    copy.qrzStatus = [self.qrzStatus copy];
    copy.lotwStatus = [self.lotwStatus copy];
    copy.clublogStatus = [self.clublogStatus copy];
    copy.eqslStatus = [self.eqslStatus copy];
    copy.imageURL = [self.imageURL copy];
    copy.myPotaRef = [self.myPotaRef copy];
    copy.theirPotaRef = [self.theirPotaRef copy];
    copy.mySotaRef = [self.mySotaRef copy];
    copy.theirSotaRef = [self.theirSotaRef copy];
    copy.iotaRef = [self.iotaRef copy];
    copy.cqZone = [self.cqZone copy];
    copy.ituZone = [self.ituZone copy];
    copy.dxccCode = [self.dxccCode copy];
    copy.createdTimestamp = self.createdTimestamp;
    copy.updatedTimestamp = self.updatedTimestamp;
    return copy;
}

- (NSString *)formattedDate {
    if (self.qsoDate.length == 8) {
        NSString *y = [self.qsoDate substringWithRange:NSMakeRange(0, 4)];
        NSString *m = [self.qsoDate substringWithRange:NSMakeRange(4, 2)];
        NSString *d = [self.qsoDate substringWithRange:NSMakeRange(6, 2)];
        return [NSString stringWithFormat:@"%@-%@-%@", y, m, d];
    }
    return self.qsoDate ?: @"";
}

- (NSString *)formattedTime {
    if (self.timeOn.length >= 4) {
        NSString *hh = [self.timeOn substringWithRange:NSMakeRange(0, 2)];
        NSString *mm = [self.timeOn substringWithRange:NSMakeRange(2, 2)];
        if (self.timeOn.length >= 6) {
            NSString *ss = [self.timeOn substringWithRange:NSMakeRange(4, 2)];
            return [NSString stringWithFormat:@"%@:%@:%@", hh, mm, ss];
        }
        return [NSString stringWithFormat:@"%@:%@", hh, mm];
    }
    return self.timeOn ?: @"";
}

- (double)frequencyMHz {
    return (double)self.frequencyHz / 1e6;
}

+ (NSString *)bandForFrequencyHz:(uint64_t)freqHz {
    double mhz = (double)freqHz / 1e6;
    if (mhz >= 1.8 && mhz <= 2.0) return @"160m";
    if (mhz >= 3.5 && mhz <= 4.0) return @"80m";
    if (mhz >= 5.0 && mhz <= 5.5) return @"60m";
    if (mhz >= 7.0 && mhz <= 7.3) return @"40m";
    if (mhz >= 10.1 && mhz <= 10.15) return @"30m";
    if (mhz >= 14.0 && mhz <= 14.35) return @"20m";
    if (mhz >= 18.068 && mhz <= 18.168) return @"17m";
    if (mhz >= 21.0 && mhz <= 21.45) return @"15m";
    if (mhz >= 24.89 && mhz <= 24.99) return @"12m";
    if (mhz >= 28.0 && mhz <= 29.7) return @"10m";
    if (mhz >= 50.0 && mhz <= 54.0) return @"6m";
    if (mhz >= 144.0 && mhz <= 148.0) return @"2m";
    if (mhz >= 430.0 && mhz <= 450.0) return @"70cm";
    return @"HF";
}

- (NSString *)adifRecordString {
    NSMutableString *outStr = [NSMutableString string];
    void (^addField)(NSString *, NSString *) = ^(NSString *tag, NSString *val) {
        if (!val || val.length == 0) return;
        NSString *trimmed = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 0) {
            NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
            [outStr appendFormat:@"<%@:%lu>%@ ", tag, (unsigned long)data.length, trimmed];
        }
    };

    addField(@"CALL", [self.callsign uppercaseString]);
    addField(@"QSO_DATE", self.qsoDate);
    addField(@"TIME_ON", self.timeOn.length >= 4 ? [self.timeOn substringToIndex:MIN(6, self.timeOn.length)] : @"0000");
    if (self.timeOff.length >= 4) {
        addField(@"TIME_OFF", [self.timeOff substringToIndex:MIN(6, self.timeOff.length)]);
    }
    addField(@"BAND", [self.band lowercaseString]);
    if (self.frequencyHz > 0) {
        addField(@"FREQ", [NSString stringWithFormat:@"%.6f", self.frequencyMHz]);
    }

    NSString *normMode = [self.mode uppercaseString];
    if ([normMode isEqualToString:@"FT4"]) {
        addField(@"MODE", @"MFSK");
        addField(@"SUBMODE", @"FT4");
    } else {
        addField(@"MODE", normMode);
        if (self.submode.length > 0) {
            addField(@"SUBMODE", [self.submode uppercaseString]);
        }
    }

    addField(@"RST_SENT", self.rstSent);
    addField(@"RST_RCVD", self.rstRcvd);
    addField(@"NAME", self.name);
    addField(@"EMAIL", self.email);
    addField(@"QTH", self.qth);
    addField(@"STATE", self.state);
    addField(@"COUNTRY", self.country);
    addField(@"GRIDSQUARE", [self.grid uppercaseString]);
    addField(@"COMMENT", self.notes);
    if (self.powerWatts > 0) {
        addField(@"TX_PWR", [NSString stringWithFormat:@"%ld", (long)self.powerWatts]);
    }
    addField(@"OPERATOR", [self.stationProfile[@"operatorCall"] length] ? self.stationProfile[@"operatorCall"] : self.myCall);
    addField(@"STATION_CALLSIGN", self.myCall);
    addField(@"MY_CALL", self.myCall);
    NSDictionary *stationFields=@{@"operatorName":@"MY_NAME",@"country":@"MY_COUNTRY",@"city":@"MY_CITY",@"state":@"MY_STATE",@"county":@"MY_CNTY",@"cqZone":@"MY_CQ_ZONE",@"ituZone":@"MY_ITU_ZONE",@"iota":@"MY_IOTA",@"rig":@"MY_RIG",@"antenna":@"MY_ANTENNA"};
    for(NSString *key in stationFields) addField(stationFields[key],self.stationProfile[key]);
    if(!self.myPotaRef.length && [self.stationProfile[@"sig"] length]) { addField(@"MY_SIG",self.stationProfile[@"sig"]); addField(@"MY_SIG_INFO",self.stationProfile[@"sigInfo"]); }
    if (self.myGrid.length > 0) {
        addField(@"MY_GRIDSQUARE", [self.myGrid uppercaseString]);
    }
    if ([self.lotwStatus isEqualToString:@"UPLOADED"] || [self.lotwStatus isEqualToString:@"CONFIRMED"]) {
        addField(@"LOTW_QSL_SENT", @"Y");
    }
    if ([self.qrzStatus isEqualToString:@"UPLOADED"] || [self.qrzStatus isEqualToString:@"CONFIRMED"]) {
        addField(@"APP_QRZLOG_STATUS", self.qrzStatus);
    }
    if (self.myPotaRef.length > 0) {
        addField(@"MY_SIG", @"POTA");
        addField(@"MY_SIG_INFO", self.myPotaRef);
    }
    if (self.theirPotaRef.length > 0) {
        addField(@"SIG", @"POTA");
        addField(@"SIG_INFO", self.theirPotaRef);
    }
    if (self.mySotaRef.length > 0) {
        addField(@"MY_SOTA_REF", self.mySotaRef);
    }
    if (self.theirSotaRef.length > 0) {
        addField(@"SOTA_REF", self.theirSotaRef);
    }
    if (self.iotaRef.length > 0) {
        addField(@"IOTA", self.iotaRef);
    }
    if (self.cqZone.length > 0) {
        addField(@"CQZ", self.cqZone);
    }
    if (self.ituZone.length > 0) {
        addField(@"ITUZ", self.ituZone);
    }
    if (self.dxccCode.length > 0) {
        addField(@"DXCC", self.dxccCode);
    }
    [outStr appendString:@"<EOR>\n"];
    return outStr;
}

+ (nullable TX500LogRecord *)recordFromADIFRecordText:(NSString *)adifText {
    if (!adifText || adifText.length == 0) return nil;
    
    NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"<([A-Za-z0-9_]+):(\\d+)(?::[A-Za-z])?>([^<]*)"
                                                                           options:0
                                                                             error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:adifText
                                                              options:0
                                                                range:NSMakeRange(0, adifText.length)];
    for (NSTextCheckingResult *m in matches) {
        if (m.numberOfRanges >= 4) {
            NSString *tag = [[adifText substringWithRange:[m rangeAtIndex:1]] uppercaseString];
            NSInteger len = [[adifText substringWithRange:[m rangeAtIndex:2]] integerValue];
            NSRange valRange = [m rangeAtIndex:3];
            NSString *fullVal = [adifText substringWithRange:valRange];
            if (len <= (NSInteger)fullVal.length) {
                NSString *val = [fullVal substringToIndex:len];
                fields[tag] = [val stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }

    NSString *call = fields[@"CALL"];
    if (!call || call.length == 0) return nil;

    TX500LogRecord *rec = [[TX500LogRecord alloc] init];
    rec.callsign = [call uppercaseString];
    if (fields[@"QSO_DATE"]) rec.qsoDate = fields[@"QSO_DATE"];
    if (fields[@"TIME_ON"]) rec.timeOn = fields[@"TIME_ON"];
    if (fields[@"TIME_OFF"]) rec.timeOff = fields[@"TIME_OFF"];
    if (fields[@"BAND"]) rec.band = [fields[@"BAND"] lowercaseString];
    if (fields[@"FREQ"]) {
        double f = [fields[@"FREQ"] doubleValue];
        rec.frequencyHz = (uint64_t)(f * 1e6);
        if (!fields[@"BAND"]) {
            rec.band = [self bandForFrequencyHz:rec.frequencyHz];
        }
    }
    if (fields[@"MODE"]) rec.mode = [fields[@"MODE"] uppercaseString];
    if (fields[@"SUBMODE"]) {
        rec.submode = [fields[@"SUBMODE"] uppercaseString];
        if ([rec.mode isEqualToString:@"MFSK"] && [rec.submode isEqualToString:@"FT4"]) {
            rec.mode = @"FT4";
        }
    }
    if (fields[@"RST_SENT"]) rec.rstSent = fields[@"RST_SENT"];
    if (fields[@"RST_RCVD"]) rec.rstRcvd = fields[@"RST_RCVD"];
    if (fields[@"NAME"]) rec.name = fields[@"NAME"];
    if (fields[@"EMAIL"]) rec.email = fields[@"EMAIL"];
    if (fields[@"QTH"]) rec.qth = fields[@"QTH"];
    if (fields[@"STATE"]) rec.state = fields[@"STATE"];
    if (fields[@"COUNTRY"]) rec.country = fields[@"COUNTRY"];
    if (fields[@"GRIDSQUARE"]) rec.grid = [fields[@"GRIDSQUARE"] uppercaseString];
    if (fields[@"COMMENT"]) rec.notes = fields[@"COMMENT"];
    if (fields[@"TX_PWR"]) rec.powerWatts = [fields[@"TX_PWR"] integerValue];
    NSMutableDictionary *identity=[NSMutableDictionary dictionary];
    NSDictionary *identityFields=@{@"OPERATOR":@"operatorCall",@"MY_NAME":@"operatorName",@"MY_COUNTRY":@"country",@"MY_CITY":@"city",@"MY_STATE":@"state",@"MY_CNTY":@"county",@"MY_CQ_ZONE":@"cqZone",@"MY_ITU_ZONE":@"ituZone",@"MY_IOTA":@"iota",@"MY_RIG":@"rig",@"MY_ANTENNA":@"antenna",@"MY_SIG":@"sig",@"MY_SIG_INFO":@"sigInfo"};
    for(NSString *field in identityFields) if(fields[field]) identity[identityFields[field]]=fields[field];
    rec.stationProfile=identity; // Imported records never inherit the current station.
    if(fields[@"STATION_CALLSIGN"]) rec.myCall=fields[@"STATION_CALLSIGN"];
    if (fields[@"MY_CALL"]) rec.myCall = fields[@"MY_CALL"];
    if (fields[@"OPERATOR"] && !rec.myCall) rec.myCall = fields[@"OPERATOR"];
    if (fields[@"MY_GRIDSQUARE"]) rec.myGrid = [fields[@"MY_GRIDSQUARE"] uppercaseString];
    if (fields[@"MY_SIG_INFO"]) rec.myPotaRef = fields[@"MY_SIG_INFO"];
    if (fields[@"SIG_INFO"]) rec.theirPotaRef = fields[@"SIG_INFO"];
    if (fields[@"POTA_REF"] && !rec.theirPotaRef) rec.theirPotaRef = fields[@"POTA_REF"];
    if (fields[@"MY_SOTA_REF"]) rec.mySotaRef = fields[@"MY_SOTA_REF"];
    if (fields[@"SOTA_REF"]) rec.theirSotaRef = fields[@"SOTA_REF"];
    if (fields[@"IOTA"]) rec.iotaRef = fields[@"IOTA"];
    if (fields[@"CQZ"]) rec.cqZone = fields[@"CQZ"];
    if (fields[@"ITUZ"]) rec.ituZone = fields[@"ITUZ"];
    if (fields[@"DXCC"]) rec.dxccCode = fields[@"DXCC"];

    return rec;
}

@end

@interface TX500LogbookManager () {
    sqlite3 *_db;
}
@property (nonatomic, strong) dispatch_queue_t dbQueue;
@property (nonatomic, strong, readwrite) NSURL *databaseURL;
@end

@implementation TX500LogbookManager

+ (instancetype)sharedManager {
    static TX500LogbookManager *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[TX500LogbookManager alloc] initWithDatabaseURL:nil];
    });
    return sInstance;
}

- (instancetype)initWithDatabaseURL:(nullable NSURL *)customURL {
    self = [super init];
    if (self) {
        _dbQueue = dispatch_queue_create("ir.factoreal.tx500.logbook", DISPATCH_QUEUE_SERIAL);
        if (customURL) {
            _databaseURL = customURL;
        } else {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
            NSString *testRoot = environment[@"TX500_TEST_ROOT"];
            NSURL *dir = nil;
            if (environment[@"TX500_TEST_MODE"].boolValue && testRoot.length > 0) {
                dir = [NSURL fileURLWithPath:testRoot isDirectory:YES];
            } else {
                NSURL *appSupport = [fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
                dir = [appSupport URLByAppendingPathComponent:@"Lab599 Utility" isDirectory:YES];
            }
            [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
            _databaseURL = [dir URLByAppendingPathComponent:@"TX500_Logbook.sqlite"];
        }
        [self openDatabase:nil];
    }
    return self;
}

- (void)dealloc {
    [self closeDatabase];
}

- (BOOL)openDatabase:(NSError **)error {
    __block BOOL success = YES;
    __block NSError *localErr = nil;

    dispatch_sync(self.dbQueue, ^{
        if (self->_db) return; // already open
        
        int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX;
        int rc = sqlite3_open_v2([self.databaseURL.path UTF8String], &(self->_db), flags, NULL);
        if (rc != SQLITE_OK) {
            const char *errmsg = sqlite3_errmsg(self->_db);
            localErr = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                           code:rc
                                       userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:errmsg ?: "Failed to open SQLite database"]}];
            success = NO;
            return;
        }

        // Initialize Schema
        const char *schema =
        "PRAGMA journal_mode = WAL;"
        "PRAGMA synchronous = NORMAL;"
        "CREATE TABLE IF NOT EXISTS qsos ("
        "  uuid TEXT PRIMARY KEY,"
        "  callsign TEXT NOT NULL,"
        "  qso_date TEXT NOT NULL,"
        "  time_on TEXT NOT NULL,"
        "  time_off TEXT,"
        "  band TEXT NOT NULL,"
        "  frequency_hz INTEGER NOT NULL,"
        "  mode TEXT NOT NULL,"
        "  submode TEXT,"
        "  rst_sent TEXT NOT NULL,"
        "  rst_rcvd TEXT NOT NULL,"
        "  name TEXT,"
        "  qth TEXT,"
        "  state TEXT,"
        "  country TEXT,"
        "  grid TEXT,"
        "  notes TEXT,"
        "  power_watts INTEGER NOT NULL DEFAULT 10,"
        "  my_call TEXT,"
        "  my_grid TEXT,"
        "  qrz_status TEXT NOT NULL DEFAULT 'NONE',"
        "  lotw_status TEXT NOT NULL DEFAULT 'NONE',"
        "  clublog_status TEXT NOT NULL DEFAULT 'NONE',"
        "  eqsl_status TEXT NOT NULL DEFAULT 'NONE',"
        "  image_url TEXT,"
        "  created_at REAL NOT NULL,"
        "  updated_at REAL NOT NULL,"
        "  my_pota_ref TEXT,"
        "  their_pota_ref TEXT,"
        "  my_sota_ref TEXT,"
        "  their_sota_ref TEXT,"
        "  iota_ref TEXT,"
        "  cq_zone TEXT,"
        "  itu_zone TEXT,"
        "  dxcc_code TEXT, station_profile TEXT, email TEXT"
        ");"
        "CREATE INDEX IF NOT EXISTS idx_qsos_call_date ON qsos(callsign, qso_date, time_on);"
        "CREATE INDEX IF NOT EXISTS idx_qsos_band_mode ON qsos(band, mode);"
        "CREATE INDEX IF NOT EXISTS idx_qsos_created_at ON qsos(created_at DESC);"
        "CREATE TABLE IF NOT EXISTS cloud_outbox ("
        "  id INTEGER PRIMARY KEY AUTOINCREMENT,"
        "  qso_uuid TEXT NOT NULL,"
        "  service TEXT NOT NULL,"
        "  status TEXT NOT NULL,"
        "  attempts INTEGER NOT NULL DEFAULT 0,"
        "  last_error TEXT,"
        "  updated_at REAL NOT NULL,"
        "  UNIQUE(qso_uuid, service)"
        ");";

        char *err = NULL;
        if (sqlite3_exec(self->_db, schema, NULL, NULL, &err) != SQLITE_OK) {
            NSString *msg = [NSString stringWithUTF8String:err ?: "Schema init error"];
            sqlite3_free(err);
            localErr = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: msg}];
            success = NO;
        } else {
            // Schema migration for existing tables
            NSArray<NSString *> *migrations = @[
                @"ALTER TABLE qsos ADD COLUMN my_pota_ref TEXT;",
                @"ALTER TABLE qsos ADD COLUMN their_pota_ref TEXT;",
                @"ALTER TABLE qsos ADD COLUMN my_sota_ref TEXT;",
                @"ALTER TABLE qsos ADD COLUMN their_sota_ref TEXT;",
                @"ALTER TABLE qsos ADD COLUMN iota_ref TEXT;",
                @"ALTER TABLE qsos ADD COLUMN cq_zone TEXT;",
                @"ALTER TABLE qsos ADD COLUMN itu_zone TEXT;",
                @"ALTER TABLE qsos ADD COLUMN dxcc_code TEXT;",
                @"ALTER TABLE qsos ADD COLUMN station_profile TEXT;",
                @"ALTER TABLE qsos ADD COLUMN email TEXT;"
            ];
            for (NSString *mig in migrations) {
                sqlite3_exec(self->_db, [mig UTF8String], NULL, NULL, NULL);
            }
        }
    });

    if (error && localErr) *error = localErr;
    return success;
}

- (void)closeDatabase {
    dispatch_sync(self.dbQueue, ^{
        if (self->_db) {
            sqlite3_close(self->_db);
            self->_db = NULL;
        }
    });
}

#pragma mark - CRUD

- (BOOL)saveContact:(TX500LogRecord *)record error:(NSError **)error {
    if (!record || record.callsign.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: @"Callsign cannot be empty."}];
        }
        return NO;
    }

    __block BOOL ok = YES;
    __block NSError *localErr = nil;

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) {
            ok = NO;
            return;
        }

        const char *sql =
        "INSERT INTO qsos ("
        "  uuid, callsign, qso_date, time_on, time_off, band, frequency_hz, mode, submode,"
        "  rst_sent, rst_rcvd, name, qth, state, country, grid, notes, power_watts, my_call, my_grid,"
        "  qrz_status, lotw_status, clublog_status, eqsl_status, image_url, created_at, updated_at,"
        "  my_pota_ref, their_pota_ref, my_sota_ref, their_sota_ref, iota_ref, cq_zone, itu_zone, dxcc_code, station_profile, email"
        ") VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26, ?27, ?28, ?29, ?30, ?31, ?32, ?33, ?34, ?35, ?36, ?37)"
        "ON CONFLICT(uuid) DO UPDATE SET "
        "  callsign=excluded.callsign, qso_date=excluded.qso_date, time_on=excluded.time_on, time_off=excluded.time_off,"
        "  band=excluded.band, frequency_hz=excluded.frequency_hz, mode=excluded.mode, submode=excluded.submode,"
        "  rst_sent=excluded.rst_sent, rst_rcvd=excluded.rst_rcvd, name=excluded.name, qth=excluded.qth, state=excluded.state,"
        "  country=excluded.country, grid=excluded.grid, notes=excluded.notes, power_watts=excluded.power_watts,"
        "  my_call=excluded.my_call, my_grid=excluded.my_grid, qrz_status=excluded.qrz_status, lotw_status=excluded.lotw_status,"
        "  clublog_status=excluded.clublog_status, eqsl_status=excluded.eqsl_status, image_url=excluded.image_url,"
        "  my_pota_ref=excluded.my_pota_ref, their_pota_ref=excluded.their_pota_ref, my_sota_ref=excluded.my_sota_ref,"
        "  their_sota_ref=excluded.their_sota_ref, iota_ref=excluded.iota_ref, cq_zone=excluded.cq_zone,"
        "  itu_zone=excluded.itu_zone, dxcc_code=excluded.dxcc_code, station_profile=excluded.station_profile, email=excluded.email, updated_at=excluded.updated_at;";

        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) != SQLITE_OK) {
            localErr = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                           code:3
                                       userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:sqlite3_errmsg(self->_db)]}];
            ok = NO;
            return;
        }

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        record.updatedTimestamp = now;
        if (record.createdTimestamp <= 0) record.createdTimestamp = now;

        sqlite3_bind_text(stmt, 1, [record.uuid UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 2, [[record.callsign uppercaseString] UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 3, [record.qsoDate UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 4, [record.timeOn UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 5, record.timeOff ? [record.timeOff UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 6, [record.band UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_int64(stmt, 7, (sqlite3_int64)record.frequencyHz);
        sqlite3_bind_text(stmt, 8, [record.mode UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 9, record.submode ? [record.submode UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 10, [record.rstSent UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 11, [record.rstRcvd UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 12, record.name ? [record.name UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 13, record.qth ? [record.qth UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 14, record.state ? [record.state UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 15, record.country ? [record.country UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 16, record.grid ? [record.grid UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 17, record.notes ? [record.notes UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_int(stmt, 18, (int)record.powerWatts);
        sqlite3_bind_text(stmt, 19, record.myCall ? [record.myCall UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 20, record.myGrid ? [record.myGrid UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 21, [record.qrzStatus UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 22, [record.lotwStatus UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 23, [record.clublogStatus UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 24, [record.eqslStatus UTF8String], -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 25, record.imageURL ? [record.imageURL UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 26, record.createdTimestamp);
        sqlite3_bind_double(stmt, 27, record.updatedTimestamp);
        sqlite3_bind_text(stmt, 28, record.myPotaRef ? [record.myPotaRef UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 29, record.theirPotaRef ? [record.theirPotaRef UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 30, record.mySotaRef ? [record.mySotaRef UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 31, record.theirSotaRef ? [record.theirSotaRef UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 32, record.iotaRef ? [record.iotaRef UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 33, record.cqZone ? [record.cqZone UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 34, record.ituZone ? [record.ituZone UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt, 35, record.dxccCode ? [record.dxccCode UTF8String] : NULL, -1, SQLITE_TRANSIENT);
        NSData *identityJSON=record.stationProfile ? [NSJSONSerialization dataWithJSONObject:record.stationProfile options:0 error:nil] : nil;
        NSString *identityText=identityJSON ? [[NSString alloc] initWithData:identityJSON encoding:NSUTF8StringEncoding] : nil;
        sqlite3_bind_text(stmt,36,identityText.UTF8String,-1,SQLITE_TRANSIENT);
        sqlite3_bind_text(stmt,37,record.email.UTF8String,-1,SQLITE_TRANSIENT);

        if (sqlite3_step(stmt) != SQLITE_DONE) {
            localErr = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                           code:4
                                       userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:sqlite3_errmsg(self->_db)]}];
            ok = NO;
        }
        sqlite3_finalize(stmt);
    });

    if (ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:TX500LogbookDidChangeNotification object:self];
        });
    } else if (error && localErr) {
        *error = localErr;
    }
    return ok;
}

- (BOOL)deleteContactWithUUID:(NSString *)uuid error:(NSError **)error {
    if (!uuid || uuid.length == 0) return NO;
    __block BOOL ok = YES;
    __block NSError *localErr = nil;

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        const char *sql = "DELETE FROM qsos WHERE uuid = ?1;";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                localErr = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                               code:5
                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:sqlite3_errmsg(self->_db)]}];
                ok = NO;
            }
            sqlite3_finalize(stmt);
        }
        
        // Also cleanup outbox
        const char *delOutbox = "DELETE FROM cloud_outbox WHERE qso_uuid = ?1;";
        if (sqlite3_prepare_v2(self->_db, delOutbox, -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
        }
    });

    if (ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:TX500LogbookDidChangeNotification object:self];
        });
    } else if (error && localErr) {
        *error = localErr;
    }
    return ok;
}

static const char *kQSOSelectColumns =
"uuid, callsign, qso_date, time_on, time_off, band, frequency_hz, mode, submode,"
" rst_sent, rst_rcvd, name, qth, state, country, grid, notes, power_watts, my_call, my_grid,"
" qrz_status, lotw_status, clublog_status, eqsl_status, image_url, created_at, updated_at,"
" my_pota_ref, their_pota_ref, my_sota_ref, their_sota_ref, iota_ref, cq_zone, itu_zone, dxcc_code, station_profile, email";

- (nullable TX500LogRecord *)contactWithUUID:(NSString *)uuid {
    if (!uuid || uuid.length == 0) return nil;
    __block TX500LogRecord *rec = nil;

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        NSString *sql = [NSString stringWithFormat:@"SELECT %s FROM qsos WHERE uuid = ?1 LIMIT 1;", kQSOSelectColumns];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                rec = [self recordFromStatement:stmt];
            }
            sqlite3_finalize(stmt);
        }
    });
    return rec;
}

- (TX500LogRecord *)recordFromStatement:(sqlite3_stmt *)stmt {
    TX500LogRecord *r = [[TX500LogRecord alloc] init];
    r.uuid = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)];
    r.callsign = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 1)];
    r.qsoDate = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 2)];
    r.timeOn = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 3)];
    const char *tOff = (const char *)sqlite3_column_text(stmt, 4);
    if (tOff) r.timeOff = [NSString stringWithUTF8String:tOff];
    r.band = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 5)];
    r.frequencyHz = (uint64_t)sqlite3_column_int64(stmt, 6);
    r.mode = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 7)];
    const char *sub = (const char *)sqlite3_column_text(stmt, 8);
    if (sub) r.submode = [NSString stringWithUTF8String:sub];
    r.rstSent = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 9)];
    r.rstRcvd = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 10)];
    
    const char *name = (const char *)sqlite3_column_text(stmt, 11);
    if (name) r.name = [NSString stringWithUTF8String:name];
    const char *qth = (const char *)sqlite3_column_text(stmt, 12);
    if (qth) r.qth = [NSString stringWithUTF8String:qth];
    const char *state = (const char *)sqlite3_column_text(stmt, 13);
    if (state) r.state = [NSString stringWithUTF8String:state];
    const char *country = (const char *)sqlite3_column_text(stmt, 14);
    if (country) r.country = [NSString stringWithUTF8String:country];
    const char *grid = (const char *)sqlite3_column_text(stmt, 15);
    if (grid) r.grid = [NSString stringWithUTF8String:grid];
    const char *notes = (const char *)sqlite3_column_text(stmt, 16);
    if (notes) r.notes = [NSString stringWithUTF8String:notes];
    
    r.powerWatts = sqlite3_column_int(stmt, 17);
    const char *myCall = (const char *)sqlite3_column_text(stmt, 18);
    if (myCall) r.myCall = [NSString stringWithUTF8String:myCall];
    const char *myGrid = (const char *)sqlite3_column_text(stmt, 19);
    if (myGrid) r.myGrid = [NSString stringWithUTF8String:myGrid];
    
    r.qrzStatus = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 20)];
    r.lotwStatus = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 21)];
    r.clublogStatus = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 22)];
    r.eqslStatus = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 23)];
    
    const char *img = (const char *)sqlite3_column_text(stmt, 24);
    if (img) r.imageURL = [NSString stringWithUTF8String:img];
    
    r.createdTimestamp = sqlite3_column_double(stmt, 25);
    r.updatedTimestamp = sqlite3_column_double(stmt, 26);

    const char *myPota = (const char *)sqlite3_column_text(stmt, 27);
    if (myPota) r.myPotaRef = [NSString stringWithUTF8String:myPota];
    const char *theirPota = (const char *)sqlite3_column_text(stmt, 28);
    if (theirPota) r.theirPotaRef = [NSString stringWithUTF8String:theirPota];
    const char *mySota = (const char *)sqlite3_column_text(stmt, 29);
    if (mySota) r.mySotaRef = [NSString stringWithUTF8String:mySota];
    const char *theirSota = (const char *)sqlite3_column_text(stmt, 30);
    if (theirSota) r.theirSotaRef = [NSString stringWithUTF8String:theirSota];
    const char *iota = (const char *)sqlite3_column_text(stmt, 31);
    if (iota) r.iotaRef = [NSString stringWithUTF8String:iota];
    const char *cqZ = (const char *)sqlite3_column_text(stmt, 32);
    if (cqZ) r.cqZone = [NSString stringWithUTF8String:cqZ];
    const char *ituZ = (const char *)sqlite3_column_text(stmt, 33);
    if (ituZ) r.ituZone = [NSString stringWithUTF8String:ituZ];
    const char *dxcc = (const char *)sqlite3_column_text(stmt, 34);
    if (dxcc) r.dxccCode = [NSString stringWithUTF8String:dxcc];
    const char *identity=(const char *)sqlite3_column_text(stmt,35);
    r.stationProfile=nil;
    if(identity) { id parsed=[NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:identity] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]; if([parsed isKindOfClass:NSDictionary.class]) r.stationProfile=parsed; }
    const char *email=(const char *)sqlite3_column_text(stmt,36);
    if(email) r.email=[NSString stringWithUTF8String:email];

    return r;
}

- (NSArray<TX500LogRecord *> *)allContacts {
    return [self searchContactsWithQuery:nil band:nil mode:nil];
}

- (NSArray<TX500LogRecord *> *)searchContactsWithQuery:(nullable NSString *)query
                                                  band:(nullable NSString *)band
                                                  mode:(nullable NSString *)mode {
    __block NSMutableArray<TX500LogRecord *> *results = [NSMutableArray array];

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;

        NSMutableString *sql = [NSMutableString stringWithFormat:@"SELECT %s FROM qsos WHERE 1=1", kQSOSelectColumns];

        NSMutableArray<NSString *> *args = [NSMutableArray array];
        if (query && query.length > 0) {
            NSString *trimmed = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [sql appendString:@" AND (callsign LIKE ? OR name LIKE ? OR country LIKE ? OR grid LIKE ? OR notes LIKE ? OR their_pota_ref LIKE ? OR their_sota_ref LIKE ? OR iota_ref LIKE ?)"];
            NSString *likeArg = [NSString stringWithFormat:@"%%%@%%", trimmed];
            for (int i = 0; i < 8; i++) [args addObject:likeArg];
        }
        if (band && band.length > 0 && ![band isEqualToString:@"ALL"]) {
            [sql appendString:@" AND band = ?"];
            [args addObject:[band lowercaseString]];
        }
        if (mode && mode.length > 0 && ![mode isEqualToString:@"ALL"]) {
            [sql appendString:@" AND mode = ?"];
            [args addObject:[mode uppercaseString]];
        }
        [sql appendString:@" ORDER BY qso_date DESC, time_on DESC, created_at DESC;"];

        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            for (NSUInteger i = 0; i < args.count; i++) {
                sqlite3_bind_text(stmt, (int)(i + 1), [args[i] UTF8String], -1, SQLITE_TRANSIENT);
            }
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [results addObject:[self recordFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });

    return results;
}

- (NSInteger)totalContactCount {
    __block NSInteger count = 0;
    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, "SELECT COUNT(*) FROM qsos;", -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                count = sqlite3_column_int(stmt, 0);
            }
            sqlite3_finalize(stmt);
        }
    });
    return count;
}

- (NSInteger)confirmedContactCount {
    __block NSInteger count = 0;
    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        const char *sql = "SELECT COUNT(*) FROM qsos WHERE lotw_status='CONFIRMED' OR qrz_status='CONFIRMED';";
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) {
                count = sqlite3_column_int(stmt, 0);
            }
            sqlite3_finalize(stmt);
        }
    });
    return count;
}

#pragma mark - Callsign Intelligence & Dupe Checking

- (NSArray<TX500LogRecord *> *)contactsForCallsign:(NSString *)callsign {
    if (!callsign || callsign.length == 0) return @[];
    NSString *cleanCall = [[callsign uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    __block NSMutableArray<TX500LogRecord *> *results = [NSMutableArray array];

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        NSString *sql = [NSString stringWithFormat:@"SELECT %s FROM qsos WHERE callsign = ?1 ORDER BY qso_date DESC, time_on DESC;", kQSOSelectColumns];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [cleanCall UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                [results addObject:[self recordFromStatement:stmt]];
            }
            sqlite3_finalize(stmt);
        }
    });
    return results;
}

- (NSDictionary<NSString *, id> *)dupeStatusForCallsign:(NSString *)callsign band:(nullable NSString *)band mode:(nullable NSString *)mode {
    if (!callsign || callsign.length == 0) {
        return @{
            @"isDupe": @NO,
            @"isWorkedBefore": @NO,
            @"count": @0,
            @"badgeText": @"NEW QSO",
            @"status": @"NEW",
            @"history": @[]
        };
    }

    NSArray<TX500LogRecord *> *history = [self contactsForCallsign:callsign];
    if (history.count == 0) {
        return @{
            @"isDupe": @NO,
            @"isWorkedBefore": @NO,
            @"count": @0,
            @"badgeText": @"NEW QSO",
            @"status": @"NEW",
            @"history": @[]
        };
    }

    NSString *targetBand = band ? [band lowercaseString] : @"";
    NSString *targetMode = mode ? [mode uppercaseString] : @"";

    TX500LogRecord *matchingDupe = nil;
    for (TX500LogRecord *rec in history) {
        if (targetBand.length > 0 && targetMode.length > 0 &&
            [[rec.band lowercaseString] isEqualToString:targetBand] &&
            [[rec.mode uppercaseString] isEqualToString:targetMode]) {
            matchingDupe = rec;
            break;
        }
    }

    if (matchingDupe) {
        NSString *badge = [NSString stringWithFormat:@"DUPE (%@ %@)", [matchingDupe.band uppercaseString], matchingDupe.mode];
        return @{
            @"isDupe": @YES,
            @"isWorkedBefore": @YES,
            @"count": @(history.count),
            @"badgeText": badge,
            @"status": @"DUPE",
            @"lastQSO": matchingDupe,
            @"history": history
        };
    } else {
        NSMutableSet<NSString *> *workedBands = [NSMutableSet set];
        for (TX500LogRecord *r in history) {
            if (r.band.length > 0) [workedBands addObject:[r.band uppercaseString]];
        }
        NSString *bandsSummary = [[workedBands allObjects] componentsJoinedByString:@", "];
        NSString *badge = [NSString stringWithFormat:@"WORKED BEFORE (%ld: %@)", (long)history.count, bandsSummary];
        return @{
            @"isDupe": @NO,
            @"isWorkedBefore": @YES,
            @"count": @(history.count),
            @"badgeText": badge,
            @"status": @"WORKED",
            @"lastQSO": history.firstObject,
            @"history": history
        };
    }
}

#pragma mark - Award Tracking Engine

- (NSDictionary<NSString *, id> *)awardStatistics {
    __block NSInteger dxccWorked = 0;
    __block NSInteger dxccConfirmed = 0;
    __block NSInteger wasWorked = 0;
    __block NSInteger wasConfirmed = 0;
    __block NSInteger wazWorked = 0;
    __block NSInteger wazConfirmed = 0;
    __block NSInteger potaCount = 0;
    __block NSInteger sotaCount = 0;
    __block NSInteger iotaCount = 0;

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        sqlite3_stmt *stmt = NULL;

        // 1. DXCC Worked (distinct country or dxcc_code)
        const char *sqlDxccW = "SELECT COUNT(DISTINCT CASE WHEN dxcc_code IS NOT NULL AND dxcc_code != '' THEN dxcc_code ELSE country END) FROM qsos WHERE (country IS NOT NULL AND country != '') OR (dxcc_code IS NOT NULL AND dxcc_code != '');";
        if (sqlite3_prepare_v2(self->_db, sqlDxccW, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) dxccWorked = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 2. DXCC Confirmed
        const char *sqlDxccC = "SELECT COUNT(DISTINCT CASE WHEN dxcc_code IS NOT NULL AND dxcc_code != '' THEN dxcc_code ELSE country END) FROM qsos WHERE (lotw_status='CONFIRMED' OR qrz_status='CONFIRMED') AND ((country IS NOT NULL AND country != '') OR (dxcc_code IS NOT NULL AND dxcc_code != ''));";
        if (sqlite3_prepare_v2(self->_db, sqlDxccC, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) dxccConfirmed = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 3. WAS Worked (distinct 2-letter state for US contacts)
        const char *sqlWasW = "SELECT COUNT(DISTINCT UPPER(TRIM(state))) FROM qsos WHERE state IS NOT NULL AND length(TRIM(state)) == 2 AND (country IS NULL OR country = '' OR country LIKE '%United States%' OR country = 'USA');";
        if (sqlite3_prepare_v2(self->_db, sqlWasW, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) wasWorked = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 4. WAS Confirmed
        const char *sqlWasC = "SELECT COUNT(DISTINCT UPPER(TRIM(state))) FROM qsos WHERE (lotw_status='CONFIRMED' OR qrz_status='CONFIRMED') AND state IS NOT NULL AND length(TRIM(state)) == 2 AND (country IS NULL OR country = '' OR country LIKE '%United States%' OR country = 'USA');";
        if (sqlite3_prepare_v2(self->_db, sqlWasC, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) wasConfirmed = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 5. WAZ Worked (CQ Zones)
        const char *sqlWazW = "SELECT COUNT(DISTINCT TRIM(cq_zone)) FROM qsos WHERE cq_zone IS NOT NULL AND TRIM(cq_zone) != '';";
        if (sqlite3_prepare_v2(self->_db, sqlWazW, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) wazWorked = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 6. WAZ Confirmed
        const char *sqlWazC = "SELECT COUNT(DISTINCT TRIM(cq_zone)) FROM qsos WHERE (lotw_status='CONFIRMED' OR qrz_status='CONFIRMED') AND cq_zone IS NOT NULL AND TRIM(cq_zone) != '';";
        if (sqlite3_prepare_v2(self->_db, sqlWazC, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) wazConfirmed = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 7. POTA Count
        const char *sqlPota = "SELECT COUNT(*) FROM qsos WHERE (their_pota_ref IS NOT NULL AND TRIM(their_pota_ref) != '') OR (my_pota_ref IS NOT NULL AND TRIM(my_pota_ref) != '');";
        if (sqlite3_prepare_v2(self->_db, sqlPota, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) potaCount = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 8. SOTA Count
        const char *sqlSota = "SELECT COUNT(*) FROM qsos WHERE (their_sota_ref IS NOT NULL AND TRIM(their_sota_ref) != '') OR (my_sota_ref IS NOT NULL AND TRIM(my_sota_ref) != '');";
        if (sqlite3_prepare_v2(self->_db, sqlSota, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) sotaCount = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }

        // 9. IOTA Count
        const char *sqlIota = "SELECT COUNT(*) FROM qsos WHERE iota_ref IS NOT NULL AND TRIM(iota_ref) != '';";
        if (sqlite3_prepare_v2(self->_db, sqlIota, -1, &stmt, NULL) == SQLITE_OK) {
            if (sqlite3_step(stmt) == SQLITE_ROW) iotaCount = sqlite3_column_int(stmt, 0);
            sqlite3_finalize(stmt);
        }
    });

    return @{
        @"dxccWorked": @(dxccWorked),
        @"dxccConfirmed": @(dxccConfirmed),
        @"wasWorked": @(wasWorked),
        @"wasConfirmed": @(wasConfirmed),
        @"wazWorked": @(wazWorked),
        @"wazConfirmed": @(wazConfirmed),
        @"potaCount": @(potaCount),
        @"sotaCount": @(sotaCount),
        @"iotaCount": @(iotaCount),
        @"dxcc_worked": @(dxccWorked),
        @"dxcc_confirmed": @(dxccConfirmed),
        @"was_worked": @(wasWorked),
        @"was_confirmed": @(wasConfirmed),
        @"waz_worked": @(wazWorked),
        @"waz_confirmed": @(wazConfirmed),
        @"pota_qsos": @(potaCount),
        @"sota_qsos": @(sotaCount),
        @"iota_qsos": @(iotaCount)
    };
}

#pragma mark - Maidenhead Calculations & Great Circle Utilities

+ (BOOL)coordinatesForGrid:(NSString *)grid latitude:(double *)outLat longitude:(double *)outLon {
    if (!grid || grid.length < 4) return NO;
    NSString *clean = [[grid uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length < 4) return NO;

    unichar c0 = [clean characterAtIndex:0];
    unichar c1 = [clean characterAtIndex:1];
    unichar c2 = [clean characterAtIndex:2];
    unichar c3 = [clean characterAtIndex:3];

    if (c0 < 'A' || c0 > 'R' || c1 < 'A' || c1 > 'R') return NO;
    if (c2 < '0' || c2 > '9' || c3 < '0' || c3 > '9') return NO;

    double lon = -180.0 + (c0 - 'A') * 20.0 + (c2 - '0') * 2.0;
    double lat = -90.0 + (c1 - 'A') * 10.0 + (c3 - '0') * 1.0;

    if (clean.length >= 6) {
        unichar c4 = [clean characterAtIndex:4];
        unichar c5 = [clean characterAtIndex:5];
        if (c4 >= 'A' && c4 <= 'X' && c5 >= 'A' && c5 <= 'X') {
            lon += (c4 - 'A' + 0.5) * (5.0 / 60.0);
            lat += (c5 - 'A' + 0.5) * (2.5 / 60.0);
        } else {
            lon += 1.0;
            lat += 0.5;
        }
    } else {
        lon += 1.0;
        lat += 0.5;
    }

    if (outLat) *outLat = lat;
    if (outLon) *outLon = lon;
    return YES;
}

+ (double)distanceKmFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid {
    double lat1 = 0, lon1 = 0, lat2 = 0, lon2 = 0;
    if (![self coordinatesForGrid:fromGrid latitude:&lat1 longitude:&lon1]) return 0.0;
    if (![self coordinatesForGrid:toGrid latitude:&lat2 longitude:&lon2]) return 0.0;

    double rLat1 = lat1 * M_PI / 180.0;
    double rLon1 = lon1 * M_PI / 180.0;
    double rLat2 = lat2 * M_PI / 180.0;
    double rLon2 = lon2 * M_PI / 180.0;

    double dLat = rLat2 - rLat1;
    double dLon = rLon2 - rLon1;

    double a = sin(dLat / 2.0) * sin(dLat / 2.0) +
               cos(rLat1) * cos(rLat2) * sin(dLon / 2.0) * sin(dLon / 2.0);
    double c = 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
    double d = 6371.0 * c;
    return d;
}

+ (double)bearingDegreesFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid {
    double lat1 = 0, lon1 = 0, lat2 = 0, lon2 = 0;
    if (![self coordinatesForGrid:fromGrid latitude:&lat1 longitude:&lon1]) return 0.0;
    if (![self coordinatesForGrid:toGrid latitude:&lat2 longitude:&lon2]) return 0.0;

    double rLat1 = lat1 * M_PI / 180.0;
    double rLon1 = lon1 * M_PI / 180.0;
    double rLat2 = lat2 * M_PI / 180.0;
    double rLon2 = lon2 * M_PI / 180.0;

    double dLon = rLon2 - rLon1;
    double y = sin(dLon) * cos(rLat2);
    double x = cos(rLat1) * sin(rLat2) - sin(rLat1) * cos(rLat2) * cos(dLon);
    double b = atan2(y, x) * 180.0 / M_PI;
    double bearing = fmod(b + 360.0, 360.0);
    return bearing;
}

+ (NSString *)compassCardinalForDegrees:(double)degrees {
    double d = fmod(degrees, 360.0);
    if (d < 0) d += 360.0;
    static NSString * const cardinals[] = {
        @"N", @"NNE", @"NE", @"ENE",
        @"E", @"ESE", @"SE", @"SSE",
        @"S", @"SSW", @"SW", @"WSW",
        @"W", @"WNW", @"NW", @"NNW"
    };
    int idx = (int)floor((d + 11.25) / 22.5) % 16;
    return cardinals[idx];
}

+ (NSString *)formattedBearingAndDistanceFromGrid:(NSString *)fromGrid toGrid:(NSString *)toGrid {
    if (!fromGrid || fromGrid.length < 4 || !toGrid || toGrid.length < 4) return @"--";
    double km = [self distanceKmFromGrid:fromGrid toGrid:toGrid];
    if (km <= 0.1) return @"Local QTH";
    double miles = km * 0.621371;
    double bearing = [self bearingDegreesFromGrid:fromGrid toGrid:toGrid];
    NSString *card = [self compassCardinalForDegrees:bearing];
    return [NSString stringWithFormat:@"%03.0f° (%@) • %ld km (%ld mi)", bearing, card, (long)round(km), (long)round(miles)];
}

- (BOOL)updateCloudStatusForUUID:(NSString *)uuid
                         service:(NSString *)service
                          status:(NSString *)status
                           error:(NSError **)error {
    if (!uuid || !service || !status) return NO;
    __block BOOL ok = YES;
    __block NSError *localErr = nil;

    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        NSString *col = nil;
        NSString *sLower = [service lowercaseString];
        if ([sLower containsString:@"qrz"]) col = @"qrz_status";
        else if ([sLower containsString:@"lotw"]) col = @"lotw_status";
        else if ([sLower containsString:@"clublog"] || [sLower containsString:@"club"]) col = @"clublog_status";
        else if ([sLower containsString:@"eqsl"]) col = @"eqsl_status";
        else {
            ok = NO;
            return;
        }

        NSString *sql = [NSString stringWithFormat:@"UPDATE qsos SET %@ = ?1, updated_at = ?2 WHERE uuid = ?3;", col];
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(self->_db, [sql UTF8String], -1, &stmt, NULL) == SQLITE_OK) {
            sqlite3_bind_text(stmt, 1, [status UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_double(stmt, 2, [[NSDate date] timeIntervalSince1970]);
            sqlite3_bind_text(stmt, 3, [uuid UTF8String], -1, SQLITE_TRANSIENT);
            if (sqlite3_step(stmt) != SQLITE_DONE) {
                localErr = [NSError errorWithDomain:@"TX500LogbookErrorDomain"
                                               code:6
                                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:sqlite3_errmsg(self->_db)]}];
                ok = NO;
            }
            sqlite3_finalize(stmt);
        }
    });

    if (ok) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:TX500LogbookDidChangeNotification object:self];
        });
    } else if (error && localErr) {
        *error = localErr;
    }
    return ok;
}

#pragma mark - Subsystem Adapters

- (BOOL)addContactFromFT8:(TX500FT8LoggedQSO *)ft8QSO myCall:(nullable NSString *)myCall myGrid:(nullable NSString *)myGrid {
    if (!ft8QSO) return NO;
    TX500LogRecord *rec = [[TX500LogRecord alloc] init];
    rec.callsign = [ft8QSO.callsign uppercaseString];
    rec.band = [ft8QSO.band lowercaseString];
    rec.frequencyHz = ft8QSO.freqHz;
    rec.rstSent = ft8QSO.rstSent ?: @"-10";
    rec.rstRcvd = ft8QSO.rstRcvd ?: @"-10";
    rec.grid = ft8QSO.grid ? [ft8QSO.grid uppercaseString] : nil;
    rec.country = ft8QSO.countryName;
    rec.mode = ft8QSO.mode ?: @"FT8";
    if ([rec.mode isEqualToString:@"FT4"]) rec.submode = @"FT4";
    rec.myCall = myCall ?: @"EP2AES";
    rec.myGrid = myGrid;

    NSDate *d = ft8QSO.timestamp ?: [NSDate date];
    NSDateFormatter *dfDate = [[NSDateFormatter alloc] init];
    dfDate.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dfDate.dateFormat = @"yyyyMMdd";
    rec.qsoDate = [dfDate stringFromDate:d];

    NSDateFormatter *dfTime = [[NSDateFormatter alloc] init];
    dfTime.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    dfTime.dateFormat = @"HHmmss";
    rec.timeOn = [dfTime stringFromDate:d];
    rec.timeOff = rec.timeOn;

    return [self saveContact:rec error:nil];
}

- (BOOL)addContactFromCW:(TX500QSOContact *)cwContact myCall:(nullable NSString *)myCall myGrid:(nullable NSString *)myGrid {
    if (!cwContact) return NO;
    TX500LogRecord *rec = [[TX500LogRecord alloc] init];
    rec.callsign = [cwContact.callsign uppercaseString];
    rec.band = [cwContact.band lowercaseString];
    rec.frequencyHz = (uint64_t)(cwContact.frequencyMHz * 1e6);
    rec.mode = @"CW";
    rec.rstSent = cwContact.rstSent ?: @"599";
    rec.rstRcvd = cwContact.rstRcvd ?: @"599";
    rec.name = cwContact.name;
    rec.qth = cwContact.qth;
    rec.notes = cwContact.notes;
    rec.myCall = myCall ?: @"EP2AES";
    rec.myGrid = myGrid;

    if (cwContact.qsoDate.length == 8) rec.qsoDate = cwContact.qsoDate;
    if (cwContact.timeOn.length >= 4) rec.timeOn = cwContact.timeOn;
    rec.timeOff = rec.timeOn;

    return [self saveContact:rec error:nil];
}

#pragma mark - ADIF Export & Import

- (NSString *)exportFullADIFStringWithProgramId:(NSString *)programId {
    NSArray<TX500LogRecord *> *contacts = [self allContacts];
    NSMutableString *outStr = [NSMutableString string];
    [outStr appendFormat:@"Lab599 Discovery TX-500 ADIF Export\n<ADIF_VER:5>3.1.4 <PROGRAMID:%lu>%@ <EOH>\n\n",
     (unsigned long)programId.length, programId];

    for (TX500LogRecord *c in contacts) {
        [outStr appendString:[c adifRecordString]];
    }
    return outStr;
}

- (BOOL)exportADIFToFileURL:(NSURL *)fileURL error:(NSError **)error {
    NSString *fullADIF = [self exportFullADIFStringWithProgramId:@"Lab599 Utility"];
    return [fullADIF writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:error];
}

- (NSInteger)importADIFFromFileURL:(NSURL *)fileURL
                   duplicatesCount:(NSInteger * _Nullable)outDuplicates
                             error:(NSError **)error {
    NSString *content = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:error];
    if (!content) {
        content = [NSString stringWithContentsOfURL:fileURL encoding:NSISOLatin1StringEncoding error:error];
    }
    if (!content) return 0;

    // Split records by <eor> / <EOR>
    NSArray *rawRecords = [content componentsSeparatedByString:@"<EOR>"];
    if (rawRecords.count <= 1) {
        rawRecords = [content componentsSeparatedByString:@"<eor>"];
    }

    // Load existing for deduplication
    NSArray<TX500LogRecord *> *existing = [self allContacts];
    NSMutableSet<NSString *> *existingKeys = [NSMutableSet set];
    for (TX500LogRecord *r in existing) {
        NSString *shortTime = r.timeOn.length >= 4 ? [r.timeOn substringToIndex:4] : @"";
        NSString *k = [NSString stringWithFormat:@"%@_%@_%@_%@_%@",
                       [r.callsign uppercaseString], r.qsoDate, shortTime, [r.band lowercaseString], [r.mode uppercaseString]];
        [existingKeys addObject:k];
    }

    NSInteger imported = 0;
    NSInteger duplicates = 0;

    for (NSString *chunk in rawRecords) {
        if (![chunk localizedCaseInsensitiveContainsString:@"<CALL"]) continue;
        TX500LogRecord *rec = [TX500LogRecord recordFromADIFRecordText:chunk];
        if (!rec) continue;

        NSString *shortTime = rec.timeOn.length >= 4 ? [rec.timeOn substringToIndex:4] : @"";
        NSString *k = [NSString stringWithFormat:@"%@_%@_%@_%@_%@",
                       [rec.callsign uppercaseString], rec.qsoDate, shortTime, [rec.band lowercaseString], [rec.mode uppercaseString]];
        if ([existingKeys containsObject:k]) {
            duplicates++;
            continue;
        }

        if ([self saveContact:rec error:nil]) {
            [existingKeys addObject:k];
            imported++;
        }
    }

    if (outDuplicates) *outDuplicates = duplicates;
    return imported;
}

- (void)clearAllContactsForTesting {
    dispatch_sync(self.dbQueue, ^{
        if (!self->_db) return;
        sqlite3_exec(self->_db, "DELETE FROM qsos; DELETE FROM cloud_outbox;", NULL, NULL, NULL);
    });
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TX500LogbookDidChangeNotification object:self];
    });
}

@end
