#pragma once
#include <string>
#include <window_manager/oh_display_manager.h>
#include <multimedia/player_framework/native_avcapability.h>
#include <multimedia/player_framework/native_avcodec_base.h>

struct HdrCapabilities {
    bool displayQueried=false, pq=false, hlg=false, main10=false, dolbyDecoder=false;
    std::string formats,profiles;
    bool HDR10() const { return displayQueried&&pq&&main10; }
    static HdrCapabilities Query(){
        HdrCapabilities result;NativeDisplayManager_DisplayInfo *display=nullptr;
        if(OH_NativeDisplayManager_CreatePrimaryDisplay(&display)==DISPLAY_MANAGER_OK&&display){
            result.displayQueried=true;
            if(display->hdrFormat)for(uint32_t i=0;i<display->hdrFormat->hdrFormatLength;i++){
                uint32_t value=display->hdrFormat->hdrFormats[i];result.formats+=std::to_string(value)+",";
                if(value==1)result.hlg=true;if(value==2)result.pq=true;
            }
            OH_NativeDisplayManager_DestroyDisplay(display);
        }
        OH_AVCapability *cap=OH_AVCodec_GetCapabilityByCategory(OH_AVCODEC_MIMETYPE_VIDEO_HEVC,false,HARDWARE);
        const int32_t *profiles=nullptr;uint32_t count=0;
        if(cap&&OH_AVCapability_GetSupportedProfiles(cap,&profiles,&count)==AV_ERR_OK)for(uint32_t i=0;i<count;i++){
            int32_t p=profiles[i];result.profiles+=std::to_string(p)+",";
            if(p==HEVC_PROFILE_MAIN_10||p==HEVC_PROFILE_MAIN_10_HDR10||p==HEVC_PROFILE_MAIN_10_HDR10_PLUS)result.main10=true;
        }
        result.dolbyDecoder=OH_AVCodec_GetCapabilityByCategory("video/dolby-vision",false,HARDWARE)!=nullptr;
        return result;
    }
};
