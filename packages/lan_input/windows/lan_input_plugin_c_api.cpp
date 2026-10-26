#include "include/lan_input/lan_input_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "lan_input_plugin.h"

void LanInputPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  lan_input::LanInputPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
