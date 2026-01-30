#!/bin/bash
# Unified Lexicon Mobile APK Build Script
# Builds lexicon-flutter Rust library + Flutter APK in one command
#
# Usage: ./build_mobile_apk.sh [target]
#   Targets: arm64, x86_64 (default), arm32, all

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(dirname "$SCRIPT_DIR")"
LOCAL_SERVER_DIR="$SUITE_ROOT/Lexicon-Local-Server"
MOBILE_DIR="$SUITE_ROOT/Lexicon-Mobile"

# Android NDK Configuration
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/Android/Sdk/ndk/29.0.14206865}"
ANDROID_API="${ANDROID_API:-26}"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"

# Build Configuration
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-4}"
BUILD_TYPE="${BUILD_TYPE:-release}"

# Model Configuration
WHISPER_MODEL_ID="base-q5_1"
WHISPER_MODEL_NAME="ggml-base-q5_1.bin"
LEXICON_CLI="$LOCAL_SERVER_DIR/target/release/lexicon"
LEXICON_MODEL_DIR="$HOME/.local/share/lexiconlocalserver/models"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header() {
    echo ""
    echo "=============================================="
    echo " $1"
    echo "=============================================="
    echo ""
}

# =============================================================================
# Model Management Functions
# =============================================================================

ensure_lexicon_cli() {
    if [ -x "$LEXICON_CLI" ]; then
        log_success "Lexicon CLI found: $LEXICON_CLI"
        return 0
    fi

    log_info "Lexicon CLI not found, building..."

    if [ ! -f "$LOCAL_SERVER_DIR/scripts/build.sh" ]; then
        log_error "Build script not found: $LOCAL_SERVER_DIR/scripts/build.sh"
        return 1
    fi

    (
        cd "$LOCAL_SERVER_DIR"
        ./scripts/build.sh
    )

    if [ -x "$LEXICON_CLI" ]; then
        log_success "Lexicon CLI built successfully"
        return 0
    else
        log_error "Failed to build Lexicon CLI"
        return 1
    fi
}

ensure_whisper_model() {
    local MOBILE_MODEL_DIR="$MOBILE_DIR/assets/models"
    local MOBILE_MODEL_FILE="$MOBILE_MODEL_DIR/$WHISPER_MODEL_NAME"

    print_header "Ensuring Whisper Model"

    # Check if model already exists in mobile assets
    if [ -f "$MOBILE_MODEL_FILE" ]; then
        local SIZE=$(ls -lh "$MOBILE_MODEL_FILE" | awk '{print $5}')
        log_success "Model already exists: $MOBILE_MODEL_FILE ($SIZE)"
        return 0
    fi

    # Check if model exists in Lexicon-Local-Server/models/ (bundled)
    local SERVER_MODEL_FILE="$LOCAL_SERVER_DIR/models/$WHISPER_MODEL_NAME"
    if [ -f "$SERVER_MODEL_FILE" ]; then
        log_info "Found model in Lexicon-Local-Server/models/, copying..."
        mkdir -p "$MOBILE_MODEL_DIR"
        cp "$SERVER_MODEL_FILE" "$MOBILE_MODEL_FILE"
        local SIZE=$(ls -lh "$MOBILE_MODEL_FILE" | awk '{print $5}')
        log_success "Copied model to mobile assets ($SIZE)"
        return 0
    fi

    # Check if model exists in lexicon cache
    local CACHE_MODEL_FILE="$LEXICON_MODEL_DIR/$WHISPER_MODEL_NAME"
    if [ -f "$CACHE_MODEL_FILE" ]; then
        log_info "Found model in lexicon cache, copying..."
        mkdir -p "$MOBILE_MODEL_DIR"
        cp "$CACHE_MODEL_FILE" "$MOBILE_MODEL_FILE"
        local SIZE=$(ls -lh "$MOBILE_MODEL_FILE" | awk '{print $5}')
        log_success "Copied model from cache ($SIZE)"
        return 0
    fi

    # Need to download via lexicon CLI
    log_info "Model not found locally, downloading via lexicon CLI..."

    # Ensure lexicon CLI exists
    if ! ensure_lexicon_cli; then
        log_error "Cannot download model: lexicon CLI unavailable"
        return 1
    fi

    # Download the model
    log_info "Downloading model: $WHISPER_MODEL_ID"
    if ! "$LEXICON_CLI" models download "$WHISPER_MODEL_ID"; then
        log_error "Failed to download model"
        return 1
    fi

    # Copy from cache to mobile assets
    if [ -f "$CACHE_MODEL_FILE" ]; then
        mkdir -p "$MOBILE_MODEL_DIR"
        cp "$CACHE_MODEL_FILE" "$MOBILE_MODEL_FILE"
        local SIZE=$(ls -lh "$MOBILE_MODEL_FILE" | awk '{print $5}')
        log_success "Model downloaded and copied to mobile assets ($SIZE)"
        return 0
    else
        log_error "Model download succeeded but file not found at expected location"
        log_error "Expected: $CACHE_MODEL_FILE"
        return 1
    fi
}

# =============================================================================
# Prerequisite Checks
# =============================================================================

check_prerequisites() {
    print_header "Checking Prerequisites"

    local missing=0

    # Check Android NDK
    if [ ! -d "$ANDROID_NDK_HOME" ]; then
        log_error "Android NDK not found at $ANDROID_NDK_HOME"
        log_info "Set ANDROID_NDK_HOME environment variable or install NDK r29+"
        missing=1
    else
        log_success "Android NDK found: $ANDROID_NDK_HOME"
    fi

    # Check Rust
    if ! command -v cargo &> /dev/null; then
        log_error "Rust/Cargo not found. Install from https://rustup.rs"
        missing=1
    else
        log_success "Rust found: $(rustc --version)"
    fi

    # Check Flutter
    if ! command -v flutter &> /dev/null; then
        log_error "Flutter not found. Install from https://flutter.dev"
        missing=1
    else
        log_success "Flutter found: $(flutter --version | head -1)"
    fi

    # Check adb (optional, for deployment)
    if ! command -v adb &> /dev/null; then
        log_warn "adb not found. Device deployment will be skipped."
    else
        log_success "adb found: $(adb version | head -1)"
    fi

    # Check project directories
    if [ ! -d "$LOCAL_SERVER_DIR" ]; then
        log_error "Lexicon-Local-Server not found at $LOCAL_SERVER_DIR"
        missing=1
    else
        log_success "Lexicon-Local-Server found"
    fi

    if [ ! -d "$MOBILE_DIR" ]; then
        log_error "Lexicon-Mobile not found at $MOBILE_DIR"
        missing=1
    else
        log_success "Lexicon-Mobile found"
    fi

    # Check assets (informational - model will be downloaded if missing)
    local MODEL_FILE="$MOBILE_DIR/assets/models/$WHISPER_MODEL_NAME"
    if [ ! -f "$MODEL_FILE" ]; then
        log_info "Whisper model not found (will be downloaded automatically)"
    else
        local MODEL_SIZE=$(ls -lh "$MODEL_FILE" | awk '{print $5}')
        log_success "Whisper model found: $WHISPER_MODEL_NAME ($MODEL_SIZE)"
    fi

    local TEST_AUDIO="$MOBILE_DIR/assets/audio/woodchuck.wav"
    if [ ! -f "$TEST_AUDIO" ]; then
        log_warn "Test audio not found at $TEST_AUDIO (optional)"
    else
        local AUDIO_SIZE=$(ls -lh "$TEST_AUDIO" | awk '{print $5}')
        log_success "Test audio found: woodchuck.wav ($AUDIO_SIZE)"
    fi

    # Check Rust targets
    local rust_targets=$(rustup target list --installed)
    for target in aarch64-linux-android x86_64-linux-android armv7-linux-androideabi; do
        if echo "$rust_targets" | grep -q "$target"; then
            log_success "Rust target installed: $target"
        else
            log_warn "Rust target missing: $target"
            log_info "Install with: rustup target add $target"
        fi
    done

    if [ $missing -eq 1 ]; then
        log_error "Prerequisites check failed. Please fix the issues above."
        exit 1
    fi

    echo ""
    log_success "All prerequisites satisfied!"
}

# =============================================================================
# Rust Build Functions
# =============================================================================

build_rust_target() {
    local TARGET=$1
    local CC_VAR=$2
    local CC_BIN=$3
    local FEATURES=${4:-"default"}
    local ABI=$5

    log_info "Building lexicon-flutter for $TARGET (features: $FEATURES)"

    # Run cargo build in a subshell to isolate environment changes
    (
        export CC_${CC_VAR}="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang"
        export CXX_${CC_VAR}="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang++"
        export AR_${CC_VAR}="$TOOLCHAIN/llvm-ar"
        # Configure the Rust linker for this target (uppercase with underscores for Cargo env vars)
        CARGO_TARGET_VAR="CARGO_TARGET_$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')_LINKER"
        export "${CARGO_TARGET_VAR}"="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang"
        export ANDROID_NDK_HOME
        # Don't use CMAKE_TOOLCHAIN_FILE - let cmake-rs handle Android cross-compilation
        # Set the required CMake variables directly for Android cross-compilation
        export ANDROID_ABI="$ABI"
        export ANDROID_PLATFORM="android-${ANDROID_API}"
        export ANDROID_NDK="$ANDROID_NDK_HOME"
        # cmake-rs uses these for Android detection
        export CMAKE_ANDROID_NDK="$ANDROID_NDK_HOME"
        export CMAKE_ANDROID_ARCH_ABI="$ABI"
        export CMAKE_SYSTEM_NAME="Android"
        export CMAKE_SYSTEM_VERSION="${ANDROID_API}"
        export CARGO_BUILD_JOBS

        cd "$LOCAL_SERVER_DIR"

        if [ "$FEATURES" = "default" ]; then
            cargo build -p lexicon-flutter --target "$TARGET" --release
        else
            cargo build -p lexicon-flutter --target "$TARGET" --release --no-default-features --features "$FEATURES"
        fi
    )

    # Verify output
    local OUTPUT="$LOCAL_SERVER_DIR/target/$TARGET/release/liblexicon_flutter.so"
    if [ -f "$OUTPUT" ]; then
        local SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
        log_success "Built: $OUTPUT ($SIZE)"
    else
        log_error "Build failed: $OUTPUT not found"
        exit 1
    fi
}

build_rust_libraries() {
    local TARGETS=$1

    print_header "Building Rust Libraries"

    case "$TARGETS" in
        arm64)
            build_rust_target "aarch64-linux-android" "aarch64_linux_android" "aarch64-linux-android" "default" "arm64-v8a"
            ;;
        x86_64)
            build_rust_target "x86_64-linux-android" "x86_64_linux_android" "x86_64-linux-android" "stt" "x86_64"
            log_warn "TTS disabled for x86_64 (ONNX Runtime not available)"
            ;;
        arm32)
            build_rust_target "armv7-linux-androideabi" "armv7_linux_androideabi" "armv7a-linux-androideabi" "stt" "armeabi-v7a"
            ;;
        all)
            build_rust_target "aarch64-linux-android" "aarch64_linux_android" "aarch64-linux-android" "default" "arm64-v8a"
            build_rust_target "x86_64-linux-android" "x86_64_linux_android" "x86_64-linux-android" "stt" "x86_64"
            build_rust_target "armv7-linux-androideabi" "armv7_linux_androideabi" "armv7a-linux-androideabi" "stt" "armeabi-v7a"
            ;;
    esac

    log_success "Rust library build complete!"
}

# =============================================================================
# Library Copy Functions
# =============================================================================

copy_library() {
    local RUST_TARGET=$1
    local ABI=$2
    local NDK_ARCH=$3

    local JNILIBS_DIR="$MOBILE_DIR/android/app/src/main/jniLibs/$ABI"
    mkdir -p "$JNILIBS_DIR"

    # Copy lexicon-flutter library
    local SRC="$LOCAL_SERVER_DIR/target/$RUST_TARGET/release/liblexicon_flutter.so"
    if [ -f "$SRC" ]; then
        cp "$SRC" "$JNILIBS_DIR/"
        log_success "Copied liblexicon_flutter.so -> jniLibs/$ABI/"
    else
        log_warn "Library not found: $SRC"
        return 1
    fi

    # Copy libc++_shared.so
    local LIBCPP="$NDK_SYSROOT/$NDK_ARCH/libc++_shared.so"
    if [ -f "$LIBCPP" ]; then
        cp "$LIBCPP" "$JNILIBS_DIR/"
        log_success "Copied libc++_shared.so -> jniLibs/$ABI/"
    else
        log_warn "libc++_shared.so not found: $LIBCPP"
    fi
}

copy_libraries() {
    local TARGETS=$1

    print_header "Copying Libraries to Flutter Project"

    case "$TARGETS" in
        arm64)
            copy_library "aarch64-linux-android" "arm64-v8a" "aarch64-linux-android"
            ;;
        x86_64)
            copy_library "x86_64-linux-android" "x86_64" "x86_64-linux-android"
            ;;
        arm32)
            copy_library "armv7-linux-androideabi" "armeabi-v7a" "arm-linux-androideabi"
            ;;
        all)
            copy_library "aarch64-linux-android" "arm64-v8a" "aarch64-linux-android"
            copy_library "x86_64-linux-android" "x86_64" "x86_64-linux-android"
            copy_library "armv7-linux-androideabi" "armeabi-v7a" "arm-linux-androideabi"
            ;;
    esac

    # List copied libraries
    echo ""
    log_info "Libraries in jniLibs:"
    find "$MOBILE_DIR/android/app/src/main/jniLibs" -name "*.so" -exec ls -lh {} \; 2>/dev/null || true
}

# =============================================================================
# Flutter Build Functions
# =============================================================================

build_flutter_apk() {
    # All output goes to stderr except the final APK path
    print_header "Building Flutter APK" >&2

    cd "$MOBILE_DIR"

    # List bundled assets
    log_info "Bundled assets:" >&2
    if [ -f "$MOBILE_DIR/assets/models/ggml-base-q5_1.bin" ]; then
        local MODEL_SIZE=$(ls -lh "$MOBILE_DIR/assets/models/ggml-base-q5_1.bin" | awk '{print $5}')
        log_info "  - Whisper model: ggml-base-q5_1.bin ($MODEL_SIZE)" >&2
    fi
    if [ -f "$MOBILE_DIR/assets/audio/woodchuck.wav" ]; then
        local AUDIO_SIZE=$(ls -lh "$MOBILE_DIR/assets/audio/woodchuck.wav" | awk '{print $5}')
        log_info "  - Test audio: woodchuck.wav ($AUDIO_SIZE)" >&2
    fi

    # Clean previous builds
    log_info "Cleaning previous builds..." >&2
    flutter clean >&2

    # Get dependencies
    log_info "Getting Flutter dependencies..." >&2
    flutter pub get >&2

    # Run build_runner if needed
    if grep -q "build_runner" pubspec.yaml 2>/dev/null; then
        log_info "Running build_runner..." >&2
        flutter pub run build_runner build --delete-conflicting-outputs >&2 || true
    fi

    # Build APK
    log_info "Building release APK..." >&2
    flutter build apk --release >&2

    # Verify output
    local APK_PATH="$MOBILE_DIR/build/app/outputs/flutter-apk/app-release.apk"
    if [ -f "$APK_PATH" ]; then
        local SIZE=$(ls -lh "$APK_PATH" | awk '{print $5}')
        log_success "APK built successfully: $APK_PATH ($SIZE)" >&2
        # Only this line goes to stdout for capture
        echo "$APK_PATH"
    else
        log_error "APK build failed: $APK_PATH not found" >&2
        exit 1
    fi
}

# =============================================================================
# Device Deployment Functions
# =============================================================================

deploy_to_device() {
    local APK_PATH=$1

    print_header "Deploying to Device"

    if ! command -v adb &> /dev/null; then
        log_warn "adb not found. Skipping device deployment."
        print_manual_install_instructions "$APK_PATH"
        return
    fi

    # Check for connected devices
    local DEVICES=$(adb devices | grep -v "^List" | grep -v "^$" | grep "device$")

    if [ -z "$DEVICES" ]; then
        log_warn "No adb devices found online."
        print_manual_install_instructions "$APK_PATH"
        return
    fi

    # List connected devices
    log_info "Found connected device(s):"
    echo "$DEVICES"
    echo ""

    # Install to all connected devices
    local DEVICE_COUNT=$(echo "$DEVICES" | wc -l)
    log_info "Installing APK to $DEVICE_COUNT device(s)..."

    echo "$DEVICES" | while read -r line; do
        local DEVICE_ID=$(echo "$line" | awk '{print $1}')
        if [ -n "$DEVICE_ID" ]; then
            log_info "Installing to device: $DEVICE_ID"
            if adb -s "$DEVICE_ID" install -r "$APK_PATH"; then
                log_success "Installed successfully on $DEVICE_ID"
            else
                log_error "Installation failed on $DEVICE_ID"
            fi
        fi
    done
}

print_manual_install_instructions() {
    local APK_PATH=$1

    echo ""
    echo "=============================================="
    echo " Manual Installation Instructions"
    echo "=============================================="
    echo ""
    echo "To install the APK manually, connect your device and run:"
    echo ""
    echo "  adb install -r \"$APK_PATH\""
    echo ""
    echo "Or for a specific device:"
    echo ""
    echo "  adb -s <device-id> install -r \"$APK_PATH\""
    echo ""
    echo "To list available devices:"
    echo ""
    echo "  adb devices"
    echo ""
}

# =============================================================================
# Main Script
# =============================================================================

print_usage() {
    echo "Lexicon Mobile APK Build Script"
    echo ""
    echo "Usage: $0 [target] [options]"
    echo ""
    echo "Targets:"
    echo "  arm64   Build for ARM64 (most Android devices)"
    echo "  x86_64  Build for x86_64 (Android emulators) [default]"
    echo "  arm32   Build for ARM32 (older 32-bit devices)"
    echo "  all     Build for all targets"
    echo ""
    echo "Options:"
    echo "  --skip-rust    Skip Rust library build (use existing)"
    echo "  --skip-model   Skip Whisper model check/download"
    echo "  --skip-deploy  Skip device deployment"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  ANDROID_NDK_HOME    Path to Android NDK (default: ~/Android/Sdk/ndk/29.0.14206865)"
    echo "  ANDROID_API         Android API level (default: 26)"
    echo "  CARGO_BUILD_JOBS    Parallel cargo jobs (default: 4)"
    echo ""
    echo "Bundled Assets (in Lexicon-Mobile/assets/):"
    echo "  models/ggml-base-q5_1.bin  Whisper base model for STT (auto-downloaded)"
    echo "  audio/woodchuck.wav        Test audio for transcription (optional)"
    echo ""
    echo "Examples:"
    echo "  $0                  # Build x86_64 and deploy (default)"
    echo "  $0 x86_64           # Build x86_64 (for emulator)"
    echo "  $0 arm64            # Build ARM64 (for physical devices)"
    echo "  $0 all              # Build all architectures"
    echo "  $0 arm64 --skip-rust  # Rebuild APK only, skip Rust"
    echo ""
}

main() {
    local TARGET="x86_64"
    local SKIP_RUST=false
    local SKIP_MODEL=false
    local SKIP_DEPLOY=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            arm64|x86_64|arm32|all)
                TARGET=$1
                shift
                ;;
            --skip-rust)
                SKIP_RUST=true
                shift
                ;;
            --skip-model)
                SKIP_MODEL=true
                shift
                ;;
            --skip-deploy)
                SKIP_DEPLOY=true
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                print_usage
                exit 1
                ;;
        esac
    done

    print_header "Lexicon Mobile APK Build"
    log_info "Target: $TARGET"
    log_info "Skip Rust: $SKIP_RUST"
    log_info "Skip Model: $SKIP_MODEL"
    log_info "Skip Deploy: $SKIP_DEPLOY"
    log_info "NDK: $ANDROID_NDK_HOME"
    log_info "API Level: $ANDROID_API"

    # Run build pipeline
    check_prerequisites

    if [ "$SKIP_MODEL" = false ]; then
        ensure_whisper_model
    else
        log_info "Skipping model check (--skip-model)"
    fi

    if [ "$SKIP_RUST" = false ]; then
        build_rust_libraries "$TARGET"
    else
        log_info "Skipping Rust build (--skip-rust)"
    fi

    copy_libraries "$TARGET"

    APK_PATH=$(build_flutter_apk)

    if [ "$SKIP_DEPLOY" = false ]; then
        deploy_to_device "$APK_PATH"
    else
        log_info "Skipping deployment (--skip-deploy)"
        print_manual_install_instructions "$APK_PATH"
    fi

    # Final summary
    print_header "Build Complete!"
    log_success "APK Location: $APK_PATH"
    echo ""
}

# Run main function
main "$@"
