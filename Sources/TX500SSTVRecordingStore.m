// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500SSTVRecordingStore.h"

@interface TX500SSTVStoredReception ()
@property (nonatomic, readwrite, copy) NSString *identifier, *modeKey;
@property (nonatomic, readwrite, copy) NSDate *startUTC, *endUTC;
@property (nonatomic, readwrite) BOOL fromFile, keep;
@property (nonatomic, readwrite) NSUInteger byteSize;
@property (nonatomic, strong, nullable) TX500SSTVRecording *memory;
@property (nonatomic, copy, nullable) NSURL *file;
@property (nonatomic, readwrite, copy) NSArray<NSString *> *pictureNames;
@property (nonatomic, readwrite, copy) NSString *modeName;
@property (nonatomic, readwrite, copy) NSArray<NSArray<NSNumber *> *> *timeAnchors;
@property (nonatomic, readwrite) uint64_t catFrequencyHz;
@property (nonatomic, readwrite) BOOL offered, logged;
@property (nonatomic, readwrite) unsigned long long pictureBytes;
@property (nonatomic) BOOL listedAgain;      // found in the folder without its list, at this start: not removed now
@end

@implementation TX500SSTVStoredReception
// a regular file, never a folder (DEC-9)
- (BOOL)onDisk {
    BOOL dir = NO;
    return self.file != nil && [NSFileManager.defaultManager fileExistsAtPath:self.file.path isDirectory:&dir] && !dir;
}
- (BOOL)inMemory { return self.memory != nil; }
- (NSArray<NSString *> *)pictureNames { return _pictureNames ?: @[]; }
- (NSString *)modeName { return _modeName ?: @""; }
- (NSArray<NSArray<NSNumber *> *> *)timeAnchors { return _timeAnchors ?: @[]; }
@end

// index.json: {"version": 1, "items": [...]}; the first form, a plain list, is read too
static const NSInteger SSTVIndexVersion = 1;

static NSString *SSTVString(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }
static NSNumber *SSTVNumber(id v) { return [v isKindOfClass:NSNumber.class] ? v : nil; }
static BOOL SSTVIsUUID(NSString *s) { return s.length == 36 && [[NSUUID alloc] initWithUUIDString:s] != nil; }

@implementation TX500SSTVRecordingStore {
    NSMutableArray<TX500SSTVStoredReception *> *_list;   // newest first
    BOOL _loading;
    NSMutableArray<NSString *> *_unsaid;                  // problems found before anyone listened (loading)
    NSUInteger _unsaidRemoved;                            // removed before anyone listened (the first trim)
    unsigned long long _unsaidFreed;
    BOOL _saidLimited, _saidKeptFull, _saidNoRoom;
    NSUInteger _saidFailed;                               // old files that could not be removed, as last said
}

static unsigned long long (^SSTVVolumeBytesProvider)(void);
+ (nullable unsigned long long (^)(void))volumeBytesProvider { return SSTVVolumeBytesProvider; }
+ (void)setVolumeBytesProvider:(nullable unsigned long long (^)(void))provider { SSTVVolumeBytesProvider = [provider copy]; }

- (instancetype)initWithDirectory:(NSURL *)directory {
    return [self initWithDirectory:directory pictureDirectory:nil];
}

// the existing folder nearest to u (the volume's values are read there)
static NSURL *SSTVExisting(NSURL *u) {
    while (u.path.length > 1 && ![NSFileManager.defaultManager fileExistsAtPath:u.path]) u = u.URLByDeletingLastPathComponent;
    return u;
}

- (instancetype)initWithDirectory:(NSURL *)directory pictureDirectory:(nullable NSURL *)pictures {
    return [self initWithDirectory:directory pictureDirectory:pictures diskShare:0.01];   // 1 % of the disk
}

// The share is known before anything is trimmed: the first trim, at the start, uses the operator's
// own share, never the default (N-memoria-disc-1)
- (instancetype)initWithDirectory:(NSURL *)directory pictureDirectory:(nullable NSURL *)pictures diskShare:(double)share {
    if ((self = [super init])) {
        _directory = [directory copy];
        _pictureDirectory = [pictures copy];
        _memoryCount = 3;
        if (SSTVVolumeBytesProvider) _volumeBytes = SSTVVolumeBytesProvider();
        else {
            NSNumber *total = nil;
            [SSTVExisting(directory) getResourceValue:&total forKey:NSURLVolumeTotalCapacityKey error:nil];
            _volumeBytes = total.unsignedLongLongValue;
        }
        _diskShare = share > 0 ? share : 0;
        _diskCapBytes = [self capForShare:_diskShare];
        _minimumFreeBytes = 200ULL * 1000ULL * 1000ULL;
        _list = [NSMutableArray array];
        _loading = YES;
        [self loadIndex];
        _loading = NO;
        [self trim];                                            // a cap lowered since last time applies now (DEC-14)
    }
    return self;
}

// a share of the disk in bytes (1 GB for each 1 % when the disk's size is not known)
- (unsigned long long)capForShare:(double)share {
    if (share <= 0) return 0;
    return _volumeBytes ? (unsigned long long)(share * _volumeBytes) : (unsigned long long)(share / 0.01 * 1e9);
}

- (NSArray<TX500SSTVStoredReception *> *)receptions { return [_list copy]; }

- (NSURL *)indexURL { return [self.directory URLByAppendingPathComponent:@"index.json"]; }

// a reception's audio is always <identifier>.wav in this folder: never a path read from the index
- (NSURL *)wavURLFor:(NSString *)identifier { return [self.directory URLByAppendingPathComponent:[identifier stringByAppendingString:@".wav"]]; }

- (void)problem:(NSString *)text {
    if (self.onProblem) { self.onProblem(text); return; }
    if (!_unsaid) _unsaid = [NSMutableArray array];
    [_unsaid addObject:text];
}

// what was found while loading is said as soon as someone listens
- (void)setOnProblem:(void (^)(NSString *))onProblem {
    _onProblem = [onProblem copy];
    NSArray *pending = _unsaid;
    _unsaid = nil;
    if (_onProblem) for (NSString *t in pending) _onProblem(t);
}

- (void)setDiskCapBytes:(unsigned long long)cap { _diskCapBytes = cap; [self trim]; }
- (void)setDiskShare:(double)share {
    _diskShare = share > 0 ? share : 0;
    _diskCapBytes = [self capForShare:_diskShare];
    [self trim];
}

// what the first trim removed is said as soon as someone listens
- (void)setOnRemoved:(void (^)(NSUInteger, unsigned long long))onRemoved {
    _onRemoved = [onRemoved copy];
    NSUInteger n = _unsaidRemoved;
    unsigned long long b = _unsaidFreed;
    _unsaidRemoved = 0; _unsaidFreed = 0;
    if (_onRemoved && n) _onRemoved(n, b);
}

- (unsigned long long)freeBytes {
    if (self.freeBytesProvider) return self.freeBytesProvider();
    NSNumber *free = nil;
    if (![SSTVExisting(self.directory) getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil] || !free)
        return ULLONG_MAX / 4;                                  // not known: the share alone applies
    return free.unsignedLongLongValue;
}

// never more than a tenth of the room there is for it: what is free plus what it already uses
- (unsigned long long)effectiveCapBytes {
    unsigned long long cap = self.diskCapBytes;
    if (!cap) return 0;
    unsigned long long room = self.freeBytes, used = self.diskBytesUsed;
    room = room > ULLONG_MAX - used ? ULLONG_MAX : room + used;
    unsigned long long guard = room / 10;
    return guard < cap ? guard : cap;
}

- (BOOL)limitedByFreeSpace { return self.diskCapBytes > 0 && self.effectiveCapBytes < self.diskCapBytes; }

// a picture's PNG, only a plain name in the pictures folder
- (nullable NSURL *)pictureURL:(NSString *)name {
    if (!self.pictureDirectory || !name.length || [name containsString:@"/"] || [name hasPrefix:@"."] ||
        ![name.pathExtension.lowercaseString isEqualToString:@"png"]) return nil;
    return [self.pictureDirectory URLByAppendingPathComponent:name];
}

- (unsigned long long)bytesOfPictures:(TX500SSTVStoredReception *)r {
    unsigned long long n = 0;
    for (NSString *name in r.pictureNames) {
        NSURL *u = [self pictureURL:name];
        if (u) n += [[NSFileManager.defaultManager attributesOfItemAtPath:u.path error:nil][NSFileSize] unsignedLongLongValue];
    }
    return n;
}
- (void)setMemoryCount:(NSUInteger)count { _memoryCount = count; [self trim]; }

// The disk copies survive the app: a small index of what is there and what is kept. Every value is
// checked; an index that cannot be read, or is from a newer version, is set aside (never written
// over) and the recordings in the folder are listed again (DEC-8, DEC-9, SEG-16).
- (void)loadIndex {
    NSData *d = [NSData dataWithContentsOfURL:[self indexURL]];
    if (d) {
        id root = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        NSArray *items = nil;
        if ([root isKindOfClass:NSArray.class]) items = root;
        else if ([root isKindOfClass:NSDictionary.class] && SSTVNumber(root[@"version"]) &&
                 SSTVNumber(root[@"version"]).integerValue <= SSTVIndexVersion && [root[@"items"] isKindOfClass:NSArray.class])
            items = root[@"items"];
        if (items) {
            for (id it in items) [self readItem:it];
        } else {
            NSString *name = [NSString stringWithFormat:@"index-%ld.json.bad", (long)[NSDate date].timeIntervalSince1970];
            [NSFileManager.defaultManager moveItemAtURL:[self indexURL] toURL:[self.directory URLByAppendingPathComponent:name] error:nil];
            [self problem:[NSString stringWithFormat:@"The list of recordings could not be read (kept aside as %@); "
                                                      "the recordings in the folder are listed again.", name]];
        }
    }
    [self adoptOrphans];
}

- (void)readItem:(id)it {
    if (![it isKindOfClass:NSDictionary.class]) return;
    NSString *ident = SSTVString(it[@"id"]);
    if (!SSTVIsUUID(ident)) return;
    for (TX500SSTVStoredReception *x in _list) if ([x.identifier isEqualToString:ident]) return;
    TX500SSTVStoredReception *r = [TX500SSTVStoredReception new];
    r.identifier = ident;
    r.file = [self wavURLFor:ident];
    r.modeKey = SSTVString(it[@"mode"]) ?: @"";
    r.endUTC = [NSDate dateWithTimeIntervalSince1970:SSTVNumber(it[@"end"]).doubleValue];
    r.startUTC = SSTVNumber(it[@"start"]) ? [NSDate dateWithTimeIntervalSince1970:SSTVNumber(it[@"start"]).doubleValue] : r.endUTC;
    NSMutableArray *anc = [NSMutableArray array];
    if ([it[@"anchors"] isKindOfClass:NSArray.class])
        for (id a in it[@"anchors"])
            if ([a isKindOfClass:NSArray.class] && [a count] == 2 && SSTVNumber(a[0]) && SSTVNumber(a[1])) [anc addObject:a];
    r.timeAnchors = anc;
    r.fromFile = SSTVNumber(it[@"fromFile"]).boolValue;
    r.keep = SSTVNumber(it[@"keep"]).boolValue;
    // the size is the file's, not what the index says
    NSNumber *size = [NSFileManager.defaultManager attributesOfItemAtPath:r.file.path error:nil][NSFileSize];
    r.byteSize = size.unsignedIntegerValue > 44 ? size.unsignedIntegerValue - 44 : 0;
    NSMutableArray *pics = [NSMutableArray array];
    if ([it[@"pictures"] isKindOfClass:NSArray.class]) for (id p in it[@"pictures"]) if (SSTVString(p).length) [pics addObject:p];
    r.pictureNames = pics;
    r.pictureBytes = [self bytesOfPictures:r];
    if (!r.onDisk && !r.pictureBytes) return;                   // nothing of it is left on disk
    if (!r.onDisk) r.file = nil;
    r.modeName = SSTVString(it[@"modeName"]) ?: @"";
    r.catFrequencyHz = SSTVNumber(it[@"cat"]).unsignedLongLongValue;
    r.offered = SSTVNumber(it[@"offered"]).boolValue;
    r.logged = SSTVNumber(it[@"logged"]).boolValue;
    [_list addObject:r];
}

// Recordings in the folder that the index does not list (it was lost or set aside): listed again,
// so they count within the cap. What they were is not known: they are practice, never logged, and
// not kept (DEC-8).
- (void)adoptOrphans {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSURL *> *all = [fm contentsOfDirectoryAtURL:self.directory includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                 options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSUInteger n = 0;
    for (NSURL *u in all) {
        if (![u.pathExtension isEqualToString:@"wav"]) continue;
        NSString *ident = u.lastPathComponent.stringByDeletingPathExtension;
        if (!SSTVIsUUID(ident)) continue;
        BOOL listed = NO;
        for (TX500SSTVStoredReception *x in _list) if ([x.identifier isEqualToString:ident]) listed = YES;
        if (listed) continue;
        TX500SSTVStoredReception *r = [TX500SSTVStoredReception new];
        r.identifier = ident;
        r.file = [self wavURLFor:ident];
        if (!r.onDisk) continue;
        NSDate *mod = nil;
        [u getResourceValue:&mod forKey:NSURLContentModificationDateKey error:nil];
        NSNumber *size = [fm attributesOfItemAtPath:u.path error:nil][NSFileSize];
        r.byteSize = size.unsignedIntegerValue > 44 ? size.unsignedIntegerValue - 44 : 0;
        r.endUTC = mod ?: [NSDate date];
        r.startUTC = r.endUTC;
        r.modeKey = @""; r.modeName = @"";
        r.fromFile = YES;
        r.listedAgain = YES;
        [_list addObject:r];
        n++;
    }
    if (n) {
        [_list sortUsingComparator:^NSComparisonResult(TX500SSTVStoredReception *a, TX500SSTVStoredReception *b) {
            return [b.endUTC compare:a.endUTC];
        }];
        // what they were is not known (some may have been kept): none is removed on this start (N-memoria-disc-6)
        [self problem:[NSString stringWithFormat:@"%lu recording%@ in the folder had no entry in the list: listed again, as practice. "
                       "None is removed while the app runs now: mark Keep on those you want to keep.",
                       (unsigned long)n, n == 1 ? @"" : @"s"]];
    }
}

// Nothing is written with the disk Off: no folder and no list unless there is a recording to list (DEC-6).
- (void)saveIndex {
    if (_loading) return;
    NSMutableArray *items = [NSMutableArray array];
    for (TX500SSTVStoredReception *r in _list) {
        if (!r.onDisk && !r.pictureBytes) continue;
        [items addObject:@{@"id": r.identifier, @"mode": r.modeKey, @"end": @(r.endUTC.timeIntervalSince1970),
                           @"start": @(r.startUTC.timeIntervalSince1970), @"anchors": r.timeAnchors,
                           @"fromFile": @(r.fromFile), @"keep": @(r.keep), @"bytes": @(r.byteSize),
                           @"pictures": r.pictureNames, @"modeName": r.modeName,
                           @"cat": @(r.catFrequencyHz), @"offered": @(r.offered), @"logged": @(r.logged)}];
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!items.count && ![fm fileExistsAtPath:[self indexURL].path]) return;
    [fm createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *d = [NSJSONSerialization dataWithJSONObject:@{@"version": @(SSTVIndexVersion), @"items": items}
                                                options:NSJSONWritingPrettyPrinted error:nil];
    NSError *err = nil;
    if (![d writeToURL:[self indexURL] options:NSDataWritingAtomic error:&err])
        [self problem:[NSString stringWithFormat:@"The list of recordings could not be saved: %@", err.localizedDescription ?: @"unknown error"]];
}

// the audio and the pictures on disk
- (unsigned long long)diskBytesUsed {
    unsigned long long n = 0;
    for (TX500SSTVStoredReception *r in _list) n += (r.onDisk ? r.byteSize + 44 : 0) + r.pictureBytes;
    return n;
}

- (unsigned long long)keptBytes {
    unsigned long long n = 0;
    for (TX500SSTVStoredReception *r in _list) if (r.keep) n += (r.onDisk ? r.byteSize + 44 : 0) + r.pictureBytes;
    return n;
}

- (NSUInteger)keptCount {
    NSUInteger n = 0;
    for (TX500SSTVStoredReception *r in _list) if (r.keep && (r.onDisk || r.pictureBytes)) n++;
    return n;
}

// the free space must hold the copy and a margin; when it cannot be read, the write itself says
- (BOOL)roomFor:(unsigned long long)bytes {
    NSURL *u = self.directory;
    while (u.path.length > 1 && ![NSFileManager.defaultManager fileExistsAtPath:u.path]) u = u.URLByDeletingLastPathComponent;
    NSNumber *free = nil;
    if (![u getResourceValue:&free forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil] || !free) return YES;
    return free.unsignedLongLongValue >= bytes + self.minimumFreeBytes;
}

// a copy on disk, or the reason there is none (DEC-7)
- (BOOL)writeReception:(TX500SSTVStoredReception *)r error:(NSError **)error {
    NSString *why = nil;
    if (!r.memory) why = @"its audio is no longer kept";
    else if (![self roomFor:r.byteSize + 44]) why = @"there is not enough free disk space";
    else {
        NSError *e = nil;
        [NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:&e];
        NSURL *u = [self wavURLFor:r.identifier];
        if ([r.memory writeWAVToURL:u error:&e]) { r.file = u; return YES; }
        why = e.localizedDescription ?: @"the copy could not be written";
    }
    NSString *text = [NSString stringWithFormat:@"The recording could not be kept on disk: %@.", why];
    [self problem:text];
    if (error) *error = [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:30 userInfo:@{NSLocalizedDescriptionKey: text}];
    return NO;
}

- (TX500SSTVStoredReception *)addRecording:(TX500SSTVRecording *)recording {
    return [self addRecording:recording catFrequencyHz:0];
}

- (TX500SSTVStoredReception *)addRecording:(TX500SSTVRecording *)recording catFrequencyHz:(uint64_t)hz {
    TX500SSTVStoredReception *r = [TX500SSTVStoredReception new];
    r.catFrequencyHz = recording.fromFile ? 0 : hz;
    r.identifier = [NSUUID UUID].UUIDString;
    r.modeKey = recording.modeKey ?: @"";
    r.endUTC = recording.endUTC ?: [NSDate date];
    r.startUTC = recording.startUTC;
    r.timeAnchors = recording.timeAnchors;
    r.fromFile = recording.fromFile;
    r.keep = NO;                                 // Keep belongs to the stored reception, not to the audio
    r.byteSize = recording.byteSize;
    r.memory = recording;
    [_list insertObject:r atIndex:0];
    // practice (a WAV the operator already has) never goes to disk: memory only (SEG-3, DEC-5); nor a
    // recording the share would remove at once (N3-importants-nous-4)
    if (!r.fromFile && self.effectiveCapBytes > 0 && [self newFileFits:r.byteSize + 44 audio:YES]) [self writeReception:r error:nil];
    [self trim];
    return r;
}

- (nullable TX500SSTVStoredReception *)receptionFromRadioEndingAt:(nullable NSDate *)end byteSize:(NSUInteger)bytes {
    if (!end || !bytes) return nil;
    for (TX500SSTVStoredReception *r in _list)
        if (!r.fromFile && r.byteSize == bytes && r.endUTC && fabs([r.endUTC timeIntervalSinceDate:end]) < 0.001) return r;
    return nil;
}

- (nullable TX500SSTVStoredReception *)keepCopyOfRecording:(TX500SSTVRecording *)recording catFrequencyHz:(uint64_t)hz
                                                     error:(NSError **)error {
    // the same minutes again: the copy already made, never a second one (N3-importants-nous-1)
    TX500SSTVStoredReception *same = [self receptionFromRadioEndingAt:recording.endUTC byteSize:recording.byteSize];
    if (same) return (same.keep || [self setKeep:YES forReception:same error:error]) ? same : nil;
    TX500SSTVStoredReception *r = [TX500SSTVStoredReception new];
    r.catFrequencyHz = hz;
    r.identifier = [NSUUID UUID].UUIDString;
    r.modeKey = @"";
    r.endUTC = recording.endUTC ?: [NSDate date];
    r.startUTC = recording.startUTC;
    r.timeAnchors = recording.timeAnchors;
    r.byteSize = recording.byteSize;
    r.memory = recording;
    if (![self writeReception:r error:error]) return nil;        // no row when it cannot be written
    r.keep = YES;
    r.memory = nil;                                              // read back from disk: no place in memory
    [_list insertObject:r atIndex:0];
    [self trim];
    return r;
}

// what the share never removes now: the kept receptions, and those found again in the folder at this start
- (unsigned long long)pinnedBytes {
    unsigned long long n = 0;
    for (TX500SSTVStoredReception *r in _list)
        if (r.keep || r.logged || r.listedAgain) n += (r.onDisk ? r.byteSize + 44 : 0) + r.pictureBytes;
    return n;
}

- (BOOL)newPictureFitsShare:(unsigned long long)bytes { return [self newFileFits:bytes audio:NO]; }

// The share removes the oldest audio first, then the oldest pictures (DEC-15), never what is kept or
// found again: new audio stays when it fits beside those and every picture, a new picture beside those.
// One the share would remove at once is not written at all, and that is said once (N3-importants-nous-4,
// N3-menors-oberts-3); when the kept ones alone fill the share, trim says it
- (BOOL)newFileFits:(unsigned long long)bytes audio:(BOOL)audio {
    unsigned long long cap = self.effectiveCapBytes;
    if (cap == 0) return NO;
    unsigned long long fixed = self.pinnedBytes;
    if (audio) for (TX500SSTVStoredReception *r in _list) if (!r.keep && !r.logged && !r.listedAgain) fixed += r.pictureBytes;
    BOOL fits = fixed + bytes <= cap;
    if (fits) _saidNoRoom = NO;
    else if (!_saidNoRoom) {
        _saidNoRoom = YES;
        if (self.keptBytes < cap)
            [self problem:@"The disk share is full of what it does not remove now (kept recordings, recordings found again in "
                          "the folder, pictures): new recordings and pictures stay in memory only, until the app quits. "
                          "Choose a bigger share, or untick Keep on some."];
    }
    return fits;
}

- (void)addPictureNamed:(NSString *)name toReception:(TX500SSTVStoredReception *)reception {
    [self addPictureNamed:name modeName:nil toReception:reception];
}

- (void)addPictureNamed:(NSString *)name modeName:(nullable NSString *)modeName toReception:(TX500SSTVStoredReception *)reception {
    if (!name.length) return;
    reception.pictureNames = [reception.pictureNames arrayByAddingObject:name];
    if (modeName.length) reception.modeName = modeName;
    reception.pictureBytes = [self bytesOfPictures:reception];
    [self trim];                                                // its PNG counts within the cap
}

// the operator's own removal: that one name goes, what is left on disk is what counts, and a reception with
// nothing left goes, as trim lets it go
- (BOOL)removePictureNamed:(NSString *)name ofReception:(TX500SSTVStoredReception *)reception {
    if (!name.length) return NO;
    NSMutableArray<NSString *> *names = [reception.pictureNames mutableCopy];
    NSUInteger i = [names indexOfObject:name];
    if (i == NSNotFound) return NO;
    [names removeObjectAtIndex:i];
    reception.pictureNames = names;
    reception.pictureBytes = [self bytesOfPictures:reception];
    BOOL gone = !reception.memory && !reception.onDisk && !reception.pictureBytes;
    if (gone) [_list removeObjectIdenticalTo:reception];
    [self saveIndex];
    return gone;
}

- (nullable NSURL *)latestPictureURLOfReception:(TX500SSTVStoredReception *)reception {
    for (NSString *name in reception.pictureNames.reverseObjectEnumerator) {
        NSURL *u = [self pictureURL:name];
        BOOL dir = NO;
        if (u && [NSFileManager.defaultManager fileExistsAtPath:u.path isDirectory:&dir] && !dir) return u;
    }
    return nil;
}

- (void)markOffered:(TX500SSTVStoredReception *)reception { reception.offered = YES; [self saveIndex]; }
- (void)markLogged:(TX500SSTVStoredReception *)reception { reception.offered = YES; reception.logged = YES; [self saveIndex]; }

- (BOOL)setKeep:(BOOL)keep forReception:(TX500SSTVStoredReception *)reception {
    return [self setKeep:keep forReception:reception error:nil];
}

// Keep is only marked when there is a copy on disk to keep (DEC-7). With the disk Off, Keep still
// writes that one copy: it is the operator's own explicit choice (DEC-17).
- (BOOL)setKeep:(BOOL)keep forReception:(TX500SSTVStoredReception *)reception error:(NSError **)error {
    // practice (a WAV the operator already has) never goes to disk, Keep or not (N-memoria-disc-2);
    // a recording found in the folder without its list is already there, and may be kept
    if (keep && reception.fromFile && !reception.onDisk) {
        NSString *text = @"Practice recordings are never saved on disk: use Export recording… to keep a copy.";
        if (error) *error = [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:31 userInfo:@{NSLocalizedDescriptionKey: text}];
        return NO;
    }
    if (keep && !reception.onDisk && ![self writeReception:reception error:error]) return NO;
    reception.keep = keep;
    reception.memory.keep = keep;
    [self trim];
    return YES;
}

// Memory: the newest memoryCount from the radio, and the newest practice one (practice never takes a
// radio reception's place). Disk: within the cap, the oldest audio goes first, then the oldest
// pictures; never anything of a kept reception; and it says what went (DEC-15). The kept ones count
// within the cap, as the lamp shows them (DEC-16): what is on disk is what is counted,
// and only the others make room.
- (void)trim {
    if (_loading) return;
    NSUInteger inMem = 0, practice = 0;
    for (TX500SSTVStoredReception *r in _list) {
        if (!r.memory) continue;
        if (r.fromFile ? ++practice > 1 : ++inMem > self.memoryCount) r.memory = nil;
    }
    unsigned long long cap = self.effectiveCapBytes, used = 0;
    for (TX500SSTVStoredReception *r in _list) used += (r.onDisk ? r.byteSize + 44 : 0) + r.pictureBytes;
    NSUInteger removed = 0;
    unsigned long long freed = 0;
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger failed = 0;
    for (TX500SSTVStoredReception *r in _list.reverseObjectEnumerator) {
        if (used <= cap) break;
        if (!r.onDisk || r.keep || r.logged || r.listedAgain) continue;
        // only our own <identifier>.wav in this folder (DEC-9, SEG-16); a file that cannot be removed
        // stays counted and listed, and it is said (N-memoria-disc-8)
        NSURL *own = [self wavURLFor:r.identifier];
        if (![r.file.path isEqualToString:own.path]) { r.file = nil; continue; }
        if ([fm removeItemAtURL:own error:nil]) {
            used -= r.byteSize + 44;
            removed++; freed += r.byteSize + 44;                    // the operator's space, the operator's choice
            r.file = nil;
        } else failed++;
    }
    for (TX500SSTVStoredReception *r in _list.reverseObjectEnumerator) {
        if (used <= cap) break;
        if (r.keep || r.logged || r.listedAgain || !r.pictureBytes) continue;
        BOOL all = YES;
        for (NSString *name in r.pictureNames) {
            NSURL *u = [self pictureURL:name];
            unsigned long long b = u ? [[fm attributesOfItemAtPath:u.path error:nil][NSFileSize] unsignedLongLongValue] : 0;
            if (!u || !b) continue;
            if ([fm removeItemAtURL:u error:nil]) { freed += b; used = used > b ? used - b : 0; }
            else all = NO;
        }
        r.pictureBytes = all ? 0 : [self bytesOfPictures:r];     // what is still there still counts (N-memoria-disc-5)
        if (all) removed++; else failed++;
    }
    // said once, and again only when the number changes (N3-importants-nous-3)
    if (failed && failed != _saidFailed)
        [self problem:[NSString stringWithFormat:@"%lu old recording%@ could not be removed to stay within the disk share: "
                       "%@ still counted.", (unsigned long)failed, failed == 1 ? @"" : @"s", failed == 1 ? @"it is" : @"they are"]];
    _saidFailed = failed;
    NSMutableArray *gone = [NSMutableArray array];
    for (TX500SSTVStoredReception *r in _list) if (!r.memory && !r.onDisk && !r.pictureBytes) [gone addObject:r];
    [_list removeObjectsInArray:gone];
    [self saveIndex];
    if (removed && self.onRemoved) self.onRemoved(removed, freed);
    else if (removed) { _unsaidRemoved += removed; _unsaidFreed += freed; }
    BOOL limited = self.limitedByFreeSpace;
    if (limited && !_saidLimited)
        [self problem:[NSString stringWithFormat:@"The recordings are limited to %.1f GB, a tenth of the free space plus what they already use, "
                                                  "so that the disk never fills up.", self.effectiveCapBytes / 1e9]];
    _saidLimited = limited;
    // the kept ones are never removed: when they alone fill the share, new recordings and pictures stay in memory only (DEC-16)
    BOOL keptFull = cap > 0 && self.keptBytes >= cap;
    if (keptFull && !_saidKeptFull)
        [self problem:@"The recordings you keep fill the disk share on their own. They are never removed, so new recordings "
                      "and pictures stay in memory only: untick Keep on some, or choose a bigger share."];
    _saidKeptFull = keptFull;
}

- (nullable TX500SSTVRecording *)recordingForReception:(TX500SSTVStoredReception *)reception {
    return [self recordingForReception:reception error:nil];
}

- (nullable TX500SSTVRecording *)recordingForReception:(TX500SSTVStoredReception *)reception error:(NSError **)error {
    if (reception.memory) return reception.memory;
    if (!reception.onDisk) {
        // the store forgets the file of what it removes itself: a file still named here was taken away by hand
        if (reception.file && error)
            *error = [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:32
                                     userInfo:@{NSLocalizedDescriptionKey: @"Its audio is no longer in the folder."}];
        return nil;
    }
    TX500SSTVRecording *r = [TX500SSTVRecording recordingFromWAVAtURL:reception.file error:error];
    if (!r) return nil;
    r.modeKey = reception.modeKey; r.endUTC = reception.endUTC; r.fromFile = reception.fromFile; r.keep = reception.keep;
    r.timeAnchors = reception.timeAnchors;
    r.fileURL = reception.file;
    return r;
}

+ (NSArray<TX500SSTVPicture *> *)decodeAgain:(TX500SSTVRecording *)recording mode:(TX500SSTVModeChoice)mode
                                colourScale:(TX500SSTVColourScale)scale scottieLayout:(TX500SSTVScottieLayout)layout
                                   fitSlant:(BOOL)fitSlant slantPPM:(double)ppm {
    TX500SSTVEngine *e = [TX500SSTVEngine new];
    e.callbackQueue = nil;
    e.modeChoice = mode; e.colourScale = scale; e.scottieLayout = layout;
    e.fitSlant = fitSlant; e.slantPPM = ppm;
    e.ringSeconds = MAX(1.0, recording.duration + 1.0);
    NSMutableArray<TX500SSTVPicture *> *out = [NSMutableArray array];
    e.onPicture = ^(TX500SSTVPicture *p) { [out addObject:p]; };
    [e startWithSource:[[TX500SSTVRecordingSource alloc] initWithRecording:recording] error:nil];
    return out;
}
@end
