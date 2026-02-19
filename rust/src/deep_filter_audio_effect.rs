use std::ffi::c_void;

use godot::classes::{AudioEffect, AudioEffectInstance, IAudioEffect, IAudioEffectInstance};

use df::DFState;
use godot::{classes::native::AudioFrame, prelude::*};

/// Adds a noise removal effect to an audio bus using DeepFilterNet.
///
/// High-quality but also CPU-intensive.
#[derive(GodotClass, Debug)]
#[class(tool, init, base=AudioEffect)]
pub(crate) struct AudioEffectDeepFilter {
    pub(crate) base: Base<AudioEffect>,
}

#[godot_api]
impl IAudioEffect for AudioEffectDeepFilter {
    fn instantiate(&mut self) -> Option<Gd<AudioEffectInstance>> {
        let deep_filter = AudioEffectDeepFilterInstance::new_gd();
        return Some(deep_filter.upcast::<AudioEffectInstance>());
    }
}

#[derive(GodotClass)]
#[class(base=AudioEffectInstance)]
pub(crate) struct AudioEffectDeepFilterInstance {
    pub(crate) base: Base<AudioEffectInstance>,
    df_state: Box<DFState>,
    input_buffer: Vec<f32>,
    output_buffer: Vec<f32>,
    first_frame: bool,
}

#[godot_api]
impl IAudioEffectInstance for AudioEffectDeepFilterInstance {
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
            .map(|frame| ((frame.left + frame.right) / 2.0) as f32)
            .collect(); // Add new input to buffer
        self.input_buffer.extend_from_slice(&scaled_input);

        // Process complete frames
        while self.input_buffer.len() >= self.df_state.frame_size {
            let mut out_buf = vec![0.0; self.df_state.frame_size];

            // Process one frame
            self.df_state.process_frame(
                &self.input_buffer[..self.df_state.frame_size],
                &mut out_buf[..],
            );

            // Skip first frame output due to fade-in artifacts
            if !self.first_frame {
                self.output_buffer.extend_from_slice(&out_buf[..]);
            }
            self.first_frame = false;

            // Remove processed samples from input buffer
            self.input_buffer.drain(..self.df_state.frame_size);
        }

        // Fill output with available processed samples
        for (i, output_frame) in output_slice.iter_mut().enumerate() {
            if i < self.output_buffer.len() {
                let denoised_sample = self.output_buffer[i] as f32;
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
        // Initialize DFState with default parameters for 48kHz audio
        // fft_size=512, hop_size=128, nb_bands=32, min_nb_freqs=1
        let df_state = DFState::new(48000, 960, 480, 24, 3);

        AudioEffectDeepFilterInstance {
            base,
            df_state: Box::new(df_state),
            input_buffer: Vec::new(),
            output_buffer: Vec::new(),
            first_frame: true,
        }
    }
}
