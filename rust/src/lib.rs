use godot::prelude::*;

mod opus_codec;
mod resampler;
mod rnnoise_audio_effect;

struct MyExtension;

#[gdextension]
unsafe impl ExtensionLibrary for MyExtension {}
