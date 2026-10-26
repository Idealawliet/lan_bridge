//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <desktop_drop/desktop_drop_plugin.h>
#include <file_selector_windows/file_selector_windows.h>
#include <lan_input/lan_input_plugin_c_api.h>
#include <pasteboard/pasteboard_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  DesktopDropPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("DesktopDropPlugin"));
  FileSelectorWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FileSelectorWindows"));
  LanInputPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("LanInputPluginCApi"));
  PasteboardPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PasteboardPlugin"));
}
