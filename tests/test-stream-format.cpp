#include "../HarmonyOS/entry/src/main/cpp/stream_format.h"
#include <cassert>
#include <cstdio>
static void Put(uint8_t *p,uint32_t value){for(int i=0;i<4;i++)p[i]=value>>(24-i*8);}
int main(){
    uint8_t header[16]{};Put(header+4,2880);Put(header+8,1920);Put(header+12,144);DesktopStreamFormat out;
    memcpy(header,"LDQ1",4);assert(DesktopStreamFormat::Parse(header,out)&&out.hdr10&&out.hevc&&!out.receiptMetrics);
    memcpy(header,"LDH2",4);assert(DesktopStreamFormat::Parse(header,out)&&!out.hdr10&&out.hevc&&out.receiptMetrics);
    memcpy(header,"LDV1",4);assert(DesktopStreamFormat::Parse(header,out)&&!out.hdr10&&!out.hevc&&!out.receiptMetrics);
    Put(header+4,1920);Put(header+8,1280);assert(DesktopStreamFormat::Parse(header,out));
    memcpy(header,"LDQ1",4);assert(!DesktopStreamFormat::Parse(header,out));
    Put(header+4,2880);Put(header+8,1920);Put(header+12,240);assert(!DesktopStreamFormat::Parse(header,out));
    Put(header+12,60);memcpy(header,"LDQ2",4);assert(!DesktopStreamFormat::Parse(header,out));
    puts("STREAM_FORMAT_PASS: HDR10 requires HEVC and full resolution; SDR compatibility, diagnostic mode and malformed formats");
}
