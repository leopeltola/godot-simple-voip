use std::ffi::c_void;

use godot::classes::{
    AudioEffect, AudioEffectInstance, AudioStreamGenerator, AudioStreamGeneratorPlayback,
    AudioStreamPlayback, IAudioEffect, IAudioEffectInstance, IAudioStreamGenerator,
};

use df::DFState;
use godot::{classes::native::AudioFrame, prelude::*};

// #[derive(GodotClass, Debug)]
// #[class(tool, init, base=AudioStreamGenerator)]
// pub(crate) struct AudioStreamVoice {
//     pub(crate) base: Base<AudioStreamGenerator>,
// }

// #[godot_api]
// impl IAudioStreamGenerator for AudioStreamVoice {
//     fn instantiate_playback(&self) -> Option<Gd<AudioStreamPlayback>> {
//         let pb = AudioStreamGeneratorPlayback::

//         return None;
//     }
// }
