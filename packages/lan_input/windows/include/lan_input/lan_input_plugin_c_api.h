#ifndef FLUTTER_PLUGIN_LAN_INPUT_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_LAN_INPUT_PLUGIN_C_API_H_

#include <flutter_plugin_registrar.h>

#ifdef FLUTTER_PLUGIN_IMPL
#define LAN_INPUT_PLUGIN_EXPORT __declspec(dllexport)
#else
#define LAN_INPUT_PLUGIN_EXPORT __declspec(dllimport)
#endif

#if defined(__cplusplus)
extern "C" {
#endif
LAN_INPUT_PLUGIN_EXPORT void LanInputPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#if defined(__cplusplus)
}
#endif
#endif
