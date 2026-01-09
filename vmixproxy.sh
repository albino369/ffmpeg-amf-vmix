#!/bin/bash
################################################################################
# vmixproxy.sh — Build script for vmixproxy
#
# This script compiles ffmpeg_proxy.c (located in the same directory)
# into output/ffmpeg6.exe using MinGW cross-compiler.
#
# Requirements:
# - ffmpeg_proxy.c must exist in the current directory
# - x86_64-w64-mingw32-gcc must be installed
#
# All code and comments are in English by design.
################################################################################

set -e
set -o pipefail

# Paths
WORKDIR="$(pwd)"
SOURCE_FILE="$WORKDIR/ffmpeg_proxy.c"
OUTPUT_DIR="$WORKDIR/output"
OUTPUT_BIN="$OUTPUT_DIR/ffmpeg6.exe"

# Toolchain
TARGET_ARCH=${TARGET_ARCH:-x86_64-w64-mingw32}
CC="${TARGET_ARCH}-gcc"

# Build flags
BUILD_FLAGS=${BUILD_FLAGS:-"-O2 -s"}

# Sanity checks
if [ ! -f "$SOURCE_FILE" ]; then
    echo "[ERROR] ffmpeg_proxy.c not found in current directory"
    exit 1
fi

if ! command -v "$CC" >/dev/null 2>&1; then
    echo "[ERROR] MinGW compiler not found: $CC"
    exit 1
fi

# Prepare output directory
mkdir -p "$OUTPUT_DIR"

echo "[INFO] Compiling vmixproxy..."
echo "[INFO] Source: $SOURCE_FILE"
echo "[INFO] Output: $OUTPUT_BIN"

# Compile
"$CC" $BUILD_FLAGS \
    -o "$OUTPUT_BIN" \
    "$SOURCE_FILE" \
    -static-libgcc

# Verify result
if [ -f "$OUTPUT_BIN" ]; then
    echo "[SUCCESS] Build completed successfully"
    echo "[SUCCESS] Binary generated at: $OUTPUT_BIN"
else
    echo "[ERROR] Build failed: output binary not found"
    exit 1
fi
