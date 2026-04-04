# WebKit Android aarch64 cross-compilation CMake toolchain
#
# Uses CMAKE_SYSTEM_NAME=Linux (not Android) because WebKit's CMake system
# has no Android support - it detects Android via __ANDROID__ at the C/C++
# preprocessor level, which the NDK compiler defines automatically.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

# Android NDK paths
if(NOT DEFINED ANDROID_NDK_HOME)
    set(ANDROID_NDK_HOME "/home/guy/Android/Sdk/ndk/28.1.13356709")
endif()
set(ANDROID_API 24)
set(ANDROID_TRIPLE "aarch64-linux-android")
set(ANDROID_TRIPLE_API "${ANDROID_TRIPLE}${ANDROID_API}")

set(NDK_TOOLCHAIN "${ANDROID_NDK_HOME}/toolchains/llvm/prebuilt/linux-x86_64")
set(NDK_SYSROOT "${NDK_TOOLCHAIN}/sysroot")

# Compilers
set(CMAKE_C_COMPILER "${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang")
set(CMAKE_CXX_COMPILER "${NDK_TOOLCHAIN}/bin/${ANDROID_TRIPLE_API}-clang++")
set(CMAKE_AR "${NDK_TOOLCHAIN}/bin/llvm-ar" CACHE FILEPATH "Archiver")
set(CMAKE_RANLIB "${NDK_TOOLCHAIN}/bin/llvm-ranlib" CACHE FILEPATH "Ranlib")
set(CMAKE_STRIP "${NDK_TOOLCHAIN}/bin/llvm-strip" CACHE FILEPATH "Strip")
set(CMAKE_NM "${NDK_TOOLCHAIN}/bin/llvm-nm" CACHE FILEPATH "NM")
set(CMAKE_LINKER "${NDK_TOOLCHAIN}/bin/ld.lld" CACHE FILEPATH "Linker")

# Sysroot
set(CMAKE_SYSROOT "${NDK_SYSROOT}")

# Add our custom ICU/deps prefix to the search path
set(DEPS_PREFIX "/home/guy/opencode-termux/deps-android/prefix")
set(CMAKE_FIND_ROOT_PATH "${DEPS_PREFIX}" "${NDK_SYSROOT}")
set(CMAKE_PREFIX_PATH "${DEPS_PREFIX}")

# Explicitly set ICU paths to prevent FindICU from picking up NDK sysroot headers
# and then failing to find libraries. We cross-compiled ICU 75.1 for Android.
set(ICU_ROOT "${DEPS_PREFIX}" CACHE PATH "ICU root directory")
set(ICU_INCLUDE_DIR "${DEPS_PREFIX}/include" CACHE PATH "ICU include directory")
set(ICU_INCLUDE_DIRS "${DEPS_PREFIX}/include" CACHE PATH "ICU include directories")
set(ICU_UC_LIBRARY "${DEPS_PREFIX}/lib/libicuuc.a" CACHE FILEPATH "ICU UC library")
set(ICU_UC_LIBRARY_RELEASE "${DEPS_PREFIX}/lib/libicuuc.a" CACHE FILEPATH "ICU UC library (release)")
set(ICU_I18N_LIBRARY "${DEPS_PREFIX}/lib/libicui18n.a" CACHE FILEPATH "ICU I18N library")
set(ICU_I18N_LIBRARY_RELEASE "${DEPS_PREFIX}/lib/libicui18n.a" CACHE FILEPATH "ICU I18N library (release)")
set(ICU_DATA_LIBRARY "${DEPS_PREFIX}/lib/libicudata.a" CACHE FILEPATH "ICU Data library")
set(ICU_DATA_LIBRARY_RELEASE "${DEPS_PREFIX}/lib/libicudata.a" CACHE FILEPATH "ICU Data library (release)")
set(ICU_LIBRARIES "${DEPS_PREFIX}/lib/libicui18n.a;${DEPS_PREFIX}/lib/libicuuc.a;${DEPS_PREFIX}/lib/libicudata.a" CACHE STRING "ICU libraries")
set(ICU_FOUND TRUE CACHE BOOL "ICU found")
set(ICU_VERSION "75.1" CACHE STRING "ICU version")

# Search paths - search target sysroot and our deps prefix
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE BOTH)

# Cross-compilation
set(CMAKE_CROSSCOMPILING TRUE)

# Skip compiler checks (we know the NDK compiler works)
set(CMAKE_C_COMPILER_WORKS ON)
set(CMAKE_CXX_COMPILER_WORKS ON)

# Use LLD linker
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")

# PIC is required for Android
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
