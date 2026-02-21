use std::ffi::c_void;
use std::sync::{Arc, Mutex};

use godot::classes::{
    AudioEffect, AudioEffectInstance, AudioServer, IAudioEffect, IAudioEffectInstance,
};
use godot::{classes::native::AudioFrame, prelude::*};

#[derive(Debug, Clone)]
struct NoiseGateParams {
    threshold_db: f32,
    hysteresis_db: f32,
    attack_ms: f32,
    release_ms: f32,
    hold_ms: f32,
    floor_db: f32,
}

impl Default for NoiseGateParams {
    fn default() -> Self {
        Self {
            threshold_db: -45.0,
            hysteresis_db: 6.0,
            attack_ms: 5.0,
            release_ms: 120.0,
            hold_ms: 35.0,
            floor_db: -80.0,
        }
    }
}

#[derive(Debug, Default)]
struct NoiseGateSharedConfig {
    params: NoiseGateParams,
    revision: u64,
}

type NoiseGateSharedConfigRef = Arc<Mutex<NoiseGateSharedConfig>>;

fn db_to_gain(db: f32) -> f32 {
    10.0f32.powf(db / 20.0)
}

fn ms_to_coeff(ms: f32, sample_rate: f32) -> f32 {
    let ms = ms.max(0.0);
    if ms <= 0.0 || sample_rate <= 0.0 {
        return 0.0;
    }

    let seconds = ms * 0.001;
    (-1.0 / (seconds * sample_rate)).exp()
}

/// Adds a configurable noise gate to an audio bus.
///
/// The gate uses mono level detection and applies the same gain envelope to
/// both channels to avoid stereo image drifting.
#[derive(GodotClass)]
#[class(tool, base=AudioEffect)]
pub(crate) struct AudioEffectNoiseGate {
    pub(crate) base: Base<AudioEffect>,
    /// Gate opens when signal level rises above this threshold.
    #[export]
    #[var(get = get_threshold_db, set = set_threshold_db)]
    threshold_db: f32,
    /// Extra dB below threshold required to close the gate.
    #[export]
    #[var(get = get_hysteresis_db, set = set_hysteresis_db)]
    hysteresis_db: f32,
    /// Time to open gate (gain increase), in milliseconds.
    #[export]
    #[var(get = get_attack_ms, set = set_attack_ms)]
    attack_ms: f32,
    /// Time to close gate (gain decrease), in milliseconds.
    #[export]
    #[var(get = get_release_ms, set = set_release_ms)]
    release_ms: f32,
    /// Time to keep gate open after signal falls below close threshold.
    #[export]
    #[var(get = get_hold_ms, set = set_hold_ms)]
    hold_ms: f32,
    /// Gain floor while gate is closed (negative dB, e.g. -80.0).
    #[export]
    #[var(get = get_floor_db, set = set_floor_db)]
    floor_db: f32,
    shared_config: NoiseGateSharedConfigRef,
}

#[godot_api]
impl IAudioEffect for AudioEffectNoiseGate {
    fn init(base: Base<AudioEffect>) -> Self {
        let params = NoiseGateParams::default();
        Self {
            base,
            threshold_db: params.threshold_db,
            hysteresis_db: params.hysteresis_db,
            attack_ms: params.attack_ms,
            release_ms: params.release_ms,
            hold_ms: params.hold_ms,
            floor_db: params.floor_db,
            shared_config: Arc::new(Mutex::new(NoiseGateSharedConfig {
                params,
                revision: 0,
            })),
        }
    }

    fn instantiate(&mut self) -> Option<Gd<AudioEffectInstance>> {
        self.push_config_to_shared();

        let mut effect = AudioEffectNoiseGateInstance::new_gd();
        {
            let mut effect_mut = effect.bind_mut();
            effect_mut.shared_config = self.shared_config.clone();
        }

        Some(effect.upcast::<AudioEffectInstance>())
    }
}

#[godot_api]
impl AudioEffectNoiseGate {
    fn sanitize_hysteresis_db(value: f32) -> f32 {
        value.max(0.0)
    }

    fn sanitize_attack_ms(value: f32) -> f32 {
        value.max(0.0)
    }

    fn sanitize_release_ms(value: f32) -> f32 {
        value.max(0.0)
    }

    fn sanitize_hold_ms(value: f32) -> f32 {
        value.max(0.0)
    }

    fn sanitize_floor_db(value: f32) -> f32 {
        value.min(0.0)
    }

    fn push_config_to_shared(&mut self) {
        if let Ok(mut cfg) = self.shared_config.lock() {
            cfg.params.threshold_db = self.threshold_db;
            cfg.params.hysteresis_db = self.hysteresis_db;
            cfg.params.attack_ms = self.attack_ms;
            cfg.params.release_ms = self.release_ms;
            cfg.params.hold_ms = self.hold_ms;
            cfg.params.floor_db = self.floor_db;
            cfg.revision = cfg.revision.wrapping_add(1);
        }
    }

    #[func]
    fn get_threshold_db(&self) -> f32 {
        self.threshold_db
    }

    #[func]
    fn set_threshold_db(&mut self, value: f32) {
        self.threshold_db = value;
        self.push_config_to_shared();
    }

    #[func]
    fn get_hysteresis_db(&self) -> f32 {
        self.hysteresis_db
    }

    #[func]
    fn set_hysteresis_db(&mut self, value: f32) {
        self.hysteresis_db = Self::sanitize_hysteresis_db(value);
        self.push_config_to_shared();
    }

    #[func]
    fn get_attack_ms(&self) -> f32 {
        self.attack_ms
    }

    #[func]
    fn set_attack_ms(&mut self, value: f32) {
        self.attack_ms = Self::sanitize_attack_ms(value);
        self.push_config_to_shared();
    }

    #[func]
    fn get_release_ms(&self) -> f32 {
        self.release_ms
    }

    #[func]
    fn set_release_ms(&mut self, value: f32) {
        self.release_ms = Self::sanitize_release_ms(value);
        self.push_config_to_shared();
    }

    #[func]
    fn get_hold_ms(&self) -> f32 {
        self.hold_ms
    }

    #[func]
    fn set_hold_ms(&mut self, value: f32) {
        self.hold_ms = Self::sanitize_hold_ms(value);
        self.push_config_to_shared();
    }

    #[func]
    fn get_floor_db(&self) -> f32 {
        self.floor_db
    }

    #[func]
    fn set_floor_db(&mut self, value: f32) {
        self.floor_db = Self::sanitize_floor_db(value);
        self.push_config_to_shared();
    }
}

#[derive(GodotClass)]
#[class(base=AudioEffectInstance)]
pub(crate) struct AudioEffectNoiseGateInstance {
    pub(crate) base: Base<AudioEffectInstance>,
    shared_config: NoiseGateSharedConfigRef,
    applied_revision: u64,

    threshold_open_lin: f32,
    threshold_close_lin: f32,
    floor_gain: f32,
    attack_coeff: f32,
    release_coeff: f32,
    hold_samples: usize,

    envelope: f32,
    gain: f32,
    hold_counter: usize,
    gate_open: bool,
}

impl AudioEffectNoiseGateInstance {
    fn apply_config(&mut self, params: &NoiseGateParams) {
        let sample_rate = AudioServer::singleton().get_mix_rate().max(1.0);

        self.threshold_open_lin = db_to_gain(params.threshold_db);
        self.threshold_close_lin = db_to_gain(params.threshold_db - params.hysteresis_db.max(0.0));
        self.floor_gain = db_to_gain(params.floor_db.min(0.0));

        self.attack_coeff = ms_to_coeff(params.attack_ms, sample_rate);
        self.release_coeff = ms_to_coeff(params.release_ms, sample_rate);

        let hold_samples_f = (params.hold_ms.max(0.0) * 0.001 * sample_rate).round();
        self.hold_samples = hold_samples_f.max(0.0) as usize;
    }

    fn refresh_runtime_config_if_needed(&mut self) {
        let Ok(cfg) = self.shared_config.lock() else {
            return;
        };

        if self.applied_revision == cfg.revision {
            return;
        }

        let revision = cfg.revision;
        let params = cfg.params.clone();
        drop(cfg);

        self.apply_config(&params);
        self.applied_revision = revision;
    }
}

#[godot_api]
impl IAudioEffectInstance for AudioEffectNoiseGateInstance {
    unsafe fn process_rawptr(
        &mut self,
        input: *const c_void,
        output: *mut AudioFrame,
        frame_count: i32,
    ) {
        if frame_count <= 0 {
            return;
        }

        self.refresh_runtime_config_if_needed();

        let frame_count = frame_count as usize;
        let input_slice = std::slice::from_raw_parts(input as *const AudioFrame, frame_count);
        let output_slice = std::slice::from_raw_parts_mut(output, frame_count);

        for (in_frame, out_frame) in input_slice.iter().zip(output_slice.iter_mut()) {
            let level = ((in_frame.left + in_frame.right) * 0.5).abs();

            let detector_coeff = if level > self.envelope {
                self.attack_coeff
            } else {
                self.release_coeff
            };
            self.envelope = level + detector_coeff * (self.envelope - level);

            if self.gate_open {
                if self.envelope < self.threshold_close_lin {
                    if self.hold_counter < self.hold_samples {
                        self.hold_counter += 1;
                    } else {
                        self.gate_open = false;
                    }
                } else {
                    self.hold_counter = 0;
                }
            } else if self.envelope >= self.threshold_open_lin {
                self.gate_open = true;
                self.hold_counter = 0;
            }

            let target_gain = if self.gate_open { 1.0 } else { self.floor_gain };
            let gain_coeff = if target_gain > self.gain {
                self.attack_coeff
            } else {
                self.release_coeff
            };
            self.gain = target_gain + gain_coeff * (self.gain - target_gain);

            out_frame.left = in_frame.left * self.gain;
            out_frame.right = in_frame.right * self.gain;
        }
    }

    fn init(base: Base<AudioEffectInstance>) -> Self {
        let defaults = NoiseGateParams::default();
        let sample_rate = AudioServer::singleton().get_mix_rate().max(1.0);

        let threshold_open_lin = db_to_gain(defaults.threshold_db);
        let threshold_close_lin =
            db_to_gain(defaults.threshold_db - defaults.hysteresis_db.max(0.0));
        let floor_gain = db_to_gain(defaults.floor_db.min(0.0));
        let attack_coeff = ms_to_coeff(defaults.attack_ms, sample_rate);
        let release_coeff = ms_to_coeff(defaults.release_ms, sample_rate);
        let hold_samples = ((defaults.hold_ms * 0.001 * sample_rate).round()).max(0.0) as usize;

        Self {
            base,
            shared_config: Arc::default(),
            applied_revision: 0,
            threshold_open_lin,
            threshold_close_lin,
            floor_gain,
            attack_coeff,
            release_coeff,
            hold_samples,
            envelope: 0.0,
            gain: floor_gain,
            hold_counter: 0,
            gate_open: false,
        }
    }
}
