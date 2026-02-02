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
ANDROID_API="${ANDROID_API:-30}"
TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
NDK_SYSROOT="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib"

# Build Configuration
# Reduced from 4 to 2 - each job uses 1-2GB RAM, and LTO phase uses 2-3GB more
CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-2}"
BUILD_TYPE="${BUILD_TYPE:-release}"

# Model Configuration
WHISPER_MODEL_ID="tiny-q5_1"
WHISPER_MODEL_NAME="ggml-tiny-q5_1.bin"
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
# Memory Management Functions
# =============================================================================

get_available_memory_gb() {
    if [ -f /proc/meminfo ]; then
        awk '/MemAvailable/ {print int($2/1024/1024)}' /proc/meminfo
    else
        echo "8"  # Assume 8GB if can't detect
    fi
}

adjust_build_settings() {
    local available_gb=$(get_available_memory_gb)
    log_info "Available memory: ${available_gb}GB"

    # Only adjust if CARGO_BUILD_JOBS wasn't explicitly set by user
    if [ -z "${CARGO_BUILD_JOBS_USER_SET:-}" ]; then
        if [ "$available_gb" -lt 6 ]; then
            export CARGO_BUILD_JOBS=1
            log_warn "Low memory (${available_gb}GB) - using single-threaded Rust build"
        elif [ "$available_gb" -lt 10 ]; then
            export CARGO_BUILD_JOBS=2
            log_info "Limited memory (${available_gb}GB) - using 2 parallel Rust jobs"
        fi
    fi
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
    # In WSL2, prefer Windows adb.exe to communicate with Windows emulator
    WINDOWS_ADB="/mnt/n/.DEV/tools/Android/platform-tools/adb.exe"
    if [ -f "$WINDOWS_ADB" ]; then
        ADB_CMD="$WINDOWS_ADB"
        log_success "Windows adb.exe found (WSL2 mode)"
    elif command -v adb &> /dev/null; then
        ADB_CMD="adb"
        log_success "adb found: $(adb version | head -1)"
    else
        ADB_CMD=""
        log_warn "adb not found. Device deployment will be skipped."
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

    # Create wrapper scripts that inject -stdlib=libc++ for C++ compilation
    # This is necessary because cmake-rs doesn't reliably pass CXXFLAGS to cmake
    local WRAPPER_DIR="$SCRIPT_DIR/.clang-wrappers/$TARGET"
    mkdir -p "$WRAPPER_DIR"

    local REAL_CXX="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang++"
    local REAL_CC="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang"

    # Create C++ compiler wrapper that:
    # 1. Injects -stdlib=libc++
    # 2. Fixes --target to include API level (required for pthread_cond_clockwait on API 30+)
    cat > "$WRAPPER_DIR/clang++" << EOF
#!/bin/bash
# Wrapper to force libc++ and correct target for Android C++ compilation
# Replace --target=aarch64-linux-android with --target=aarch64-linux-android${ANDROID_API}
ARGS=()
for arg in "\$@"; do
    if [[ "\$arg" == "--target=aarch64-linux-android" ]]; then
        ARGS+=("--target=aarch64-linux-android${ANDROID_API}")
    elif [[ "\$arg" == "--target=x86_64-linux-android" ]]; then
        ARGS+=("--target=x86_64-linux-android${ANDROID_API}")
    elif [[ "\$arg" == "--target=armv7a-linux-androideabi" ]]; then
        ARGS+=("--target=armv7a-linux-androideabi${ANDROID_API}")
    else
        ARGS+=("\$arg")
    fi
done
exec "$REAL_CXX" -stdlib=libc++ "\${ARGS[@]}"
EOF
    chmod +x "$WRAPPER_DIR/clang++"

    # Create C compiler wrapper with same target fix
    cat > "$WRAPPER_DIR/clang" << EOF
#!/bin/bash
# Wrapper to fix target for Android C compilation
ARGS=()
for arg in "\$@"; do
    if [[ "\$arg" == "--target=aarch64-linux-android" ]]; then
        ARGS+=("--target=aarch64-linux-android${ANDROID_API}")
    elif [[ "\$arg" == "--target=x86_64-linux-android" ]]; then
        ARGS+=("--target=x86_64-linux-android${ANDROID_API}")
    elif [[ "\$arg" == "--target=armv7a-linux-androideabi" ]]; then
        ARGS+=("--target=armv7a-linux-androideabi${ANDROID_API}")
    else
        ARGS+=("\$arg")
    fi
done
exec "$REAL_CC" "\${ARGS[@]}"
EOF
    chmod +x "$WRAPPER_DIR/clang"

    # Run cargo build in a subshell to isolate environment changes
    (
        # Use wrappers for both C and C++ to ensure correct target with API level
        export CC_${CC_VAR}="$WRAPPER_DIR/clang"
        export CXX_${CC_VAR}="$WRAPPER_DIR/clang++"
        export AR_${CC_VAR}="$TOOLCHAIN/llvm-ar"

        # Configure the Rust linker for this target (uppercase with underscores for Cargo env vars)
        CARGO_TARGET_VAR="CARGO_TARGET_$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')_LINKER"
        export "${CARGO_TARGET_VAR}"="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang"

        # CRITICAL: Force libc++ usage for Android compatibility
        # Android uses libc++, not libstdc++. Without these flags, C++ dependencies
        # (like whisper.cpp) will link against libstdc++ symbols that don't exist on Android.
        export CXXFLAGS="-stdlib=libc++"
        export CFLAGS=""
        export LDFLAGS="-stdlib=libc++ -lc++_shared"

        # Set rustflags to pass libc++ to the linker for C++ dependencies
        CARGO_TARGET_RUSTFLAGS_VAR="CARGO_TARGET_$(echo "$TARGET" | tr '[:lower:]-' '[:upper:]_')_RUSTFLAGS"
        export "${CARGO_TARGET_RUSTFLAGS_VAR}"="-C link-arg=-stdlib=libc++"

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
        # Force CMake to use our wrapper compiler that injects -stdlib=libc++
        export CMAKE_CXX_COMPILER="$WRAPPER_DIR/clang++"
        export CMAKE_C_COMPILER="$TOOLCHAIN/${CC_BIN}${ANDROID_API}-clang"

        # ARM64-specific: Enable DOTPROD for whisper.cpp (~2x speedup for quantized ops)
        # Note: I8MM (ARMv8.6-A) was tested but causes SIGILL on some Cortex-A78 variants
        # Note: OpenMP was tested but provided no benefit on Android ARM64 (~3320ms vs 3250ms)
        # These CMAKE flags only affect CMake builds (whisper-rs-sys), not other crates
        local WHISPER_ARCH_FLAGS=""
        if [ "$TARGET" = "aarch64-linux-android" ]; then
            WHISPER_ARCH_FLAGS="-march=armv8.2-a+dotprod"
            log_info "Enabling ARMv8.2-A DOTPROD for whisper.cpp"
        fi

        # Set CMAKE flags with optional DOTPROD for whisper.cpp optimization
        export CMAKE_CXX_FLAGS="-stdlib=libc++ $WHISPER_ARCH_FLAGS"
        export CMAKE_C_FLAGS="$WHISPER_ARCH_FLAGS"
        export CMAKE_EXE_LINKER_FLAGS="-stdlib=libc++ -lc++_shared"
        export CMAKE_SHARED_LINKER_FLAGS="-stdlib=libc++ -lc++_shared"
        export CARGO_BUILD_JOBS

        cd "$LOCAL_SERVER_DIR"

        # Clean whisper-rs-sys build cache to force rebuild with new flags
        rm -rf target/$TARGET/release/build/whisper-rs-sys-* 2>/dev/null || true

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
            # Use stt-only features for arm64 to avoid ONNX Runtime libstdc++ issues
            build_rust_target "aarch64-linux-android" "aarch64_linux_android" "aarch64-linux-android" "stt" "arm64-v8a"
            log_warn "TTS disabled for arm64 (ONNX Runtime has libstdc++ compatibility issues)"
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

    # Note: OpenMP is statically linked, no need to copy libomp.so
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

    # Only clean if --clean flag was passed (saves 50-70% build time on incremental builds)
    if [ "$FORCE_CLEAN" = true ]; then
        log_info "Cleaning previous builds (--clean)..." >&2
        flutter clean >&2
    else
        log_info "Incremental build (use --clean for full rebuild)" >&2
    fi

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
# Daemon Cleanup Functions
# =============================================================================

stop_build_daemons() {
    print_header "Stopping Build Daemons"

    # Gracefully stop Gradle daemon (this also handles the Kotlin daemon)
    # Note: gradle.properties configures org.gradle.daemon.idletimeout=300000 (5 min)
    # so any daemons not stopped here will self-terminate after 5 minutes idle
    if [ -f "$MOBILE_DIR/android/gradlew" ]; then
        log_info "Requesting graceful Gradle daemon shutdown..."
        (cd "$MOBILE_DIR/android" && timeout 15 ./gradlew --stop 2>/dev/null) || true
    fi

    # Give time for graceful shutdown
    sleep 3

    # Verify cleanup (informational - daemons will self-terminate via idletimeout if still running)
    local GRADLE_PROCS
    local KOTLIN_PROCS
    GRADLE_PROCS=$(pgrep -c "GradleDaemon" 2>/dev/null) || GRADLE_PROCS=0
    KOTLIN_PROCS=$(pgrep -c "KotlinCompileDaemon" 2>/dev/null) || KOTLIN_PROCS=0

    if [ "$GRADLE_PROCS" -eq 0 ] && [ "$KOTLIN_PROCS" -eq 0 ]; then
        log_success "All build daemons stopped gracefully"
    else
        log_info "Daemons still running: Gradle=$GRADLE_PROCS, Kotlin=$KOTLIN_PROCS"
        log_info "They will self-terminate in 5 minutes (org.gradle.daemon.idletimeout)"
    fi
}

# =============================================================================
# Memory Cleanup Functions
# =============================================================================

drop_filesystem_cache() {
    print_header "Dropping Filesystem Cache"

    # Get memory before cleanup
    local BEFORE_CACHE=$(free -m | awk '/^Mem:/ {print $6}')
    local BEFORE_AVAIL=$(free -m | awk '/^Mem:/ {print $7}')

    log_info "Before: ${BEFORE_CACHE}MB buff/cache, ${BEFORE_AVAIL}MB available"

    # Sync to flush dirty pages first
    sync

    # Try to drop caches (requires root or appropriate permissions)
    if [ -w /proc/sys/vm/drop_caches ]; then
        # Drop pagecache, dentries, and inodes
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        log_success "Dropped filesystem caches"
    elif command -v sudo &> /dev/null; then
        # Try with sudo (may prompt for password or fail silently)
        if sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null; then
            log_success "Dropped filesystem caches (via sudo)"
        else
            log_warn "Cannot drop caches (requires sudo password or root)"
            log_info "Run manually: sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'"
            return 0
        fi
    else
        log_warn "Cannot drop caches (no write access to /proc/sys/vm/drop_caches)"
        log_info "Run manually: sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'"
        return 0
    fi

    # Get memory after cleanup
    local AFTER_CACHE=$(free -m | awk '/^Mem:/ {print $6}')
    local AFTER_AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
    local FREED=$((BEFORE_CACHE - AFTER_CACHE))

    log_info "After: ${AFTER_CACHE}MB buff/cache, ${AFTER_AVAIL}MB available"
    log_success "Freed ${FREED}MB of cached memory"
}

# =============================================================================
# Device Deployment Functions
# =============================================================================

deploy_to_device() {
    local APK_PATH=$1

    print_header "Deploying to Device"

    if [ -z "$ADB_CMD" ]; then
        log_warn "adb not found. Skipping device deployment."
        print_manual_install_instructions "$APK_PATH"
        return
    fi

    # For Windows adb.exe, convert WSL path to Windows path
    local INSTALL_PATH="$APK_PATH"
    if [[ "$ADB_CMD" == *.exe ]]; then
        INSTALL_PATH=$(wslpath -w "$APK_PATH")
        log_info "Using Windows path: $INSTALL_PATH"
    fi

    # Check for connected devices
    local DEVICES=$("$ADB_CMD" devices | grep -v "^List" | grep -v "^$" | grep "device$")

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
            if "$ADB_CMD" -s "$DEVICE_ID" install -r "$INSTALL_PATH"; then
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

    # Show appropriate command based on detected adb
    if [ -n "$ADB_CMD" ]; then
        if [[ "$ADB_CMD" == *.exe ]]; then
            local WIN_PATH=$(wslpath -w "$APK_PATH")
            echo "To install the APK manually (using Windows adb.exe):"
            echo ""
            echo "  $ADB_CMD install -r \"$WIN_PATH\""
        else
            echo "To install the APK manually:"
            echo ""
            echo "  adb install -r \"$APK_PATH\""
        fi
    else
        echo "To install the APK manually, connect your device and run:"
        echo ""
        echo "  adb install -r \"$APK_PATH\""
    fi
    echo ""
    echo "To list available devices:"
    echo ""
    echo "  ${ADB_CMD:-adb} devices"
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
    echo "  --clean        Force full Flutter rebuild (default: incremental)"
    echo "  --keep-daemons Keep Gradle/Kotlin daemons running after build"
    echo "  --help, -h     Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  ANDROID_NDK_HOME    Path to Android NDK (default: ~/Android/Sdk/ndk/29.0.14206865)"
    echo "  ANDROID_API         Android API level (default: 26)"
    echo "  CARGO_BUILD_JOBS    Parallel cargo jobs (default: 2, auto-adjusts based on available RAM)"
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
    local KEEP_DAEMONS=false
    FORCE_CLEAN=false  # Global for use in build_flutter_apk

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
            --keep-daemons)
                KEEP_DAEMONS=true
                shift
                ;;
            --clean)
                FORCE_CLEAN=true
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
    log_info "Force Clean: $FORCE_CLEAN"
    log_info "Keep Daemons: $KEEP_DAEMONS"
    log_info "NDK: $ANDROID_NDK_HOME"
    log_info "API Level: $ANDROID_API"

    # Run build pipeline
    check_prerequisites

    # Auto-adjust build settings based on available memory
    adjust_build_settings

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

    # Stop build daemons to reclaim memory (unless --keep-daemons)
    if [ "$KEEP_DAEMONS" = false ]; then
        stop_build_daemons
    else
        log_info "Keeping daemons running (--keep-daemons)"
        log_warn "Run './gradlew --stop' manually to reclaim ~5-6GB memory"
    fi

    # Drop filesystem cache to reclaim memory used during build
    drop_filesystem_cache

    # Final summary
    print_header "Build Complete!"
    log_success "APK Location: $APK_PATH"
    echo ""
}

# Run main function
main "$@"
