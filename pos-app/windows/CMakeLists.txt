# Project-level configuration.
cmake_minimum_required(VERSION 3.14)
project(optomstroy LANGUAGES CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "optomstroy")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# Define build configuration option.
get_property(IS_MULTICONFIG GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
if(IS_MULTICONFIG)
  set(CMAKE_CONFIGURATION_TYPES "Debug;Profile;Release"
    CACHE STRING "" FORCE)
else()
  if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE "Debug" CACHE
      STRING "Flutter build mode" FORCE)
    set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
      "Debug" "Profile" "Release")
  endif()
endif()
# Define settings for the Profile build mode.
set(CMAKE_EXE_LINKER_FLAGS_PROFILE "${CMAKE_EXE_LINKER_FLAGS_RELEASE}")
set(CMAKE_SHARED_LINKER_FLAGS_PROFILE "${CMAKE_SHARED_LINKER_FLAGS_RELEASE}")
set(CMAKE_C_FLAGS_PROFILE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_CXX_FLAGS_PROFILE "${CMAKE_CXX_FLAGS_RELEASE}")

# Use Unicode for all projects.
add_definitions(-DUNICODE -D_UNICODE)

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_17)
  target_compile_options(${TARGET} PRIVATE /W4 /WX /wd"4100")
  target_compile_options(${TARGET} PRIVATE /EHsc)
  target_compile_definitions(${TARGET} PRIVATE "_HAS_EXCEPTIONS=0")
  target_compile_definitions(${TARGET} PRIVATE "$<$<CONFIG:Debug>:_DEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")


# === Offline third-party archives (16 section 10.7 "Windows build and PDFium", 12 T-BUILD-005) ===
# In a clean build/windows two plugins fetch archives from the internet while CMake configures:
#   - printing 5.14.3: PDFium binaries, pdfium-win-<arch>.tgz from github.com/bblanchon/pdfium-binaries
#     (chromium/<PDFIUM_VERSION>, 5200). PDFIUM_URL is a normal variable there, so a -DPDFIUM_URL cache entry is
#     shadowed and the plugin has no cache folder of its own;
#   - sqlite3_flutter_libs: the SQLite amalgamation sqlite-autoconf-<version>.tar.gz from sqlite.org
#     (FetchContent with a literal URL).
# When the environment variables below name local copies of exactly those archives, configure takes them from
# disk and needs no network; without the variables the plugins behave as before. scripts/package_windows.ps1
# keeps the copies in its cache and sets the variables.
#   OPTOMSTROY_PDFIUM_ARCHIVE, OPTOMSTROY_SQLITE_ARCHIVE  absolute paths, file names as in the plugins' URLs
#   OPTOMSTROY_PDFIUM_SHA256,  OPTOMSTROY_SQLITE_SHA256   optional expected SHA-256; a mismatch stops configure
function(optomstroy_local_archive OUT_VAR ENV_NAME SHA_ENV_NAME)
  set(${OUT_VAR} "" PARENT_SCOPE)
  if("$ENV{${ENV_NAME}}" STREQUAL "")
    return()
  endif()
  file(TO_CMAKE_PATH "$ENV{${ENV_NAME}}" archive)
  if(NOT IS_ABSOLUTE "${archive}" OR NOT EXISTS "${archive}" OR IS_DIRECTORY "${archive}")
    message(FATAL_ERROR "${ENV_NAME}: not an absolute path to an existing archive file: '${archive}'")
  endif()
  # printing's download helper writes the URL unquoted into a generated CMakeLists.txt.
  if(archive MATCHES "[ ;\"]")
    message(FATAL_ERROR "${ENV_NAME}: the path must not contain spaces, semicolons or quotes: '${archive}'")
  endif()
  if(NOT "$ENV{${SHA_ENV_NAME}}" STREQUAL "")
    file(SHA256 "${archive}" actual)
    string(TOLOWER "$ENV{${SHA_ENV_NAME}}" expected)
    if(NOT actual STREQUAL expected)
      message(FATAL_ERROR "${ENV_NAME}: SHA-256 of '${archive}' is ${actual}, ${SHA_ENV_NAME} expects ${expected}")
    endif()
  endif()
  set(${OUT_VAR} "${archive}" PARENT_SCOPE)
endfunction()

optomstroy_local_archive(OPTOMSTROY_PDFIUM_ARCHIVE OPTOMSTROY_PDFIUM_ARCHIVE OPTOMSTROY_PDFIUM_SHA256)
if(OPTOMSTROY_PDFIUM_ARCHIVE)
  # variable_watch runs the macro in the plugin's scope right after its set(PDFIUM_URL ...); CMake does not re-enter
  # a watch callback, so the set() below is final. Only the file name is compared: the version folder of the cache
  # (chromium-<PDFIUM_VERSION>) is checked by scripts/package_windows.ps1.
  macro(optomstroy_pdfium_url_override watched_var access value)
    if("${access}" STREQUAL "MODIFIED_ACCESS" AND NOT "${value}" STREQUAL "${OPTOMSTROY_PDFIUM_ARCHIVE}")
      get_filename_component(_optomstroy_wanted "${value}" NAME)
      get_filename_component(_optomstroy_local "${OPTOMSTROY_PDFIUM_ARCHIVE}" NAME)
      if(NOT _optomstroy_wanted STREQUAL _optomstroy_local)
        message(FATAL_ERROR "OPTOMSTROY_PDFIUM_ARCHIVE: the plugin wants ${_optomstroy_wanted} (${value}), "
          "the local archive is ${_optomstroy_local}")
      endif()
      set(${watched_var} "${OPTOMSTROY_PDFIUM_ARCHIVE}")
      message(STATUS "PDFium: local archive ${OPTOMSTROY_PDFIUM_ARCHIVE} instead of ${value}")
    endif()
  endmacro()
  variable_watch(PDFIUM_URL optomstroy_pdfium_url_override)
endif()

optomstroy_local_archive(OPTOMSTROY_SQLITE_ARCHIVE OPTOMSTROY_SQLITE_ARCHIVE OPTOMSTROY_SQLITE_SHA256)
if(OPTOMSTROY_SQLITE_ARCHIVE)
  set(_optomstroy_sqlite_plugin
    "${FLUTTER_MANAGED_DIR}/ephemeral/.plugin_symlinks/sqlite3_flutter_libs/windows/CMakeLists.txt")
  if(NOT EXISTS "${_optomstroy_sqlite_plugin}")
    message(FATAL_ERROR "OPTOMSTROY_SQLITE_ARCHIVE is set, but ${_optomstroy_sqlite_plugin} is missing")
  endif()
  file(STRINGS "${_optomstroy_sqlite_plugin}" _optomstroy_sqlite_urls REGEX "^[ \t]*URL[ \t]+[^ \t]+")
  list(GET _optomstroy_sqlite_urls 0 _optomstroy_sqlite_url)
  string(REGEX REPLACE "^[ \t]*URL[ \t]+([^ \t]+).*$" "\\1" _optomstroy_sqlite_url "${_optomstroy_sqlite_url}")
  get_filename_component(_optomstroy_wanted "${_optomstroy_sqlite_url}" NAME)
  get_filename_component(_optomstroy_local "${OPTOMSTROY_SQLITE_ARCHIVE}" NAME)
  if(NOT _optomstroy_wanted STREQUAL _optomstroy_local)
    message(FATAL_ERROR "OPTOMSTROY_SQLITE_ARCHIVE: the plugin wants ${_optomstroy_wanted} "
      "(${_optomstroy_sqlite_url}), the local archive is ${_optomstroy_local}")
  endif()
  # FetchContent keeps the first declaration of a name ("first to record wins"); the plugin's own
  # FetchContent_Declare(sqlite3 ...) is then ignored and its FetchContent_MakeAvailable(sqlite3) uses this one.
  include(FetchContent)
  if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.24.0")
    FetchContent_Declare(sqlite3 URL "${OPTOMSTROY_SQLITE_ARCHIVE}" DOWNLOAD_EXTRACT_TIMESTAMP NEW)
  else()
    FetchContent_Declare(sqlite3 URL "${OPTOMSTROY_SQLITE_ARCHIVE}")
  endif()
  message(STATUS "SQLite: local archive ${OPTOMSTROY_SQLITE_ARCHIVE} instead of ${_optomstroy_sqlite_url}")
endif()

# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# Support files are copied into place next to the executable, so that it can
# run in place. This is done instead of making a separate bundle (as on Linux)
# so that building and running from within Visual Studio will work.
set(BUILD_BUNDLE_DIR "$<TARGET_FILE_DIR:${BINARY_NAME}>")
# Make the "install" step default, as it's required to run.
set(CMAKE_VS_INCLUDE_INSTALL_TO_DEFAULT_BUILD 1)
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

if(PLUGIN_BUNDLED_LIBRARIES)
  install(FILES "${PLUGIN_BUNDLED_LIBRARIES}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()

# Visual C++ runtime next to the exe, Profile/Release only (16 section 10.7 step 6, 13 RM-H-007, 12 T-BUILD-005).
# The runner, the plugin DLLs, rive_native.dll and sqlite3.dll use the dynamic CRT (/MD). `dumpbin /dependents` over
# the bundle (2026-11-19) finds exactly these three VC runtime DLLs; the UCRT (api-ms-win-crt-*, ucrtbase.dll) is
# part of Windows 10/11 and is not copied. The files come from the VC Redist folder of the Visual Studio that builds
# (VC/Redist/MSVC/<version>/x64/Microsoft.VC143.CRT), which Microsoft allows to deploy app-locally. Debug builds use
# the debug CRT of the developer's Visual Studio and get nothing. scripts/package_windows.ps1 re-reads the imports of
# every bundled PE file and stops if a VC runtime DLL is missing, so a new dependency shows up when packaging.
set(OPTOMSTROY_VC_RUNTIME_DLLS msvcp140.dll vcruntime140.dll vcruntime140_1.dll)
set(CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS_SKIP TRUE)
set(CMAKE_INSTALL_UCRT_LIBRARIES FALSE)
set(CMAKE_INSTALL_DEBUG_LIBRARIES FALSE)
include(InstallRequiredSystemLibraries)
set(OPTOMSTROY_VC_RUNTIME_FILES "")
foreach(_optomstroy_dll IN LISTS OPTOMSTROY_VC_RUNTIME_DLLS)
  set(_optomstroy_found "")
  foreach(_optomstroy_path IN LISTS CMAKE_INSTALL_SYSTEM_RUNTIME_LIBS)
    get_filename_component(_optomstroy_name "${_optomstroy_path}" NAME)
    string(TOLOWER "${_optomstroy_name}" _optomstroy_name)
    if(_optomstroy_name STREQUAL _optomstroy_dll AND EXISTS "${_optomstroy_path}")
      set(_optomstroy_found "${_optomstroy_path}")
    endif()
  endforeach()
  if(_optomstroy_found)
    list(APPEND OPTOMSTROY_VC_RUNTIME_FILES "${_optomstroy_found}")
  else()
    message(WARNING "Visual C++ runtime: ${_optomstroy_dll} is not in the VC Redist folder "
      "(MSVC_REDIST_DIR='${MSVC_REDIST_DIR}'); the Profile/Release bundle will lack it")
  endif()
endforeach()
if(OPTOMSTROY_VC_RUNTIME_FILES)
  install(FILES ${OPTOMSTROY_VC_RUNTIME_FILES} DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    CONFIGURATIONS Profile;Release
    COMPONENT Runtime)
endif()

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/windows/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
# Debug runs Dart in JIT mode from kernel_blob.bin. Profile/Release run AOT code from app.so; a kernel_blob.bin left in
# build/flutter_assets by an earlier debug build or `flutter test -d windows` (the whole program as Dart kernel,
# +121 MB) is not copied into their bundle (12 T-BUILD-005, 13 RM-H-007 criterion 5).
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Debug
  COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime
  PATTERN "kernel_blob.bin" EXCLUDE)

# Install the AOT library on non-Debug builds only.
install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  CONFIGURATIONS Profile;Release
  COMPONENT Runtime)
