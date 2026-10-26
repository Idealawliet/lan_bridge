cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "lan_input")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "lan_input_plugin")
add_library(${PLUGIN_NAME} SHARED
  "lan_input_plugin.cpp"
  "lan_input_plugin_c_api.cpp"
  "file_drag_bridge.cpp"
)
apply_standard_settings(${PLUGIN_NAME})
# std::packaged_task/future and explicit validation errors require the STL's
# exception machinery, unlike Flutter's default generated project setting.
get_target_property(PLUGIN_DEFINITIONS ${PLUGIN_NAME} COMPILE_DEFINITIONS)
list(REMOVE_ITEM PLUGIN_DEFINITIONS "_HAS_EXCEPTIONS=0")
set_target_properties(${PLUGIN_NAME} PROPERTIES COMPILE_DEFINITIONS "${PLUGIN_DEFINITIONS}")
target_compile_features(${PLUGIN_NAME} PUBLIC cxx_std_20)
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL NOMINMAX)
target_include_directories(${PLUGIN_NAME} INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin user32 ole32 shell32 uuid)
set(lan_input_bundled_libraries "" PARENT_SCOPE)
