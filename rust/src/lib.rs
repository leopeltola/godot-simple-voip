use godot::prelude::*;

mod audio_stream_voip;
mod deep_filter_audio_effect;
mod opus_codec;
mod resampler;
mod rnnoise_audio_effect;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}
