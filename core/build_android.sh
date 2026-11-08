#!/bin/zsh
# Build the Rust core for Android arm64 and drop it into the Flutter app's jniLibs.
set -e
cd "$(dirname "$0")"
# Set ANDROID_NDK_HOME, or have NDK 28.2.13676358 in the default SDK folder.
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
NDK="${ANDROID_NDK_HOME:-$SDK/ndk/28.2.13676358}"
HOST="$(uname -s | tr "[:upper:]" "[:lower:]")-x86_64"
BIN="$NDK/toolchains/llvm/prebuilt/$HOST/bin"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$BIN/aarch64-linux-android24-clang"
export CC_aarch64_linux_android="$BIN/aarch64-linux-android24-clang"
export AR_aarch64_linux_android="$BIN/llvm-ar"
cargo build --release --target aarch64-linux-android
OUT=../app/android/app/src/main/jniLibs/arm64-v8a
mkdir -p "$OUT"
cp target/aarch64-linux-android/release/libcp_core.so "$OUT/"
ls -la "$OUT/libcp_core.so"
