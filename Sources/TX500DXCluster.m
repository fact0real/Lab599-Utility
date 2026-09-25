#import "TX500DXCluster.h"
#import "TX500FT8Message.h"
#import "TX500LogbookManager.h"
#import <Network/Network.h>
#import <arpa/inet.h>
#import <math.h>
static BOOL DXMatch(NSString *s,NSString *pattern) { return [s rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound; }
static BOOL DXCall(NSString *s) { return s.length>=3 && s.length<=32 && DXMatch(s,@"^[A-Z0-9]+(/[A-Z0-9]+)*$") && DXMatch(s,@"[A-Z]") && DXMatch(s,@"[0-9]"); }
@implementation TX500DXSpot
+ (instancetype)parseLine:(NSString *)line receivedAt:(NSDate *)date {
    if(line.length>1024) return nil;
    static NSRegularExpression *regex; static dispatch_once_t once; dispatch_once(&once, ^{ regex=[NSRegularExpression regularExpressionWithPattern:@"^DX de ([A-Za-z0-9/#-]{3,40}):\\s+([0-9]+(?:\\.[0-9]{1,3})?)\\s+([A-Za-z0-9/]{3,32})\\s+(.*?)\\s*([0-9]{4})Z(?:\\s+.*)?$" options:0 error:nil]; });
    NSTextCheckingResult *m=[regex firstMatchInString:line options:0 range:NSMakeRange(0,line.length)]; if(!m) return nil;
    NSString *(^part)(NSUInteger)=^NSString *(NSUInteger i){ return [line substringWithRange:[m rangeAtIndex:i]]; };
    NSString *call=part(3).uppercaseString,*time=part(5); double khz=part(2).doubleValue;
    NSInteger hour=[[time substringToIndex:2] integerValue],minute=[[time substringFromIndex:2] integerValue];
    if(!DXCall(call) || !isfinite(khz) || khz<100 || khz>1300000 || hour>23 || minute>59) return nil;
    NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian]; calendar.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
    NSDate *day=[calendar startOfDayForDate:date]; NSDate *reported=[day dateByAddingTimeInterval:hour*3600+minute*60];
    if([reported timeIntervalSinceDate:date]>300) reported=[reported dateByAddingTimeInterval:-86400];
    TX500DXSpot *s=[self new]; s.callsign=call; s.spotter=part(1).uppercaseString; s.comment=[part(4) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; s.frequencyHz=(uint64_t)llround(khz*1000); s.reportedAt=reported; s.receivedAt=date;
    s.modeHint=@"Unknown"; NSString *upper=s.comment.uppercaseString;
    for(NSString *mode in @[@"FT8",@"FT4",@"RTTY",@"PSK31",@"USB",@"LSB",@"SSB",@"CW",@"FM",@"AM"]) if(DXMatch(upper,[NSString stringWithFormat:@"(?<![A-Z0-9])%@(?![A-Z0-9])",mode])) { s.modeHint=mode; break; }
    s.band=[TX500LogRecord bandForFrequencyHz:s.frequencyHz]; s.country=[TX500FT8Message countryNameForCallsign:call] ?: @"Unknown";
    s.countryFlag=[TX500FT8Message countryFlagForCallsign:call] ?: @"🌐";
    if([s.country isEqual:@"International"]) s.country=@"Unknown";
    s.identifier=[NSString stringWithFormat:@"%@/%llu/%.0f",call,(unsigned long long)s.frequencyHz,reported.timeIntervalSince1970]; return s;
}
- (BOOL)isStaleAt:(NSDate *)now { return [now timeIntervalSinceDate:self.reportedAt]>900; }
@end
@implementation TX500DXStream {
    NSMutableData *_line; NSUInteger _state; uint8_t _verb; BOOL _discard,_escape;
}
- (instancetype)init { if((self=[super init])) _line=[NSMutableData data]; return self; }
- (void)consume:(NSData *)data {
    const uint8_t *bytes=data.bytes;
    for(NSUInteger i=0;i<data.length;i++) {
        uint8_t c=bytes[i];
        if(_state==1) { if(c==255) { _state=0; continue; } if(c==250) { _state=3; continue; } if(c>=251 && c<=254) { _verb=c; _state=2; continue; } _state=0; continue; }
        if(_state==2) { if(_verb==251 || _verb==253) { uint8_t reply[]={255,_verb==251?254:252,c}; if(self.replyHandler) self.replyHandler([NSData dataWithBytes:reply length:3]); } _state=0; continue; }
        if(_state==3) { if(c==255) _state=4; continue; }
        if(_state==4) { _state=c==240?0:3; continue; }
        if(c==255) { _state=1; continue; }
        if(c==27) { _escape=YES; continue; }
        if(_escape) { if(c>=64 && c<=126 && c!='[') _escape=NO; continue; }
        if(c=='\n' || c=='\r') {
            if(!_discard && _line.length) { NSString *line=[[NSString alloc] initWithData:_line encoding:NSUTF8StringEncoding] ?: [[NSString alloc] initWithData:_line encoding:NSISOLatin1StringEncoding]; if(self.lineHandler) self.lineHandler(line); }
            [_line setLength:0]; _discard=NO; continue;
        }
        if(_discard || c<32 || c==127) continue;
        [_line appendBytes:&c length:1]; if(_line.length>1024) { [_line setLength:0]; _discard=YES; }
    }
    if(!_discard && _line.length && self.promptHandler) { NSString *s=[[NSString alloc] initWithData:_line encoding:NSISOLatin1StringEncoding]; self.promptHandler(s); }
}
@end
@implementation TX500DXAlertPolicy {
    NSMutableDictionary<NSString *,NSDate *> *_last; NSDate *_lastAny;
}
- (instancetype)init { if((self=[super init])) { _calls=@""; _countries=@""; _last=[NSMutableDictionary dictionary]; } return self; }
- (BOOL)matches:(TX500DXSpot *)spot {
    if(!self.enabled || (!self.calls.length && !self.countries.length)) return NO;
    BOOL callOK=!self.calls.length,countryOK=!self.countries.length;
    for(NSString *raw in [self.calls.uppercaseString componentsSeparatedByString:@","]) {
        NSString *p=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; if(!p.length) continue;
        NSString *regex=[[NSRegularExpression escapedPatternForString:p] stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"];
        if(DXMatch(spot.callsign,[NSString stringWithFormat:@"^%@$",regex])) callOK=YES;
    }
    for(NSString *raw in [self.countries componentsSeparatedByString:@","]) { NSString *country=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]; if(country.length && [country caseInsensitiveCompare:spot.country]==NSOrderedSame) countryOK=YES; }
    return callOK && countryOK;
}
- (BOOL)shouldNotify:(TX500DXSpot *)spot now:(NSDate *)now {
    if(![self matches:spot] || [spot isStaleAt:now] || [now timeIntervalSinceDate:spot.reportedAt]<-60) return NO;
    NSString *key=[NSString stringWithFormat:@"%@/%@",spot.callsign,spot.band];
    if((_lastAny && [now timeIntervalSinceDate:_lastAny]<30) || (_last[key] && [now timeIntervalSinceDate:_last[key]]<600)) return NO;
    for(NSString *old in _last.allKeys) if([now timeIntervalSinceDate:_last[old]]>=600) [_last removeObjectForKey:old];
    _last[key]=now; _lastAny=now; return YES;
}
@end
@implementation TX500DXCluster {
    dispatch_queue_t _queue; nw_connection_t _connection; TX500DXStream *_stream;
    NSMutableArray<TX500DXSpot *> *_items; NSMutableSet *_ids;
    NSString *_host,*_call; NSInteger _port; NSUInteger _generation,_attempt;
    BOOL _wanted,_loginSent,_authenticated;
    NSArray *_spots; NSString *_status; BOOL _running;
}
// Endpoints published by their operators; selecting one never initiates a connection.
+ (NSArray<NSDictionary<NSString *,NSString *> *> *)recommendedNodes {
    return @[
        @{@"name":@"F5LEN",@"host":@"dxcluster.f5len.org",@"port":@"7373",@"website":@"https://cluster.f5len.org/index.php?p=about"},
        @{@"name":@"G1FEF · DXSpider",@"host":@"dxc.hamserve.uk",@"port":@"7300",@"website":@"https://wiki.dxcluster.org/wiki/How_to_connect"},
        @{@"name":@"EA3KZ-5",@"host":@"dx.ea3kz.com",@"port":@"7300",@"website":@"https://dx.ea3kz.com/"}
    ];
}
- (instancetype)init { if((self=[super init])) { _queue=dispatch_queue_create("ir.factoreal.dxcluster",DISPATCH_QUEUE_SERIAL); _items=[NSMutableArray array]; _ids=[NSMutableSet set]; _spots=@[]; _status=@"Offline • connect to receive spots"; } return self; }
- (void)dealloc { if(_connection) nw_connection_cancel(_connection); }
- (NSArray *)spots { @synchronized(self) { return _spots; } }
- (NSString *)status { @synchronized(self) { return _status; } }
- (BOOL)running { @synchronized(self) { return _running; } }
- (void)publish:(NSString *)status {
    @synchronized(self) { _spots=[_items copy]; if(status) _status=[status copy]; _running=_wanted; }
    dispatch_async(dispatch_get_main_queue(), ^{ if(self.changed) self.changed(); });
}
+ (BOOL)validHost:(NSString *)host port:(NSInteger)port callsign:(NSString *)call {
    if(!DXCall(call.uppercaseString) || port<1 || port>65535 || !host.length || host.length>253) return NO;
    struct in6_addr addr; if(inet_pton(AF_INET6,host.UTF8String,&addr)==1) return YES;
    return DXMatch(host,@"^(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$");
}
+ (NSTimeInterval)retryDelayForAttempt:(NSUInteger)attempt { return MIN(60.0,2.0*pow(2,MIN(attempt,(NSUInteger)5))); }
- (BOOL)connectHost:(NSString *)host port:(NSInteger)port callsign:(NSString *)call {
    if(![self.class validHost:host port:port callsign:call]) return NO;
    dispatch_async(_queue, ^{ self->_generation++; if(self->_connection) nw_connection_cancel(self->_connection); self->_connection=nil; self->_host=[host copy]; self->_port=port; self->_call=call.uppercaseString; self->_attempt=0; self->_wanted=YES; [self open]; }); return YES;
}
- (void)disconnect { dispatch_async(_queue, ^{ self->_wanted=NO; self->_generation++; if(self->_connection) nw_connection_cancel(self->_connection); self->_connection=nil; [self publish:@"Offline • saved session spots remain visible"]; }); }
- (void)clear { dispatch_async(_queue, ^{ [self->_items removeAllObjects]; [self->_ids removeAllObjects]; [self publish:nil]; }); }
- (void)sendData:(NSData *)data generation:(NSUInteger)token {
    if(token!=_generation || !_connection) return;
    dispatch_data_t content=dispatch_data_create(data.bytes,data.length,_queue,^{ (void)data; });
    __weak typeof(self) weak=self;
    nw_connection_send(_connection,content,NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,false,^(nw_error_t e){ typeof(self) self=weak; if(self && e && token==self->_generation) [self failed:@"Send failed"]; });
}
- (void)prompt:(NSString *)text generation:(NSUInteger)token {
    if(token!=_generation || [text hasPrefix:@"DX de "]) return;
    NSString *s=text.lowercaseString;
    if(DXMatch(s,@"(?:password|passcode)\\s*[:>]\\s*$") || [s containsString:@"login incorrect"] || [s containsString:@"invalid callsign"]) {
        _wanted=NO; _generation++; if(_connection) nw_connection_cancel(_connection); _connection=nil;
        [self publish:@"This node requires registration or a password. Choose a public callsign-login node."]; return;
    }
    if(!_loginSent && DXMatch(s,@"(?:login|call(?:sign)?|enter (?:your )?call(?:sign)?)\\s*[:>]\\s*$")) {
        _loginSent=YES; [self sendData:[[_call stringByAppendingString:@"\r\n"] dataUsingEncoding:NSASCIIStringEncoding] generation:token]; [self publish:@"Callsign sent • waiting for the node"]; return;
    }
    if(_loginSent && ([s containsString:@"welcome"] || [s containsString:@" de "] || [s hasSuffix:@">"])) { _authenticated=YES; _attempt=0; [self publish:@"Connected • listening for spots"]; }
}
- (void)accept:(NSString *)line date:(NSDate *)date {
    TX500DXSpot *s=[TX500DXSpot parseLine:line receivedAt:date]; if(!s || [_ids containsObject:s.identifier]) return;
    [_items insertObject:s atIndex:0]; [_ids addObject:s.identifier];
    if(_items.count>1000) { [_ids removeObject:_items.lastObject.identifier]; [_items removeLastObject]; }
    [self publish:nil]; dispatch_async(dispatch_get_main_queue(), ^{ if(self.receivedSpot) self.receivedSpot(s); });
}
- (void)ingestLine:(NSString *)line receivedAt:(NSDate *)date { dispatch_async(_queue, ^{ [self accept:line date:date]; }); }
- (void)receive:(NSUInteger)token {
    if(token!=_generation || !_connection) return; __weak typeof(self) weak=self;
    nw_connection_receive(_connection,1,8192,^(dispatch_data_t content,nw_content_context_t context,bool complete,nw_error_t error) {
        (void)context; typeof(self) self=weak; if(!self || token!=self->_generation) return;
        if(content) { NSMutableData *data=[NSMutableData data]; dispatch_data_apply(content,^bool(dispatch_data_t region,size_t offset,const void *buffer,size_t size){ (void)region;(void)offset;[data appendBytes:buffer length:size];return true; }); [self->_stream consume:data]; }
        if(token!=self->_generation) return;
        if(error || complete) [self failed:@"Connection lost"]; else [self receive:token];
    });
}
- (void)failed:(NSString *)reason {
    _generation++; if(_connection) nw_connection_cancel(_connection); _connection=nil;
    if(!_wanted) return;
    NSTimeInterval delay=[self.class retryDelayForAttempt:_attempt++]; NSUInteger token=_generation;
    [self publish:[NSString stringWithFormat:@"%@ • reconnecting in %.0f seconds",reason,delay]];
    __weak typeof(self) weak=self; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),_queue,^{ typeof(self) self=weak; if(self && self->_wanted && token==self->_generation) [self open]; });
}
- (void)open {
    if(!_wanted) return; NSUInteger token=++_generation; _loginSent=NO; _authenticated=NO;
    _stream=[TX500DXStream new]; __weak typeof(self) weak=self;
    _stream.replyHandler=^(NSData *data){ [weak sendData:data generation:token]; };
    _stream.promptHandler=^(NSString *s){ [weak prompt:s generation:token]; };
    _stream.lineHandler=^(NSString *s){ typeof(self) self=weak; if(!self || token!=self->_generation) return; [self prompt:s generation:token]; if(token!=self->_generation) return;
        if([s hasPrefix:@"DX de "] && [TX500DXSpot parseLine:s receivedAt:NSDate.date]) { self->_authenticated=YES; self->_attempt=0; [self publish:@"Connected • receiving spots"]; [self accept:s date:NSDate.date]; }
    };
    nw_parameters_t parameters=nw_parameters_create_secure_tcp(NW_PARAMETERS_DISABLE_PROTOCOL,^(nw_protocol_options_t options){ nw_tcp_options_set_enable_keepalive(options,true); nw_tcp_options_set_keepalive_idle_time(options,60); nw_tcp_options_set_keepalive_interval(options,15); nw_tcp_options_set_keepalive_count(options,3); });
    _connection=nw_connection_create(nw_endpoint_create_host(_host.UTF8String,[NSString stringWithFormat:@"%ld",(long)_port].UTF8String),parameters);
    nw_connection_set_queue(_connection,_queue);
    nw_connection_set_state_changed_handler(_connection,^(nw_connection_state_t state,nw_error_t error){ (void)error; typeof(self) self=weak; if(!self || token!=self->_generation) return;
        if(state==nw_connection_state_ready) { [self publish:@"TCP connected • waiting for callsign login"]; [self receive:token]; }
        else if(state==nw_connection_state_failed || state==nw_connection_state_waiting) [self failed:@"Node unavailable"];
    });
    [self publish:[NSString stringWithFormat:@"Connecting to %@:%ld…",_host,(long)_port]]; nw_connection_start(_connection);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,20*NSEC_PER_SEC),_queue,^{ typeof(self) self=weak; if(self && token==self->_generation && !self->_authenticated) [self failed:@"Login timed out"]; });
}
@end
