# Project-level configuration.
cmake_minimum_required(VERSION 3.10)
project(runner LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "commet")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID

if ($ENV{COMMET_PROD} MATCHES "1")
  set(APPLICATION_ID "chat.commet.commetapp")
  message("Building in PRODUCTION mode")
else()
  set(APPLICATION_ID "chat.commet.commetapp.develop")
  message("Building in DEVELOP mode")
endif()

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)
pkg_check_modules(DBUS REQUIRED dbus-1)

add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Define the application target. To change its name, change BINARY_NAME above,
# not the value here, or `flutter run` will no longer work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)
target_link_libraries(${BINARY_NAME} PRIVATE ${DBUS_LIBRARIES})

# for dbus
target_include_directories(${BINARY_NAME} PRIVATE ${DBUS_INCLUDE_DIRS})

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)

target_link_libraries(${BINARY_NAME} PRIVATE ${MIMALLOC_LIB})

# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

# The Flutter project root. flutter/CMakeLists.txt gets PROJECT_DIR from the
# generated config, but only in its own scope.
set(PROJECT_DIR "${CMAKE_CURRENT_SOURCE_DIR}/..")

# Linux CEF is a separate process: the Rust cef_host (transport, policy,
# profiles) and libroscord_cef_engine.so (the CEF half, on the CEF C++
# wrapper).  cef_host is installed beside the Flutter executable and the
# engine in lib/, so native packages and Flatpak share one host topology.  The
# host requires an explicit staged CEF root at launch; it never searches the
# system for libcef.so.
#
# Opt-in, like the Windows host: only a job that has staged the locked CEF
# inputs builds it.  The Flutter tool passes no -D options, so the switch, the
# SDK and the staged runtime below also come from the environment.
option(ROSCORD_BUILD_CEF_HOST "Build and bundle the Linux CEF host" OFF)
if("$ENV{ROSCORD_BUILD_CEF_HOST}" STREQUAL "ON")
  set(ROSCORD_BUILD_CEF_HOST ON)
endif()
set(ROSCORD_CEF_SDK_ROOT "" CACHE PATH "Full CEF SDK used to build the CEF engine")
if(NOT ROSCORD_CEF_SDK_ROOT AND DEFINED ENV{ROSCORD_CEF_SDK_ROOT})
  set(ROSCORD_CEF_SDK_ROOT "$ENV{ROSCORD_CEF_SDK_ROOT}" CACHE PATH
    "Full CEF SDK used to build the CEF engine" FORCE)
endif()
if(ROSCORD_BUILD_CEF_HOST)
  if(NOT ROSCORD_CEF_SDK_ROOT)
    message(FATAL_ERROR
      "ROSCORD_CEF_SDK_ROOT is required when ROSCORD_BUILD_CEF_HOST is enabled")
  endif()
  find_program(CARGO_EXECUTABLE cargo)
  if(NOT CARGO_EXECUTABLE)
    message(FATAL_ERROR "cargo is required to build cef_host")
  endif()
  set(CEF_HOST_TARGET_DIR "${PROJECT_BINARY_DIR}/cef-host-target")
  set(CEF_HOST_BINARY "${CEF_HOST_TARGET_DIR}/release/cef_host")
  file(GLOB CEF_HOST_SOURCES CONFIGURE_DEPENDS
    "${PROJECT_DIR}/../rust/rust/src/*.rs"
    "${PROJECT_DIR}/../rust/rust/src/bin/*.rs")
  add_custom_command(
    OUTPUT "${CEF_HOST_BINARY}"
    COMMAND ${CMAKE_COMMAND} -E env
      "CARGO_TARGET_DIR=${CEF_HOST_TARGET_DIR}"
      "${CARGO_EXECUTABLE}" build --release --bin cef_host
      --manifest-path "${PROJECT_DIR}/../rust/rust/Cargo.toml"
    WORKING_DIRECTORY "${PROJECT_DIR}/.."
    DEPENDS
      "${PROJECT_DIR}/../Cargo.toml"
      "${PROJECT_DIR}/../Cargo.lock"
      "${PROJECT_DIR}/../rust/rust/Cargo.toml"
      "${PROJECT_DIR}/../rust/rust/build.rs"
      ${CEF_HOST_SOURCES}
    VERBATIM
  )
  add_custom_target(cef_host_build ALL DEPENDS "${CEF_HOST_BINARY}")
  add_dependencies(${BINARY_NAME} cef_host_build)
  install(PROGRAMS "${CEF_HOST_BINARY}" DESTINATION "${CMAKE_INSTALL_PREFIX}")

  # The engine is its own CMake project: CEF's CMake helpers need C and set
  # their own compiler flags, which stay out of the Flutter build this way.
  include(ExternalProject)
  set(CEF_ENGINE_BINARY_DIR "${PROJECT_BINARY_DIR}/cef-engine")
  set(CEF_ENGINE_LIBRARY "${CEF_ENGINE_BINARY_DIR}/libroscord_cef_engine.so")
  ExternalProject_Add(cef_engine
    SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/cef_engine"
    BINARY_DIR "${CEF_ENGINE_BINARY_DIR}"
    CMAKE_ARGS
      "-DCEF_ROOT=${ROSCORD_CEF_SDK_ROOT}"
      "-DCMAKE_BUILD_TYPE=Release"
    INSTALL_COMMAND ""
    BUILD_ALWAYS ON
    BUILD_BYPRODUCTS "${CEF_ENGINE_LIBRARY}"
  )
  add_dependencies(${BINARY_NAME} cef_engine)
  install(FILES "${CEF_ENGINE_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
endif()

# Release packaging points this at the output of
# `tools/cef_runtime.py stage --platform linux-x64 --strip`, which keeps every
# file CEF loads in Release/ next to libcef.so.  Leaving it unset is safe:
# cef_host refuses to start without the explicit runtime and the app falls
# back to its native player or the browser instead.
set(ROSCORD_CEF_RUNTIME_DIR "" CACHE PATH "Staged locked Linux CEF runtime")
if(NOT ROSCORD_CEF_RUNTIME_DIR AND DEFINED ENV{ROSCORD_CEF_RUNTIME_DIR})
  set(ROSCORD_CEF_RUNTIME_DIR "$ENV{ROSCORD_CEF_RUNTIME_DIR}" CACHE PATH
    "Staged locked Linux CEF runtime" FORCE)
endif()
if(ROSCORD_CEF_RUNTIME_DIR)
  if(NOT EXISTS "${ROSCORD_CEF_RUNTIME_DIR}/Release/libcef.so" OR
     NOT EXISTS "${ROSCORD_CEF_RUNTIME_DIR}/Release/icudtl.dat")
    message(FATAL_ERROR
      "ROSCORD_CEF_RUNTIME_DIR is not a staged Linux CEF runtime "
      "(Release/ must hold libcef.so and everything it loads)")
  endif()
  install(DIRECTORY "${ROSCORD_CEF_RUNTIME_DIR}/"
    DESTINATION "${CMAKE_INSTALL_PREFIX}/cef"
    USE_SOURCE_PERMISSIONS)
endif()

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
