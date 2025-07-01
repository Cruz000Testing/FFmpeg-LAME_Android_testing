#!/bin/bash

# --- Modo de operación ---
# 1. Si recibe parámetro: compila SOLO esa arquitectura
# 2. Sin parámetros: compila todas (para ejecución local)

if [ $# -eq 1 ]; then
    echo "🔧 Modo CI: Compilando arquitectura única $1"
    ARCH_LIST=("$1")
else
    echo "🔧 Modo local: Compilando todas las arquitecturas"
    ARCH_LIST=("arm64-v8a" "armeabi-v7a" "x86" "x86_64")
fi

### Configuration Notes ###
# Android API level and target architectures are now defined in compile.yml
# for GitHub Actions automation. Uncomment and modify below if running locally.

# Default values (match those in compile.yml):
# ANDROID_API_LEVEL="25"
# ARCH_LIST=("armv8a" "armv7a" "x86" "x86-64")

### Essential FFmpeg Build Modules ###
# Minimal configuration for MP3 encoding with metadata support from source files.
ENABLED_CONFIG="\
    --enable-avcodec \
    --enable-avformat \
    --enable-avutil \
    --enable-muxer=mp3 \
    --enable-gpl \
    --enable-encoder=libmp3lame \
    --enable-libmp3lame \
    --enable-demuxer=mov \
    --enable-demuxer=matroska \
    --enable-parser=aac \
    --enable-protocol=file \
    --enable-decoder=mjpeg \
    --enable-decoder=png \
    --enable-bsf=mp3_header \
    --enable-swresample \
    --enable-static"

############### Internal Configuration - Do Not Modify ###############
############### (Automatically set by build system) ###############

## ANDROID_NDK_PATH="/home/a/Desktop/Custom-Files/ffmpeg-compile/ndk/android-ndk-r27c"
## LAME_SOURCE_DIR="/home/a/Desktop/Custom-Files/ffmpeg-compile/lame-3.1.1"
## LAME_BUILD_DIR="/home/a/Desktop/Custom-Files/ffmpeg-compile/lame-build"
## FFMPEG_SOURCE_DIR="/home/a/Desktop/Custom-Files/ffmpeg-compile/ffmpeg-7.1.1"
## FFMPEG_BUILD_DIR="/home/a/Desktop/Custom-Files/ffmpeg-compile/ffmpeg-build"

ANDROID_NDK_PATH=$ANDROID_NDK_HOME
TOOLCHAIN=$ANDROID_NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64
TOOLCHAIN_BIN=$TOOLCHAIN/bin
TOOLCHAIN_SYSROOT=$TOOLCHAIN/sysroot

AR=$TOOLCHAIN_BIN/llvm-ar
NM="$TOOLCHAIN_BIN/llvm-nm"
RANLIB="$TOOLCHAIN_BIN/llvm-ranlib"
STRIP="$TOOLCHAIN_BIN/llvm-strip"

COMMON_CFLAGS="-O3 -fPIC"

arch_template() {
    TARGET_APP=$1
    export TARGET_ARCH=$2
    export TARGET_CPU=$3
    export TARGET_ABI=$4
    ABI_SUFFIX=$5
    export EXTRA_CFLAGS=$6
    export EXTRA_CONFIG=$7
    ARCH_PREFIX=$8
    
    export CLANG_PREFIX="$TARGET_ABI-linux-android$ABI_SUFFIX"
    export CROSS_PREFIX=$TOOLCHAIN_BIN/${CLANG_PREFIX}${ANDROID_API_LEVEL}-
    export CC=${CROSS_PREFIX}clang
    export CXX=${CROSS_PREFIX}clang++
    export COMMON_LDFLAGS=-L$TOOLCHAIN_SYSROOT/usr/lib/$TARGET_ARCH-linux-android/$ANDROID_API_LEVEL
    eval "export PREFIX=\${${TARGET_APP}_BUILD_DIR}/$ANDROID_API_LEVEL/$ARCH_PREFIX"
}

compile_function() {
    export TARGET_APP_SOURCE_DIR="${TARGET_APP}_SOURCE_DIR"
    cd "${!TARGET_APP_SOURCE_DIR}" || { echo "Failed to change directory"; exit 1; }

    eval "CONFIG=\$CONFIGURE_${TARGET_APP}"
    echo "Executing configuration for ${TARGET_APP}"
    eval "$CONFIG" || { echo "Configuration failed"; exit 1; }

    make clean
    make -j$(nproc) || { echo "Build failed"; exit 1; }
    make install || { echo "Installation failed"; exit 1; }
}

FFMPEG_COMMON_EXTRA_CFLAGS="$COMMON_CFLAGS -DANDROID -fdata-sections -ffunction-sections -funwind-tables -fstack-protector-strong -no-canonical-prefixes -D__BIONIC_NO_PAGE_SIZE_MACRO -D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security"
FFMPEG_COMMON_EXTRA_CXXFLAGS=$FFMPEG_COMMON_EXTRA_CFLAGS

read -r -d '' CONFIGURE_FFMPEG << 'EOF'
EXTRA_CXXFLAGS=$EXTRA_CFLAGS
./configure \
    --disable-everything \
    --target-os=android \
    --arch=$TARGET_ARCH \
    --cpu=$TARGET_CPU \
    --enable-cross-compile \
    --cross-prefix="$CROSS_PREFIX" \
    --cc="$CC" \
    --cxx="$CXX" \
    --sysroot="$TOOLCHAIN_SYSROOT" \
    --prefix="$PREFIX" \
    --extra-cflags="$FFMPEG_COMMON_EXTRA_CFLAGS $EXTRA_CFLAGS " \
    --extra-cxxflags="$FFMPEG_COMMON_EXTRA_CXXFLAGS -std=c++17 -fexceptions -frtti $EXTRA_CXXFLAGS " \
    --extra-ldflags=" -Wl,-z,max-page-size=16384 -Wl,--build-id=sha1 -Wl,--no-rosegment -Wl,--no-undefined-version -Wl,--fatal-warnings -Wl,--no-undefined -Qunused-arguments $COMMON_LDFLAGS" \
    --enable-pic \
    ${ENABLED_CONFIG} \
    --ar="$AR" \
    --nm="$NM" \
    --ranlib="$RANLIB" \
    --strip="$STRIP" \
    ${EXTRA_CONFIG}
EOF

for ARCH in "${ARCH_LIST[@]}"; do
    case "$ARCH" in
        "armv8-a"|"aarch64"|"arm64-v8a"|"armv8a")
            template_FFMPEG=("aarch64" "armv8-a" "aarch64" "" " -march=armv8-a -mcpu=cortex-a75" "--enable-neon --enable-asm" "arm64-v8a") ;;
            
        "armv7-a"|"armeabi-v7a"|"armv7a")
            template_FFMPEG=("arm" "armv7-a" "armv7a" "eabi" " -march=armv7-a -mfpu=neon -mfloat-abi=softfp" "--enable-neon --disable-armv5te" "armeabi-v7a") ;;
            
        "x86-64"|"x86_64")
            template_FFMPEG=("x86_64" "x86-64" "x86_64" "" " -march=x86-64 -msse4.2 -mpopcnt" "" "x86_64") ;;
            
        "x86"|"i686")
            template_FFMPEG=("i686" "i686" "i686" "" " -march=core2 -msse3" "--disable-asm" "x86") ;;
            
        * )
            echo "Unknown architecture: $ARCH"
            exit 1 ;;
    esac
    arch_template "FFMPEG" "${template_FFMPEG[@]}"
    compile_function
done
