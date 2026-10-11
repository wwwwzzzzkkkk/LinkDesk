// LinkDesk configuration of BlackHole (GPL-3.0), see vendor/LICENSE and UPSTREAM.json.
// The dual endpoint exposes normal OS controls but leaves the PCM stream unchanged:
// the Mac app applies those controls to the built-in speakers only.
#ifndef LINKDESK_CONTROL_ONLY
#define LINKDESK_CONTROL_ONLY 0
#endif
#define kEnableVolumeControl (!LINKDESK_CONTROL_ONLY)
#define kEnableMuteControl (!LINKDESK_CONTROL_ONLY)
#define kHas_Driver_Name_Format false
#define kNumber_Of_Channels 2
#define kSampleRates 48000
#define kDevice2_IsHidden true
#define kCanBeDefaultSystemDevice false
#include "vendor/BlackHole.c"
