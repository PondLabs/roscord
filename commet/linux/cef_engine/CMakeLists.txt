# libroscord_cef_engine.so: the CEF half of the Linux cef_host.
#
# A standalone project so CEF's CMake helpers (which need C and set their own
# compiler flags) stay out of the Flutter runner build; commet/linux builds it
# with ExternalProject when ROSCORD_BUILD_CEF_HOST is on.  CEF_ROOT must point
# at the full locked SDK (headers, libcef_dll wrapper sources, cmake/).
#
# The engine deliberately does not link libcef.so.  The Rust host dlopen()s
# the validated Release/libcef.so with RTLD_GLOBAL first, and the engine's CEF
# symbols bind to that copy, so nothing ever searches for CEF.  That is also
# why CEF's own linker flags (which add `-rpath .`) are not applied.
cmake_minimum_required(VERSION 3.21)
project(roscord_cef_engine C CXX)

if(NOT CEF_ROOT)
  message(FATAL_ERROR "CEF_ROOT must point at the locked CEF SDK")
endif()
if(NOT EXISTS "${CEF_ROOT}/include/cef_app.h")
  message(FATAL_ERROR "CEF_ROOT does not contain the CEF headers: ${CEF_ROOT}")
endif()
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()

# Pin the stable CEF API version for both the wrapper and the engine.  Without
# it CEF's CMake builds the Linux wrapper against the experimental API, which
# is neither forward- nor backward-compatible across CEF releases.  Raise it
# deliberately when the engine starts using newer API.
if(NOT DEFINED api_version)
  set(api_version 15200)
endif()

list(APPEND CMAKE_MODULE_PATH "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)
add_subdirectory("${CEF_LIBCEF_DLL_WRAPPER_PATH}" libcef_dll_wrapper)

set(BROWSER_SURFACE_NATIVE_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../../../browser_surface/native")

add_library(roscord_cef_engine SHARED roscord_cef_engine.cc)
add_dependencies(roscord_cef_engine libcef_dll_wrapper)

# CEF's compile flags and defines, without its linker flags.
target_compile_options(roscord_cef_engine PRIVATE
  ${CEF_COMPILER_FLAGS} ${CEF_CXX_COMPILER_FLAGS}
  $<$<CONFIG:Debug>:${CEF_COMPILER_FLAGS_DEBUG} ${CEF_CXX_COMPILER_FLAGS_DEBUG}>
  $<$<CONFIG:Release>:${CEF_COMPILER_FLAGS_RELEASE} ${CEF_CXX_COMPILER_FLAGS_RELEASE}>)
target_compile_definitions(roscord_cef_engine PRIVATE
  ${CEF_COMPILER_DEFINES}
  $<$<CONFIG:Release>:${CEF_COMPILER_DEFINES_RELEASE}>)
target_include_directories(roscord_cef_engine PRIVATE
  "${CEF_INCLUDE_PATH}"
  "${BROWSER_SURFACE_NATIVE_DIR}")
target_link_options(roscord_cef_engine PRIVATE
  -pthread
  -Wl,-z,noexecstack
  -Wl,-z,now
  -Wl,-z,relro
  -Wl,-O1
  -Wl,--as-needed
  -Wl,--gc-sections)
target_link_libraries(roscord_cef_engine PRIVATE libcef_dll_wrapper rt)
set_target_properties(roscord_cef_engine PROPERTIES
  CXX_VISIBILITY_PRESET hidden
  VISIBILITY_INLINES_HIDDEN ON)

install(TARGETS roscord_cef_engine LIBRARY DESTINATION lib)
