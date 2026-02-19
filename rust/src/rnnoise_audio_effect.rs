use std::ffi::c_void;

use godot::classes::{AudioEffect, AudioEffectInstance, IAudioEffect, IAudioEffectInstance};

use godot::{classes::native::AudioFrame, prelude::*};
use nnnoiseless::DenoiseState;

/// Adds a noise removal effect to an audio bus using RNNoise[^rnnoise].
///
/// Uses both traditional signal processing and a recurrent neural network to
/// remove noise from audio. The effect is fairly aggressive and can't be configured.
/// [^rnnoise]: https://github.com/xiph/rnnoise
#[derive(GodotClass, Debug)]
#[class(tool, init, base=AudioEffect)]
pub(crate) struct AudioEffectRNNoise {
    pub(crate) base: Base<AudioEffect>,
}

#[godot_api]
impl IAudioEffect for AudioEffectRNNoise {
    fn instantiate(&mut self) -> Option<Gd<AudioEffectInstance>> {
        let rnnoise = AudioEffectRNNoiseInstance::new_gd();
        return Some(rnnoise.upcast::<AudioEffectInstance>());
    }
}

#[derive(GodotClass)]
#[class(base=AudioEffectInstance)]
pub(crate) struct AudioEffectRNNoiseInstance {
    pub(crate) base: Base<AudioEffectInstance>,
    denoise: Box<DenoiseState<'static>>,
    input_buffer: Vec<f32>,
    output_buffer: Vec<f32>,
    first_frame: bool,
}

#[godot_api]
impl IAudioEffectInstance for AudioEffectRNNoiseInstance {
    unsafe fn process_rawptr(
        &mut self,
        input: *const c_void,
        output: *mut AudioFrame,
        frame_count: i32,
    ) {
        let frame_count = frame_count as usize;

        let input_slice = std::slice::from_raw_parts(input as *const AudioFrame, frame_count);
        let output_slice = std::slice::from_raw_parts_mut(output, frame_count);

        // Convert input to mono and scale to i16 range
        let scaled_input: Vec<f32> = input_slice
            .iter()
            .map(|frame| ((frame.left + frame.right) / 2.0) * i16::MAX as f32)
            .collect();

        // Add new input to buffer
        self.input_buffer.extend_from_slice(&scaled_input);

        // Process complete frames
        while self.input_buffer.len() >= DenoiseState::FRAME_SIZE {
            let mut out_buf = [0.0; DenoiseState::FRAME_SIZE];

            // Process one frame
            self.denoise.process_frame(
                &mut out_buf[..],
                &self.input_buffer[..DenoiseState::FRAME_SIZE],
            );

            // Skip first frame output due to fade-in artifacts
            if !self.first_frame {
                self.output_buffer.extend_from_slice(&out_buf[..]);
            }
            self.first_frame = false;

            // Remove processed samples from input buffer
            self.input_buffer.drain(..DenoiseState::FRAME_SIZE);
        }

        // Fill output with available processed samples
        for (i, output_frame) in output_slice.iter_mut().enumerate() {
            if i < self.output_buffer.len() {
                let denoised_sample = self.output_buffer[i] / i16::MAX as f32;
                output_frame.left = denoised_sample;
                output_frame.right = denoised_sample;
            } else {
                // If we don't have enough processed samples, use original input
                let original_sample = (input_slice[i].left + input_slice[i].right) / 2.0;
                output_frame.left = original_sample;
                output_frame.right = original_sample;
            }
        }

        // Remove consumed output samples
        if frame_count <= self.output_buffer.len() {
            self.output_buffer.drain(..frame_count);
        } else {
            self.output_buffer.clear();
        }
    }

    fn init(base: Base<AudioEffectInstance>) -> Self {
        AudioEffectRNNoiseInstance {
            base,
            denoise: Box::new(*DenoiseState::new()),
            input_buffer: Vec::new(),
            output_buffer: Vec::new(),
            first_frame: true,
        }
    }
}
