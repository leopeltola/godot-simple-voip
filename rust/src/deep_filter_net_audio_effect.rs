use std::ffi::c_void;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use df::tract::{DfParams, DfTract, ReduceMask, RuntimeParams};
use godot::classes::{
    AudioEffect, AudioEffectInstance, AudioServer, IAudioEffect, IAudioEffectInstance,
};
use godot::{classes::native::AudioFrame, prelude::*};
use ndarray::Array2;

const MAX_DFN_CHUNKS_PER_CALLBACK: usize = 1;

#[derive(Debug, Clone)]
struct DeepFilterParams {
    atten_lim_db: f32,
    min_db_thresh: f32,
    max_db_erb_thresh: f32,
    max_db_df_thresh: f32,
    post_filter_beta: f32,
    reduce_mask_mode: i32,
}

impl Default for DeepFilterParams {
    fn default() -> Self {
        Self {
            atten_lim_db: 100.0,
            min_db_thresh: -10.0,
            max_db_erb_thresh: 30.0,
            max_db_df_thresh: 20.0,
            post_filter_beta: 0.02,
            reduce_mask_mode: ReduceMask::MEAN as i32,
        }
    }
}

#[derive(Debug, Default)]
struct DeepFilterSharedConfig {
    params: DeepFilterParams,
    revision: u64,
}

type DeepFilterSharedConfigRef = Arc<Mutex<DeepFilterSharedConfig>>;

fn reduce_mask_from_i32(mode: i32) -> ReduceMask {
    match mode {
        x if x == ReduceMask::MAX as i32 => ReduceMask::MAX,
        x if x == ReduceMask::MEAN as i32 => ReduceMask::MEAN,
        _ => ReduceMask::NONE,
    }
}

/// Adds a noise removal effect to an audio bus using DeepFilterNet.
///
/// The effect currently runs single-channel enhancement and writes the enhanced
/// mono signal to both output channels.
#[derive(GodotClass)]
#[class(tool, base=AudioEffect)]
pub(crate) struct AudioEffectDeepFilterNet {
    pub(crate) base: Base<AudioEffect>,
    #[export]
    attenuation_limit_db: f32,
    #[export]
    min_db_threshold: f32,
    #[export]
    max_db_erb_threshold: f32,
    #[export]
    max_db_df_threshold: f32,
    #[export]
    post_filter_beta: f32,
    /// 0 = NONE, 1 = MAX, 2 = MEAN
    #[export]
    reduce_mask_mode: i32,
    shared_config: DeepFilterSharedConfigRef,
}

#[godot_api]
impl IAudioEffect for AudioEffectDeepFilterNet {
    fn init(base: Base<AudioEffect>) -> Self {
        let params = DeepFilterParams::default();
        Self {
            base,
            attenuation_limit_db: params.atten_lim_db,
            min_db_threshold: params.min_db_thresh,
            max_db_erb_threshold: params.max_db_erb_thresh,
            max_db_df_threshold: params.max_db_df_thresh,
            post_filter_beta: params.post_filter_beta,
            reduce_mask_mode: params.reduce_mask_mode,
            shared_config: Arc::new(Mutex::new(DeepFilterSharedConfig {
                params,
                revision: 0,
            })),
        }
    }

    fn instantiate(&mut self) -> Option<Gd<AudioEffectInstance>> {
        if let Ok(mut cfg) = self.shared_config.lock() {
            cfg.params.atten_lim_db = self.attenuation_limit_db.abs();
            cfg.params.min_db_thresh = self.min_db_threshold;
            cfg.params.max_db_erb_thresh = self.max_db_erb_threshold;
            cfg.params.max_db_df_thresh = self.max_db_df_threshold;
            cfg.params.post_filter_beta = self.post_filter_beta.max(0.0);
            cfg.params.reduce_mask_mode = self.reduce_mask_mode;
            cfg.revision = cfg.revision.wrapping_add(1);
        }

        let mut effect = AudioEffectDeepFilterNetInstance::new_gd();
        {
            let mut effect_mut = effect.bind_mut();
            effect_mut.shared_config = self.shared_config.clone();
        }
        Some(effect.upcast::<AudioEffectInstance>())
    }
}

#[godot_api]
impl AudioEffectDeepFilterNet {}

#[derive(GodotClass)]
#[class(base=AudioEffectInstance)]
pub(crate) struct AudioEffectDeepFilterNetInstance {
    pub(crate) base: Base<AudioEffectInstance>,
    shared_config: DeepFilterSharedConfigRef,
    applied_revision: u64,
    denoiser: Option<DfTract>,
    init_attempted: bool,
    hop_size: usize,
    input_buffer: Vec<f32>,
    output_buffer: Vec<f32>,
    last_output_sample: f32,
    noisy_frame: Array2<f32>,
    enhanced_frame: Array2<f32>,
    chunk_process_count: u64,
    chunk_process_total_us: u128,
    chunk_process_max_us: u128,
}

impl AudioEffectDeepFilterNetInstance {
    fn rms(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum_sq: f32 = samples.iter().map(|x| x * x).sum();
        (sum_sq / samples.len() as f32).sqrt()
    }

    fn log_init_error(err: &(impl std::fmt::Display + std::fmt::Debug)) {
        godot_error!(
            "AudioEffectDeepFilterNet: model initialization failed. {}",
            err
        );
        godot_error!(
            "AudioEffectDeepFilterNet: model initialization chain: {:#}",
            err
        );
        godot_error!(
            "AudioEffectDeepFilterNet: model initialization debug details: {:?}",
            err
        );
    }

    fn refresh_runtime_config_if_needed(&mut self) {
        let Ok(cfg) = self.shared_config.lock() else {
            return;
        };
        if self.applied_revision == cfg.revision {
            return;
        }

        self.applied_revision = cfg.revision;
        self.denoiser = None;
        self.init_attempted = false;
        self.input_buffer.clear();
        self.output_buffer.clear();
    }

    fn ensure_denoiser_initialized(&mut self) {
        if self.init_attempted || self.denoiser.is_some() {
            return;
        }

        self.init_attempted = true;
        let mix_rate = AudioServer::singleton().get_mix_rate();
        if (mix_rate as i32) != 48_000 {
            godot_error!(
                "AudioEffectDeepFilterNet: unsupported mix rate {} Hz. DeepFilterNet expects 48000 Hz. Falling back to passthrough.",
                mix_rate
            );
            return;
        }

        let params = self
            .shared_config
            .lock()
            .map(|cfg| cfg.params.clone())
            .unwrap_or_default();
        let runtime_params = RuntimeParams::default_with_ch(1)
            .with_mask_reduce(reduce_mask_from_i32(params.reduce_mask_mode))
            .with_post_filter(params.post_filter_beta)
            .with_atten_lim(params.atten_lim_db)
            .with_thresholds(
                params.min_db_thresh,
                params.max_db_erb_thresh,
                params.max_db_df_thresh,
            );
        let t0 = Instant::now();
        match DfTract::new(DfParams::default(), &runtime_params) {
            Ok(model) => {
                self.hop_size = model.hop_size;
                self.noisy_frame = Array2::zeros((1, self.hop_size));
                self.enhanced_frame = Array2::zeros((1, self.hop_size));
                self.denoiser = Some(model);
                self.input_buffer.clear();
                self.output_buffer.clear();
                godot_print!(
                    "AudioEffectDeepFilterNet: model initialized (hop_size={}, load_time_ms={}).",
                    self.hop_size,
                    t0.elapsed().as_millis()
                );
            }
            Err(err) => {
                Self::log_init_error(&err);
                godot_error!(
                    "AudioEffectDeepFilterNet: Falling back to passthrough. load_time_ms={}.",
                    t0.elapsed().as_millis()
                );
            }
        }
    }
}

#[godot_api]
impl IAudioEffectInstance for AudioEffectDeepFilterNetInstance {
    unsafe fn process_rawptr(
        &mut self,
        input: *const c_void,
        output: *mut AudioFrame,
        frame_count: i32,
    ) {
        if frame_count <= 0 {
            return;
        }

        let frame_count = frame_count as usize;

        let input_slice = std::slice::from_raw_parts(input as *const AudioFrame, frame_count);
        let output_slice = std::slice::from_raw_parts_mut(output, frame_count);

        self.refresh_runtime_config_if_needed();
        self.ensure_denoiser_initialized();

        if self.denoiser.is_none() {
            self.input_buffer.clear();
            self.output_buffer.clear();
            for (in_frame, out_frame) in input_slice.iter().zip(output_slice.iter_mut()) {
                out_frame.left = in_frame.left;
                out_frame.right = in_frame.right;
            }
            return;
        }

        // Convert input to mono.
        let mono_input: Vec<f32> = input_slice
            .iter()
            .map(|frame| (frame.left + frame.right) * 0.5)
            .collect();

        self.input_buffer.extend_from_slice(&mono_input);
        let max_input_buffer_samples = self.hop_size * 4;
        if self.input_buffer.len() > max_input_buffer_samples {
            let overflow = self.input_buffer.len() - max_input_buffer_samples;
            self.input_buffer.drain(..overflow);
        }

        let mut processed_chunks_this_callback = 0usize;
        while self.input_buffer.len() >= self.hop_size
            && processed_chunks_this_callback < MAX_DFN_CHUNKS_PER_CALLBACK
        {
            let chunk = &self.input_buffer[..self.hop_size];

            {
                let mut noisy_row = self.noisy_frame.row_mut(0);
                for (dst, src) in noisy_row.iter_mut().zip(chunk.iter()) {
                    *dst = *src;
                }
            }

            let mut used_fallback = true;
            if let Some(denoiser) = self.denoiser.as_mut() {
                let t_chunk = Instant::now();
                if denoiser
                    .process(self.noisy_frame.view(), self.enhanced_frame.view_mut())
                    .is_ok()
                {
                    used_fallback = false;
                    let enhanced = self.enhanced_frame.row(0);
                    let in_rms = Self::rms(chunk);
                    let out_rms = Self::rms(enhanced.as_slice().unwrap_or(&[]));

                    // Guard against over-suppression that can cause robotic/choppy dropouts.
                    if in_rms > 1e-4 && out_rms < in_rms * 0.08 {
                        for (dry, wet) in chunk.iter().zip(enhanced.iter()) {
                            let sample = dry * 0.8 + wet * 0.2;
                            self.output_buffer.push(sample);
                        }
                    } else {
                        self.output_buffer.extend(enhanced.iter().copied());
                    }

                    let elapsed_us = t_chunk.elapsed().as_micros();
                    self.chunk_process_count = self.chunk_process_count.saturating_add(1);
                    self.chunk_process_total_us =
                        self.chunk_process_total_us.saturating_add(elapsed_us);
                    self.chunk_process_max_us = self.chunk_process_max_us.max(elapsed_us);

                    if self.chunk_process_count % 200 == 0 {
                        let avg_us = self.chunk_process_total_us / self.chunk_process_count as u128;
                        let avg_ms = avg_us as f32 / 1000.0;
                        let max_ms = self.chunk_process_max_us as f32 / 1000.0;
                        let budget_ms = (self.hop_size as f32 / 48_000.0) * 1000.0;
                        godot_print!(
                            "AudioEffectDeepFilterNet: chunk timing avg_ms={:.3} max_ms={:.3} budget_ms={:.3} load_ratio={:.2}",
                            avg_ms,
                            max_ms,
                            budget_ms,
                            avg_ms / budget_ms
                        );
                    }
                }
            }

            if used_fallback {
                self.output_buffer.extend_from_slice(chunk);
            }

            let max_buffered_samples = self.hop_size * 2;
            if self.output_buffer.len() > max_buffered_samples {
                let overflow = self.output_buffer.len() - max_buffered_samples;
                self.output_buffer.drain(..overflow);
            }

            self.input_buffer.drain(..self.hop_size);
            processed_chunks_this_callback += 1;
        }

        let mut out_index = 0usize;

        let processed_samples = frame_count.min(self.output_buffer.len());
        for i in 0..processed_samples {
            let sample = self.output_buffer[i];
            self.last_output_sample = sample;
            output_slice[i].left = sample;
            output_slice[i].right = sample;
            out_index += 1;
        }
        if processed_samples > 0 {
            self.output_buffer.drain(..processed_samples);
        }

        let remaining = frame_count.saturating_sub(out_index);
        let dry_take = remaining.min(self.input_buffer.len());
        for i in 0..dry_take {
            let sample = self.input_buffer[i];
            self.last_output_sample = sample;
            output_slice[out_index + i].left = sample;
            output_slice[out_index + i].right = sample;
        }
        if dry_take > 0 {
            self.input_buffer.drain(..dry_take);
            out_index += dry_take;
        }

        for i in out_index..frame_count {
            output_slice[i].left = self.last_output_sample;
            output_slice[i].right = self.last_output_sample;
        }
    }

    fn init(base: Base<AudioEffectInstance>) -> Self {
        let hop_size = 480;

        Self {
            base,
            shared_config: Arc::default(),
            applied_revision: 0,
            denoiser: None,
            init_attempted: false,
            hop_size,
            input_buffer: Vec::new(),
            output_buffer: Vec::new(),
            last_output_sample: 0.0,
            noisy_frame: Array2::zeros((1, hop_size)),
            enhanced_frame: Array2::zeros((1, hop_size)),
            chunk_process_count: 0,
            chunk_process_total_us: 0,
            chunk_process_max_us: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn frame_rms(frame: &Array2<f32>) -> f32 {
        let sum_sq: f32 = frame.iter().map(|x| x * x).sum();
        (sum_sq / frame.len() as f32).sqrt()
    }

    #[test]
    fn dfn_tract_model_initializes() {
        let runtime_params = RuntimeParams::default_with_ch(1).with_mask_reduce(ReduceMask::NONE);
        let model = DfTract::new(DfParams::default(), &runtime_params);
        assert!(
            model.is_ok(),
            "DeepFilterNet init failed in test: {:?}",
            model.err()
        );
    }

    #[test]
    fn dfn_tract_processes_simulated_audio() {
        let runtime_params = RuntimeParams::default_with_ch(1).with_mask_reduce(ReduceMask::NONE);
        let mut model = DfTract::new(DfParams::default(), &runtime_params)
            .expect("DeepFilterNet init failed for processing test");

        let hop = model.hop_size;
        let sr = model.sr as f32;
        let frames = 60usize;

        let mut noisy = Array2::<f32>::zeros((1, hop));
        let mut enhanced = Array2::<f32>::zeros((1, hop));

        let mut saw_difference = false;
        let mut max_output_rms = 0.0f32;

        for frame_idx in 0..frames {
            for i in 0..hop {
                let t = (frame_idx * hop + i) as f32 / sr;
                let clean = 0.08 * (2.0 * std::f32::consts::PI * 220.0 * t).sin()
                    + 0.03 * (2.0 * std::f32::consts::PI * 440.0 * t).sin();
                let noise = 0.02 * (2.0 * std::f32::consts::PI * 1700.0 * t).sin()
                    + 0.01 * (2.0 * std::f32::consts::PI * 3100.0 * t).sin();
                noisy[(0, i)] = clean + noise;
            }

            let lsnr = model
                .process(noisy.view(), enhanced.view_mut())
                .expect("DeepFilterNet process failed");
            assert!(lsnr.is_finite(), "lsnr must be finite, got {lsnr}");

            let mut frame_diff = 0.0f32;
            for i in 0..hop {
                let out = enhanced[(0, i)];
                assert!(out.is_finite(), "enhanced sample must be finite");
                frame_diff += (out - noisy[(0, i)]).abs();
            }

            if frame_diff / hop as f32 > 1e-6 {
                saw_difference = true;
            }

            max_output_rms = max_output_rms.max(frame_rms(&enhanced));
        }

        assert!(saw_difference, "enhanced output never differed from input");
        assert!(
            max_output_rms > 1e-4 && max_output_rms < 1.0,
            "enhanced rms out of expected range: {max_output_rms}"
        );
    }

    #[test]
    fn dfn_tract_timing_against_realtime_budget() {
        let runtime_params = RuntimeParams::default_with_ch(1).with_mask_reduce(ReduceMask::NONE);
        let mut model = DfTract::new(DfParams::default(), &runtime_params)
            .expect("DeepFilterNet init failed for timing test");

        let hop = model.hop_size;
        let sr = model.sr as f32;
        let budget_ms = (hop as f32 / sr) * 1000.0;
        let frames = 300usize;

        let mut noisy = Array2::<f32>::zeros((1, hop));
        let mut enhanced = Array2::<f32>::zeros((1, hop));

        let mut total_us: u128 = 0;
        let mut max_us: u128 = 0;

        for frame_idx in 0..frames {
            for i in 0..hop {
                let t = (frame_idx * hop + i) as f32 / sr;
                noisy[(0, i)] = 0.1 * (2.0 * std::f32::consts::PI * 300.0 * t).sin()
                    + 0.02 * (2.0 * std::f32::consts::PI * 2200.0 * t).sin();
            }

            let t0 = Instant::now();
            model
                .process(noisy.view(), enhanced.view_mut())
                .expect("DeepFilterNet process failed in timing test");
            let us = t0.elapsed().as_micros();
            total_us += us;
            max_us = max_us.max(us);
        }

        let avg_ms = (total_us as f32 / frames as f32) / 1000.0;
        let max_ms = max_us as f32 / 1000.0;
        let load_ratio = avg_ms / budget_ms;

        println!(
            "DFN timing: avg_ms={:.3}, max_ms={:.3}, budget_ms={:.3}, load_ratio={:.2}",
            avg_ms, max_ms, budget_ms, load_ratio
        );

        // Keep this loose; this is environment-dependent. We only assert no obvious runaway.
        assert!(
            avg_ms < budget_ms * 4.0,
            "average processing is far above real-time budget"
        );
    }
}
