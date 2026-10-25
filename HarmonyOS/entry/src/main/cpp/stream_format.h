#pragma once
#include <cstdint>
#include <cstring>

struct DesktopStreamFormat {
    uint32_t width=0,height=0,fps=0;
    bool hevc=false,hdr10=false,receiptMetrics=false;
    static bool Parse(const uint8_t *header,DesktopStreamFormat &out){
        DesktopStreamFormat value;
        auto read=[](const uint8_t *p){return uint32_t(p[0])<<24|uint32_t(p[1])<<16|uint32_t(p[2])<<8|p[3];};
        value.width=read(header+4);value.height=read(header+8);value.fps=read(header+12);
        value.hdr10=!memcmp(header,"LDQ1",4);
        value.hevc=value.hdr10||!memcmp(header,"LDH1",4)||!memcmp(header,"LDH2",4);
        value.receiptMetrics=!memcmp(header,"LDH2",4)||!memcmp(header,"LDV2",4);
        if(!value.hevc&&memcmp(header,"LDV1",4)&&memcmp(header,"LDV2",4))return false;
        bool full=value.width==2880&&value.height==1920;
        bool legacy=value.width==1920&&value.height==1280;
        if((!full&&!legacy)||(value.hdr10&&!full)||(value.fps!=60&&value.fps!=120&&value.fps!=144))return false;
        out=value;return true;
    }
};
