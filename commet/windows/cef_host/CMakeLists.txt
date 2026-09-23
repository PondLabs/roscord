cmake_minimum_required(VERSION 3.21)

# The Windows host is deliberately opt-in.  The normal Flutter build does not
# have a CEF distribution in its source tree; release jobs enable this target
# after tools/cef_runtime.py has staged the locked build SDK.  The SDK staging
# command verifies the exact archive digest and combines the SDK inputs with
# the allow-listed runtime files in a build-only directory.
if(NOT WIN32)
  message(FATAL_ERROR "roscord's cef_host target is Windows-only")
endif()

if(NOT DEFINED CEF_ROOT OR CEF_ROOT STREQUAL "")
  message(FATAL_ERROR
    "CEF_ROOT must point at the locked CEF distribution when building cef_host")
endif()

get_filename_component(CEF_ROOT "${CEF_ROOT}" ABSOLUTE)
if(NOT EXISTS "${CEF_ROOT}/include/cef_app.h")
  message(FATAL_ERROR "CEF_ROOT does not contain the CEF headers: ${CEF_ROOT}")
endif()

list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
# CEF builds libcef_dll_wrapper against the static CRT (/MT) by default, but
# client.dll uses the dynamic CRT like the rest of the Flutter build, and the
# two cannot be linked together.
set(CEF_RUNTIME_LIBRARY_FLAG "/MD" CACHE STRING
  "CRT flag for the CEF wrapper, matching client.dll" FORCE)
find_package(CEF REQUIRED)

# libcef_dll_wrapper is the only CEF library linked by the client DLL.  The
# standard SDK exposes its source through CEF_LIBCEF_DLL_WRAPPER_PATH (usually
# `${CEF_ROOT}/libcef_dll`).  The official M138+ bootstrap owns the process
# entry point and sandbox setup; the client DLL exports RunWinMain and receives
# the bootstrap sandbox handle.
if(NOT DEFINED CEF_LIBCEF_DLL_WRAPPER_PATH OR
   CEF_LIBCEF_DLL_WRAPPER_PATH STREQUAL "")
  set(CEF_LIBCEF_DLL_WRAPPER_PATH "${CEF_ROOT}/libcef_dll")
endif()
if(NOT EXISTS "${CEF_LIBCEF_DLL_WRAPPER_PATH}/CMakeLists.txt")
  message(FATAL_ERROR
    "CEF SDK is missing libcef_dll/CMakeLists.txt: ${CEF_LIBCEF_DLL_WRAPPER_PATH}")
endif()
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}"
  "${CMAKE_CURRENT_BINARY_DIR}/libcef_dll_wrapper")

add_library(cef_host_client SHARED
  cef_host.cpp
  cef_host.rc
)

set_target_properties(cef_host_client PROPERTIES
  OUTPUT_NAME "client"
  PREFIX ""
  SUFFIX ".dll"
)

# The CEF headers use C++20 concepts.
target_compile_features(cef_host_client PRIVATE cxx_std_20)
target_compile_definitions(cef_host_client PRIVATE
  UNICODE
  _UNICODE
  NOMINMAX
  CEF_USE_BOOTSTRAP
  USE_SANDBOX
  CEF_API_VERSION=CEF_API_VERSION_LAST
)
# Beyond /wd4100, the same warnings CEF disables for its own /W4 /WX targets
# (see CEF_COMPILER_FLAGS in cmake/cef_variables.cmake), plus C4505 for the
# file-access helpers that nothing calls yet.
target_compile_options(cef_host_client PRIVATE /W4 /WX /EHsc /wd4100
  /wd4127 /wd4244 /wd4324 /wd4481 /wd4505 /wd4512 /wd4701 /wd4702 /wd4996)
target_include_directories(cef_host_client PRIVATE
  "${CEF_ROOT}"
  "${CEF_ROOT}/include"
)
# libcef.lib is the import library for libcef.dll, which implements the C API
# the wrapper calls.
target_link_libraries(cef_host_client PRIVATE
  libcef_dll_wrapper
  "${CEF_ROOT}/Release/libcef.lib"
  ${CEF_STANDARD_LIBS}
  advapi32.lib
  shell32.lib
)

# Keep a stable logical target name for release scripts and CI.  The output is
# client.dll because bootstrap.exe loads that exact module name.
add_custom_target(cef_host DEPENDS cef_host_client)

set(CEF_RELEASE_DIR "${CEF_ROOT}/Release")
set(CEF_RESOURCES_DIR "${CEF_ROOT}/Resources")
if(NOT EXISTS "${CEF_RELEASE_DIR}/bootstrap.exe")
  message(FATAL_ERROR "locked CEF Release/bootstrap.exe is missing")
endif()

add_custom_command(TARGET cef_host_client POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "${CEF_RELEASE_DIR}/bootstrap.exe"
    "$<TARGET_FILE_DIR:cef_host_client>/cef_host.exe"
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
    "$<TARGET_FILE:cef_host_client>"
    "$<TARGET_FILE_DIR:cef_host_client>/client.dll"
  COMMENT "Staging the signed CEF bootstrap and roscord client DLL"
  VERBATIM
)

# CEF's standard distribution keeps the Release/Resources split.  Copying the
# runtime at install time preserves that layout and prevents a system CEF lookup.
#
# The Flutter runner's install prefix is $<TARGET_FILE_DIR:commet>, so, like
# the runner's own rules, destinations are absolute paths under it; relative
# ones would resolve against the unexpanded expression.  Only client.dll is
# installed, not its import library, since the payload is allow-listed.
set(CEF_HOST_INSTALL_DIR "${CMAKE_INSTALL_PREFIX}/cef_host")
install(FILES "$<TARGET_FILE:cef_host_client>" DESTINATION "${CEF_HOST_INSTALL_DIR}")
install(FILES "${CEF_RELEASE_DIR}/bootstrap.exe"
  DESTINATION "${CEF_HOST_INSTALL_DIR}" RENAME cef_host.exe)
install(DIRECTORY "${CEF_RELEASE_DIR}/" DESTINATION "${CEF_HOST_INSTALL_DIR}"
  FILES_MATCHING
  PATTERN "*.dll"
  PATTERN "*.exe"
  PATTERN "*.bin"
  PATTERN "*.json"
  PATTERN "*.pak"
  PATTERN "bootstrap.exe" EXCLUDE
)
install(DIRECTORY "${CEF_RESOURCES_DIR}/"
  DESTINATION "${CEF_HOST_INSTALL_DIR}/Resources")
install(FILES
  "${CMAKE_CURRENT_SOURCE_DIR}/README.md"
  "${CMAKE_CURRENT_SOURCE_DIR}/fixture.html"
  DESTINATION "${CEF_HOST_INSTALL_DIR}/fixtures"
)
