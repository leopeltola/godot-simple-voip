use godot::prelude::*;

mod deep_filter_net_audio_effect;
mod opus_codec;
mod resampler;
mod rnnoise_audio_effect;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}
