# Fix Noise Reduction Quality + Add Strength Control

## Context

Noise reduction with nnnoiseless (RNNoise) is reducing transcription accuracy in both normal and noisy environments. Investigation found three root causes:

1. **Critical bug**: nnnoiseless expects samples in [-32768, 32767] (16-bit PCM scale), but we pass [-1.0, 1.0] floats. The RNN receives near-zero inputs and produces garbage output. This alone likely explains most of the quality loss.
2. **Poor resampling**: Linear interpolation up + raw decimation down introduces spectral artifacts and aliasing.
3. **No tuning**: nnnoiseless has zero configuration options, no spectral subtraction. But we can add a dry/wet strength control using the VAD probability it returns.

## Changes

### 1. Fix sample scaling in `denoise.rs` (CRITICAL)
**File**: `Lexicon-Local-Server/crates/lexicon-core/src/denoise.rs`

Before `process_frame()`: multiply samples by 32767.0
After `process_frame()`: divide by 32767.0

### 2. Replace resampling with rubato
**Files**:
- `Lexicon-Local-Server/crates/lexicon-core/Cargo.toml` — add `dep:rubato` to `noise-reduction` feature
- `Lexicon-Local-Server/crates/lexicon-core/src/denoise.rs` — replace `upsample_3x` + decimation with `rubato::FastFixedIn` (Cubic, same config proven in `audio/resampler.rs`)

Delete the `upsample_3x` function entirely. Add upsampler (ratio 3.0) and downsampler (ratio 1/3) as `Denoiser` struct fields.

### 3. Add strength parameter + VAD-adaptive blending
**File**: `Lexicon-Local-Server/crates/lexicon-core/src/denoise.rs`

- Add `strength: f32` (0.0–1.0) to `Denoiser` with `set_strength()` method
- Capture VAD probability from `process_frame()` return value (currently ignored)
- Smooth VAD with EMA: `vad = 0.8 * prev_vad + 0.2 * new_vad`
- Blend per-frame: during speech (high VAD), preserve up to 30% original signal; during noise-only (low VAD), use full denoised signal
- `strength = 0.0` = full bypass, `strength = 1.0` = maximum denoising

### 4. Add FFI methods
**File**: `Lexicon-Local-Server/crates/lexicon-flutter/src/api.rs`

- Add `set_noise_reduction_strength(strength: f64)` / `get_noise_reduction_strength() -> f64` on `ParakeetTranscriber`
- Store as `AtomicU32` (f32 bits) for lock-free access
- Reset denoiser state when toggling noise reduction back on

### 5. Regenerate FRB bindings
Run `flutter_rust_bridge_codegen generate`, copy to Lexicon-Mobile.

### 6. Add strength slider to Flutter settings
**Files**:
- `Lexicon-Mobile/lib/providers/settings_provider.dart` — add `noiseReductionStrength` (default 1.0), persist via SharedPreferences
- `Lexicon-Mobile/lib/services/lexicon_core_service.dart` — add parameter to `updateSettings()`
- `Lexicon-Mobile/lib/services/lexicon_flutter_service.dart` — call `setNoiseReductionStrength()`
- `Lexicon-Mobile/lib/features/settings/screens/audio_settings_screen.dart` — add slider below toggle (visible only when noise reduction is on), labels: Light/Moderate/Strong/Maximum
- `Lexicon-Mobile/lib/providers/service_providers.dart` — pass `noiseReductionStrength` through
- `Lexicon-Mobile/lib/services/mocks/lexicon_core_service_mock.dart` — update signature

## Verification
1. `cargo test -p lexicon-core --no-default-features --features noise-reduction --lib`
2. `cargo check -p lexicon-flutter --no-default-features --features stt-parakeet,noise-reduction`
3. Build APK: `build/build_mobile_apk.sh arm64 --skip-model`
4. Test on device: noise reduction OFF vs ON at various strength levels, in quiet and noisy environments
