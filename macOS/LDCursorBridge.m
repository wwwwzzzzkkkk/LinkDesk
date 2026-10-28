#import "LDCursorBridge.h"
#import "LDCursorFlow.h"
#import <CoreMedia/CoreMedia.h>
#import <arpa/inet.h>
#import <netinet/tcp.h>
#import <sys/socket.h>
#import <unistd.h>
#import <stdlib.h>

static void Put32(NSMutableData *data, uint32_t value) { value=htonl(value); [data appendBytes:&value length:4]; }
static int CompareDouble(const void *a, const void *b) { double x=*(const double *)a, y=*(const double *)b; return (x>y)-(x<y); }
static uint64_t ClockUs(void) { return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) * 1000000.0; }

@implementation LDCursorBridge {
    NSLock *_lock;
    NSTimer *_timer;
    dispatch_group_t _workers;
    int _listener, _client;
    BOOL _running;
    CGDirectDisplayID _display;
    void (^_changed)(BOOL);
    NSData *_latest, *_shape;
    uint32_t _sequence;
    unsigned _epoch;
    CGPoint _lastPoint;
    BOOL _lastVisible;
    double _sampledShapeAt, _sentHeartbeatAt;
    NSSize _size;
    NSPoint _hotspot;
}
- (instancetype)init {
    if ((self=[super init])) { _lock=[NSLock new]; _workers=dispatch_group_create(); _listener=_client=-1; }
    return self;
}
- (void)startForDisplay:(CGDirectDisplayID)display modeChanged:(void (^)(BOOL))changed {
    [self stop]; unsigned epoch=++_epoch; _display=display; _changed=[changed copy]; _sequence=0; _shape=nil; _latest=nil;
    int fd=socket(AF_INET,SOCK_STREAM,0); if(fd<0)return;
    int yes=1; setsockopt(fd,SOL_SOCKET,SO_REUSEADDR,&yes,sizeof(yes));
    struct sockaddr_in address={0}; address.sin_family=AF_INET; address.sin_port=htons(24836); address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    if(bind(fd,(struct sockaddr *)&address,sizeof(address))||listen(fd,1)){close(fd);return;}
    [_lock lock]; _running=YES; _listener=fd; [_lock unlock];
    __weak LDCursorBridge *weakSelf=self;
    _timer=[NSTimer timerWithTimeInterval:1.0/240 repeats:YES block:^(NSTimer *timer){[weakSelf sample];}];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    [self sample];
    dispatch_group_async(_workers,dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE,0),^{
        while(YES){
            int client=accept(fd,NULL,NULL); if(client<0)break;
            setsockopt(client,IPPROTO_TCP,TCP_NODELAY,&yes,sizeof(yes));
            setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&yes,sizeof(yes));
            struct timeval timeout={0,150000};
            setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            setsockopt(client,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            char ready[8];
            if(recv(client,ready,8,MSG_WAITALL)!=8||memcmp(ready,"LDCUR001",8)){close(client);continue;}
            [self->_lock lock]; BOOL live=self->_running; if(live)self->_client=client; [self->_lock unlock];
            if(!live){close(client);break;}
            dispatch_async(dispatch_get_main_queue(),^{if(epoch==self->_epoch&&self->_timer&&self->_changed)self->_changed(YES);});
            NSLog(@"CURSOR_CHANNEL connected");
            NSData *last=nil; uint8_t ack[16]; size_t ackBytes=0; LDCursorFlow flow={0};
            double total=0,maximum=0,latencies[120]; unsigned samples=0; uint64_t lastAck=ClockUs();
            while(YES){
                [self->_lock lock]; NSData *packet=self->_latest; live=self->_running; [self->_lock unlock];
                if(!live)break;
                if(packet&&packet!=last&&LDCursorCanSend(&flow)){
                    const uint8_t *p=packet.bytes; size_t left=packet.length;
                    while(left){ssize_t n=send(client,p,left,0);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;left-=n;}
                    if(left)break; last=packet; uint32_t sequence; memcpy(&sequence, (const uint8_t *)packet.bytes + 8, 4); LDCursorDidSend(&flow, ntohl(sequence));
                }
                ssize_t n=recv(client,ack+ackBytes,16-ackBytes,MSG_DONTWAIT);
                if(n==0)break;
                if(n>0){
                    ackBytes+=n;
                    if(ackBytes==16){
                        if(memcmp(ack,"LDCA",4))break;
                        uint32_t sequence; memcpy(&sequence,ack+4,4);
                        if(!LDCursorDidAck(&flow,ntohl(sequence)))break;
                        uint64_t stamp;memcpy(&stamp,ack+8,8);stamp=CFSwapInt64BigToHost(stamp);
                        lastAck=ClockUs(); double ms=(lastAck-stamp)/1000.0;
                        if(ms<1000){total+=ms;maximum=MAX(maximum,ms);latencies[samples++]=ms;}
                        if(samples==120){qsort(latencies,120,sizeof(double),CompareDouble);NSLog(@"CURSOR_RTT samples=120 mean_ms=%.2f p50_ms=%.2f p95_ms=%.2f max_ms=%.2f",total/120,latencies[59],latencies[113],maximum);samples=0;total=maximum=0;}
                        ackBytes=0;
                    }
                }else if(errno!=EAGAIN&&errno!=EWOULDBLOCK&&errno!=EINTR)break;
                if(ClockUs()-lastAck>500000)break;
                [NSThread sleepForTimeInterval:0.002];
            }
            [self->_lock lock]; self->_client=-1; [self->_lock unlock]; close(client);
            dispatch_async(dispatch_get_main_queue(),^{if(epoch==self->_epoch&&self->_timer&&self->_changed)self->_changed(NO);});
            NSLog(@"CURSOR_CHANNEL disconnected; video cursor fallback");
        }
    });
}
- (void)sample {
    CGEventRef event=CGEventCreate(NULL); if(!event)return;
    CGPoint point=CGEventGetLocation(event); CFRelease(event);
    CGRect bounds=CGDisplayBounds(_display); if(bounds.size.width<=0||bounds.size.height<=0)return;
    BOOL visible=CGRectContainsPoint(bounds,point);
    double now=NSProcessInfo.processInfo.systemUptime; BOOL shapeChanged=NO;
    if(now-_sampledShapeAt>0.033||!_shape){
        _sampledShapeAt=now;
        NSCursor *cursor=NSCursor.currentSystemCursor ?: NSCursor.arrowCursor;
        NSImage *image=cursor.image; NSRect rect=NSMakeRect(0,0,image.size.width,image.size.height);
        CGImageRef cg=[image CGImageForProposedRect:&rect context:nil hints:nil];
        if(cg&&CGImageGetWidth(cg)<=256&&CGImageGetHeight(cg)<=256){
            NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:cg];
            NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if(png.length&&png.length<=65536&&![_shape isEqual:png]){_shape=png;shapeChanged=YES;}
            _size=image.size;_hotspot=cursor.hotSpot;
        }
    }
    if(!_shape)return;
    if(!shapeChanged&&visible==_lastVisible&&CGPointEqualToPoint(point,_lastPoint)&&now-_sentHeartbeatAt<0.1)return;
    _lastPoint=point;_lastVisible=visible;_sentHeartbeatAt=now;
    // All dimensions are fractions of the virtual display, independent of HiDPI scale.
    NSMutableData *packet=[NSMutableData dataWithBytes:"LDCP" length:4];
    // Include a small shape on each update: every snapshot is independently recoverable.
    Put32(packet,(uint32_t)_shape.length);Put32(packet,++_sequence);Put32(packet,visible?1:0);
    Put32(packet,visible?(uint32_t)((point.x-bounds.origin.x)/bounds.size.width*1000000):0);
    Put32(packet,visible?(uint32_t)((point.y-bounds.origin.y)/bounds.size.height*1000000):0);
    Put32(packet,(uint32_t)(_size.width/bounds.size.width*1000000));
    Put32(packet,(uint32_t)(_size.height/bounds.size.height*1000000));
    Put32(packet,(uint32_t)(_hotspot.x/bounds.size.width*1000000));
    Put32(packet,(uint32_t)(_hotspot.y/bounds.size.height*1000000));
    uint64_t stamp=CFSwapInt64HostToBig(ClockUs());[packet appendBytes:&stamp length:8];[packet appendData:_shape];
    [_lock lock];_latest=packet;[_lock unlock];
}
- (void)stop {
    ++_epoch;
    [_timer invalidate];_timer=nil;
    [_lock lock];_running=NO;
    if(_client>=0)shutdown(_client,SHUT_RDWR);
    if(_listener>=0){shutdown(_listener,SHUT_RDWR);close(_listener);_listener=-1;}
    [_lock unlock];
    dispatch_group_wait(_workers,DISPATCH_TIME_FOREVER);_latest=nil;
    if(_changed)_changed(NO);_changed=nil;
}
@end
