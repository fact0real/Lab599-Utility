#import <Foundation/Foundation.h>
#import <util.h>
#import <poll.h>
#import <unistd.h>
#import "TX500StationCore.h"
#import "Lab599SerialPort.h"
static NSUInteger checks;
static void Check(BOOL ok,NSString *text) { checks++; if(!ok) { fprintf(stderr,"FAIL: %s\n",text.UTF8String); exit(1); } }
static void Scenario(NSString *scenario) {
    int master,slave; char path[256]; Check(openpty(&master,&slave,path,NULL,NULL)==0,@"Create isolated serial emulator"); close(slave);
    NSMutableArray *commands=[NSMutableArray array]; __block BOOL stop=NO;
    dispatch_group_t group=dispatch_group_create();
    __block double frequencySet=0,modeSet=0;
    __block NSUInteger targetReads=0;
    dispatch_group_async(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ @autoreleasepool {
        NSMutableString *pending=[NSMutableString string]; NSString *frequency=@"00007074000",*mode=@"6",*target=nil,*targetMode=nil;
        BOOL delayedReply=NO,firstModeRead=YES;
        while(YES) {
            @synchronized(commands) { if(stop) break; }
            struct pollfd p={master,POLLIN,0}; if(poll(&p,1,20)<=0) continue;
            char bytes[256]; ssize_t n=read(master,bytes,sizeof(bytes)); if(n<=0) { usleep(1000); continue; }
            NSString *chunk=[[NSString alloc] initWithBytes:bytes length:n encoding:NSASCIIStringEncoding]; if(chunk) [pending appendString:chunk];
            while([pending containsString:@";"]) {
                NSRange end=[pending rangeOfString:@";"]; NSString *cmd=[pending substringToIndex:end.location+1]; [pending deleteCharactersInRange:NSMakeRange(0,end.location+1)];
                [commands addObject:cmd]; double now=Lab599MonotonicTime();
                if(target && now-frequencySet>0.24 && ![scenario isEqual:@"frequency-ignored"]) { frequency=target; target=nil; mode=@"1"; }
                if(targetMode && now-modeSet>0.22 && ![scenario isEqual:@"mode-ignored"]) { mode=targetMode; targetMode=nil; }
                NSString *reply=nil;
                if([cmd isEqual:@"FA;"]) {
                    if([frequency isEqual:@"00014285000"]) targetReads++;
                    if([scenario isEqual:@"slow-fragmented"] && !delayedReply) { usleep(450000); delayedReply=YES; }
                    reply=[NSString stringWithFormat:@"FA%@;",frequency];
                } else if([cmd hasPrefix:@"FA"]) { target=[cmd substringWithRange:NSMakeRange(2,11)]; frequencySet=now; }
                else if([cmd isEqual:@"MD;"]) {
                    if([scenario isEqual:@"missing-initial-mode"] && frequencySet==0) continue;
                    if([scenario isEqual:@"rejected-initial-mode"]) reply=@"?;";
                    else if(modeSet && firstModeRead && [scenario isEqual:@"busy-once"]) { reply=@"O;"; firstModeRead=NO; }
                    else reply=[NSString stringWithFormat:@"MD%@;",mode];
                } else if([cmd hasPrefix:@"MD"]) { targetMode=[cmd substringWithRange:NSMakeRange(2,1)]; modeSet=now; }
                else if([cmd isEqual:@"PT;"]) reply=frequencySet && [scenario isEqual:@"external-tx"] ? @"PT1;" : @"PT0;";
                else if([@[@"FR;",@"FT;",@"XT;",@"VX;"] containsObject:cmd]) reply=[[cmd substringToIndex:2] stringByAppendingString:@"0;"];
                else reply=@"?;";
                if(reply) {
                    // Read-command echo and unrelated frames must not count as a reply.
                    if([scenario isEqual:@"slow-fragmented"]) { NSString *extra=[cmd stringByAppendingString:@"SM0001;"]; write(master,extra.UTF8String,extra.length); }
                    NSData *data=[reply dataUsingEncoding:NSASCIIStringEncoding];
                    write(master,data.bytes,1); usleep(1000); write(master,(const char *)data.bytes+1,data.length-1);
                }
            }
        }
    }});
    TX500StationCore *core=[TX500StationCore new]; [core selectOwner:@"Station" port:@(path) error:nil];
    NSError *error=nil; BOOL ok=[core tune:14285000 mode:2 owner:@"Station" error:&error];
    @synchronized(commands) { stop=YES; }
    dispatch_group_wait(group,DISPATCH_TIME_FOREVER); [core suspend:nil]; close(master);
    BOOL success=[@[@"delayed-band",@"slow-fragmented",@"busy-once"] containsObject:scenario];
    Check(ok==success,[NSString stringWithFormat:@"%@: success=%d error=%@",scenario,ok,error.localizedDescription]);
    for(NSString *cmd in commands) Check(![cmd hasPrefix:@"TX"] && ![cmd hasPrefix:@"RX"] && ![cmd hasPrefix:@"KY"],@"Tuning never keys or dekeys the radio");
    if(success) {
        Check(modeSet-frequencySet>=0.4,@"Mode waits for band change and consecutive frequency readbacks");
        Check(targetReads>=4,@"Frequency checked before mode and again with final mode");
        Check(error==nil,@"Transient busy/old status does not leak a success error");
    } else {
        Check(error.localizedDescription.length>0,@"Failure explains what was not verified");
        if([scenario isEqual:@"mode-ignored"]) Check([error.localizedDescription containsString:@"MD1"] && [error.localizedDescription containsString:@"MD2"],@"Mode mismatch reports observed and requested mode");
        else Check(modeSet==0,@"No mode write after failed frequency or initial status");
        if([scenario containsString:@"initial-mode"]) Check([error.localizedDescription containsString:@"MD;"],@"Preflight failure retains the failing CAT query");
    }
    printf("PASS: %s\n",scenario.UTF8String);
}
int main(void) { @autoreleasepool {
    for(NSString *s in @[@"delayed-band",@"slow-fragmented",@"busy-once",@"frequency-ignored",@"mode-ignored",@"external-tx",@"missing-initial-mode",@"rejected-initial-mode"]) Scenario(s);
    printf("PASS: %lu tuning checks; pseudo-terminals only, no physical radio.\n",(unsigned long)checks);
} return 0; }
