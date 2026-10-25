cmake_minimum_required(VERSION 3.5.0)
project(LinkDesk)
set(CMAKE_CXX_STANDARD 17)
add_library(linkdesk SHARED receiver.cpp)
target_compile_options(linkdesk PRIVATE -Wall -Wextra)
target_link_libraries(linkdesk PUBLIC libace_napi.z.so libhilog_ndk.z.so
  libnative_media_codecbase.so libnative_media_core.so libnative_media_vdec.so libnative_window.so libnative_buffer.so libnative_vsync.so libnative_display_manager.so libohaudio.so)

add_library(screenmirror SHARED screen_mirror.cpp)
target_link_libraries(screenmirror PUBLIC libace_napi.z.so libhilog_ndk.z.so libnative_avscreen_capture.so
  libnative_media_codecbase.so libnative_media_core.so libnative_media_venc.so libnative_window.so)
