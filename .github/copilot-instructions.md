# Copilot instructions for godot-simple-voip

## Big picture architecture
- This repo is a Godot 4 VOIP plugin: GDScript orchestrates networking/audio buses, Rust GDExtension provides codecs/effects.
- Core control flow lives in `VOIP` singleton ([addons/godot_simple_voip/voip_singleton.gd](addons/godot_simple_voip/voip_singleton.gd)).
- Rust classes are exposed via godot-rust and loaded through [addons/godot_simple_voip/simple_voip.gdextension](addons/godot_simple_voip/simple_voip.gdextension).
- Registration entrypoint is [rust/src/lib.rs](rust/src/lib.rs); important native classes include:
  - `OpusCodec` ([rust/src/opus_codec.rs](rust/src/opus_codec.rs))
  - `Resampler` ([rust/src/resampler.rs](rust/src/resampler.rs))
  - `AudioEffectRNNoise` ([rust/src/rnnoise_audio_effect.rs](rust/src/rnnoise_audio_effect.rs))

## Data flow (mic -> network -> playback)
- Mic is routed to bus `VOIP` using `AudioStreamMicrophone` in demos ([demo/main.gd](demo/main.gd), [demo/main_generator.gd](demo/main_generator.gd)).
- `VOIP._process()` polls `AudioEffectCapture`, chunks frames, resamples to network rate, then sends unreliable ordered RPC.
- Default packet contract is 48kHz + 960 samples/frame (20ms). Keep this consistent across Rust and GDScript.
- Server relays client voice to other peers; clients decode and emit `peer_voice_data_received`.
- Playback is pull/push buffered in `AudioStreamVOIP` ([addons/godot_simple_voip/audio_stream_voip.gd](addons/godot_simple_voip/audio_stream_voip.gd)); startup requires a 3-frame prebuffer to reduce underruns.

## Project-specific conventions
- Prefer typed GDScript (`var name: Type`, typed signals, exported typed vars) and keep existing snake_case naming.
- Keep VOIP transport `@rpc("any_peer"/"authority", "unreliable_ordered", "call_remote")` unless the task explicitly changes latency/reliability behavior.
- Existing code includes rich telemetry (`debug_stats_updated`, stage counters). Extend these stats instead of adding ad-hoc prints.
- The plugin auto-creates bus/effects if missing, but also supports preconfigured bus layouts; preserve this fallback behavior.

## Build/test/debug workflows
- Rust build root is [rust/Cargo.toml](rust/Cargo.toml).
- Debug native build: run `cargo build` in `rust/`, then ensure output DLL is [addons/godot_simple_voip/bin/simple_voip.dll](addons/godot_simple_voip/bin/simple_voip.dll).
- Release native build: run `cargo build --release`, then ensure output DLL name/path matches [addons/godot_simple_voip/simple_voip.gdextension](addons/godot_simple_voip/simple_voip.gdextension) (`simple_voip_release.dll`).
- Rust unit tests currently exist for resampling only; run `cargo test` in `rust/`.
- Fast manual verification scenes: [demo/main.tscn](demo/main.tscn), [demo/main_generator.tscn](demo/main_generator.tscn), [demo/opus_loopback.tscn](demo/opus_loopback.tscn).

## Integration boundaries to respect
- Godot project enables mic input and 48kHz mix rate in [project.godot](project.godot); avoid silent sample-rate changes.
- Autoload singleton is expected at `/root/VOIP` (plugin + project both reference it).
- `AudioStreamVOIP` instances are discovered from active `AudioStreamPlayer` nodes; changes to stream binding affect all peer playback.
- Keep network payload compatibility: if modifying Opus/frame sizing, update both Rust codec and GDScript packetization/resampling paths together.