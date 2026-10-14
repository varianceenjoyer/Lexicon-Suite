# Lexicon Suite

Build tooling that ties together the Lexicon projects — on-device, privacy-first speech transcription with no cloud required.

| Repository | Description |
|------------|-------------|
| [Lexicon-Local-Server](https://github.com/varianceenjoyer/Lexicon-Local-Server) | Rust core: speech-to-text, TTS, HTTP server, CLI, and FFI crates |
| [Lexicon-Mobile](https://github.com/varianceenjoyer/Lexicon-Mobile) | Flutter app for Android/iOS, embedding the Rust core over FFI |

## Setup

Clone the project repositories into this directory (they are git-ignored here):

```bash
git clone https://github.com/varianceenjoyer/Lexicon-Suite
cd Lexicon-Suite
git clone https://github.com/varianceenjoyer/Lexicon-Local-Server
git clone https://github.com/varianceenjoyer/Lexicon-Mobile
```

## Building the Android APK

`build/build_mobile_apk.sh` builds the `lexicon-flutter` Rust library with the Parakeet STT engine, downloads the model, and builds the Flutter APK in one step.

Requirements: Rust, Flutter (Dart 3), and the Android SDK + NDK (`ANDROID_NDK_HOME`).

```bash
./build/build_mobile_apk.sh arm64      # targets: arm64, x86_64 (default), arm32, all
```

## License

MIT License - See [LICENSE](LICENSE) for details.
