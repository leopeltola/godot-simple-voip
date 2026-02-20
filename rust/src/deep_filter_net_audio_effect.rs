use std::ffi::c_void;
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use df::tract::{DfParams, DfTract, ReduceMask, RuntimeParams};
use godot::classes::{
    AudioEffect, AudioEffectInstance, AudioServer, IAudioEffect, IAudioEffectInstance,
};
use godot::{classes::native::AudioFrame, prelude::*};
use ndarray::Array2;
use ringbuf::{traits::*, HeapCons, HeapProd, HeapRb};

const DFN_RING_CAPACITY_SAMPLES: usize = 48_000;
const WORKER_IDLE_SLEEP_MICROS: u64 = 250;

type RbProd = HeapProd<f32>;
type RbCons = HeapCons<f32>;

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

struct DeepFilterWorker {
    input_producer: RbProd,
    output_consumer: RbCons,
    stop_flag: Arc<AtomicBool>,
    thread_handle: Option<JoinHandle<()>>,
}

impl DeepFilterWorker {
    fn stop(&mut self) {
        self.stop_flag.store(true, Ordering::Relaxed);
        if let Some(handle) = self.thread_handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for DeepFilterWorker {
    fn drop(&mut self) {
        self.stop();
    }
}

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
    worker: Option<DeepFilterWorker>,
    input_scratch: Vec<f32>,
    output_scratch: Vec<f32>,
    last_output_sample: f32,
    dropped_input_samples: u64,
}

impl AudioEffectDeepFilterNetInstance {
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

    fn stop_worker(&mut self) {
        if let Some(worker) = self.worker.as_mut() {
            worker.stop();
        }
        self.worker = None;
    }

    fn start_worker_with_params(&mut self, params: DeepFilterParams) {
        let mix_rate = AudioServer::singleton().get_mix_rate();
        if (mix_rate as i32) != 48_000 {
            godot_error!(
                "AudioEffectDeepFilterNet: unsupported mix rate {} Hz. DeepFilterNet expects 48000 Hz. Falling back to passthrough.",
                mix_rate
            );
            return;
        }

        let in_rb = HeapRb::<f32>::new(DFN_RING_CAPACITY_SAMPLES);
        let out_rb = HeapRb::<f32>::new(DFN_RING_CAPACITY_SAMPLES);
        let (input_producer, mut input_consumer) = in_rb.split();
        let (mut output_producer, output_consumer) = out_rb.split();

        let stop_flag = Arc::new(AtomicBool::new(false));
        let stop_flag_worker = stop_flag.clone();

        let thread_handle = match thread::Builder::new()
            .name("dfn_worker".to_string())
            .spawn(move || {
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
                let mut denoiser = match DfTract::new(DfParams::default(), &runtime_params) {
                    Ok(model) => {
                        godot_print!(
                            "AudioEffectDeepFilterNet: model initialized (hop_size={}, load_time_ms={}).",
                            model.hop_size,
                            t0.elapsed().as_millis()
                        );
                        model
                    }
                    Err(err) => {
                        AudioEffectDeepFilterNetInstance::log_init_error(&err);
                        godot_error!(
                            "AudioEffectDeepFilterNet: Falling back to passthrough. load_time_ms={}",
                            t0.elapsed().as_millis()
                        );
                        return;
                    }
                };

                let hop_size = denoiser.hop_size;
                let mut in_chunk = vec![0.0f32; hop_size];
                let mut noisy_frame = Array2::zeros((1, hop_size));
                let mut enhanced_frame = Array2::zeros((1, hop_size));

                let mut chunk_process_count: u64 = 0;
                let mut chunk_process_total_us: u128 = 0;
                let mut chunk_process_max_us: u128 = 0;

                while !stop_flag_worker.load(Ordering::Relaxed) {
                    if input_consumer.occupied_len() < hop_size {
                        thread::sleep(Duration::from_micros(WORKER_IDLE_SLEEP_MICROS));
                        continue;
                    }

                    let popped = input_consumer.pop_slice(&mut in_chunk);
                    if popped < hop_size {
                        in_chunk[popped..hop_size].fill(0.0);
                    }

                    if let Some(noisy_slice) = noisy_frame.as_slice_mut() {
                        noisy_slice.copy_from_slice(&in_chunk);
                    }

                    let t_chunk = Instant::now();
                    let out_slice: &[f32] = match denoiser
                        .process(noisy_frame.view(), enhanced_frame.view_mut())
                    {
                        Ok(_) => enhanced_frame.as_slice().unwrap_or(&in_chunk),
                        Err(err) => {
                            godot_error!(
                                "AudioEffectDeepFilterNet: process failed in worker, using dry chunk. {:?}",
                                err
                            );
                            &in_chunk
                        }
                    };

                    let elapsed_us = t_chunk.elapsed().as_micros();
                    chunk_process_count = chunk_process_count.saturating_add(1);
                    chunk_process_total_us = chunk_process_total_us.saturating_add(elapsed_us);
                    chunk_process_max_us = chunk_process_max_us.max(elapsed_us);

                    if chunk_process_count % 200 == 0 {
                        let avg_us = chunk_process_total_us / chunk_process_count as u128;
                        let avg_ms = avg_us as f32 / 1000.0;
                        let max_ms = chunk_process_max_us as f32 / 1000.0;
                        let budget_ms = (hop_size as f32 / 48_000.0) * 1000.0;
                        // godot_print!(
                        //     "AudioEffectDeepFilterNet: chunk timing avg_ms={:.3} max_ms={:.3} budget_ms={:.3} load_ratio={:.2}",
                        //     avg_ms,
                        //     max_ms,
                        //     budget_ms,
                        //     avg_ms / budget_ms
                        // );
                    }

                    let mut written = 0usize;
                    while written < hop_size && !stop_flag_worker.load(Ordering::Relaxed) {
                        written += output_producer.push_slice(&out_slice[written..]);
                        if written < hop_size {
                            thread::yield_now();
                        }
                    }
                }
            })
        {
            Ok(handle) => handle,
            Err(err) => {
                godot_error!(
                    "AudioEffectDeepFilterNet: failed to spawn worker thread: {}",
                    err
                );
                return;
            }
        };

        self.worker = Some(DeepFilterWorker {
            input_producer,
            output_consumer,
            stop_flag,
            thread_handle: Some(thread_handle),
        });
    }

    fn refresh_runtime_config_if_needed(&mut self) {
        let Ok(cfg) = self.shared_config.lock() else {
            return;
        };

        if self.applied_revision == cfg.revision && self.worker.is_some() {
            return;
        }

        let revision = cfg.revision;
        let params = cfg.params.clone();
        drop(cfg);

        self.stop_worker();
        self.applied_revision = revision;
        self.start_worker_with_params(params);
    }

    fn ensure_scratch_capacity(&mut self, frame_count: usize) {
        if self.input_scratch.len() < frame_count {
            self.input_scratch.resize(frame_count, 0.0);
        }
        if self.output_scratch.len() < frame_count {
            self.output_scratch.resize(frame_count, 0.0);
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
        self.ensure_scratch_capacity(frame_count);

        if self.worker.is_none() {
            for (in_frame, out_frame) in input_slice.iter().zip(output_slice.iter_mut()) {
                out_frame.left = in_frame.left;
                out_frame.right = in_frame.right;
            }
            return;
        }

        let mono_input = &mut self.input_scratch[..frame_count];
        for (dst, frame) in mono_input.iter_mut().zip(input_slice.iter()) {
            *dst = (frame.left + frame.right) * 0.5;
        }

        if let Some(worker) = self.worker.as_mut() {
            let pushed = worker.input_producer.push_slice(mono_input);
            if pushed < frame_count {
                self.dropped_input_samples = self
                    .dropped_input_samples
                    .saturating_add((frame_count - pushed) as u64);
                if self.dropped_input_samples % 48_000 == 0 {
                    godot_print!(
                        "AudioEffectDeepFilterNet: dropped_input_samples={}",
                        self.dropped_input_samples
                    );
                }
            }
        }

        let mut processed_samples = 0usize;
        if let Some(worker) = self.worker.as_mut() {
            processed_samples = worker
                .output_consumer
                .pop_slice(&mut self.output_scratch[..frame_count]);
        }

        for i in 0..processed_samples {
            let sample = self.output_scratch[i];
            self.last_output_sample = sample;
            output_slice[i].left = sample;
            output_slice[i].right = sample;
        }

        for i in processed_samples..frame_count {
            let sample = mono_input[i];
            self.last_output_sample = sample;
            output_slice[i].left = sample;
            output_slice[i].right = sample;
        }
    }

    fn init(base: Base<AudioEffectInstance>) -> Self {
        Self {
            base,
            shared_config: Arc::default(),
            applied_revision: 0,
            worker: None,
            input_scratch: Vec::with_capacity(2048),
            output_scratch: Vec::with_capacity(2048),
            last_output_sample: 0.0,
            dropped_input_samples: 0,
        }
    }
}

impl Drop for AudioEffectDeepFilterNetInstance {
    fn drop(&mut self) {
        self.stop_worker();
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
