use godot::prelude::*;
use opus::{Decoder, Encoder};

const FRAME_SIZE: usize = 960;
const MIX_RATE: usize = 48_000;

#[derive(GodotClass, Debug)]
#[class(init, base=RefCounted)]
struct OpusStream {}

#[derive(GodotClass, Debug)]
#[class(base=RefCounted)]
/// OpusCodec provides functionality to encode and decode audio
/// data to optimized PackedByteArrays.
///
/// PCM data is assumed to be in the format used by Godot, PackedVector2Array
/// with values in range (-1.0, 1.0).
pub(crate) struct OpusCodec {
    encoder: Encoder,
    decoder: Decoder,
    encode_resampler: StreamingStereoResampler,
    decode_resampler: StreamingStereoResampler,
    #[allow(dead_code)]
    base: Base<RefCounted>,
}

#[derive(Debug)]
struct StreamingStereoResampler {
    input_rate: usize,
    output_rate: usize,
    step: f32,
    position: f32,
    buffered_input: Vec<Vector2>,
}

impl StreamingStereoResampler {
    fn new(input_rate: usize, output_rate: usize) -> Self {
        let mut resampler = Self {
            input_rate,
            output_rate,
            step: 1.0,
            position: 0.0,
            buffered_input: Vec::new(),
        };
        resampler.recompute_step();
        resampler
    }

    fn set_rates(&mut self, input_rate: usize, output_rate: usize) {
        if self.input_rate == input_rate && self.output_rate == output_rate {
            return;
        }

        self.input_rate = input_rate;
        self.output_rate = output_rate;
        self.position = 0.0;
        self.buffered_input.clear();
        self.recompute_step();
    }

    fn process(&mut self, input: &[Vector2], output_frames: usize) -> Vec<Vector2> {
        if output_frames == 0 || self.input_rate == 0 || self.output_rate == 0 {
            return Vec::new();
        }

        if !input.is_empty() {
            self.buffered_input.extend_from_slice(input);
        }

        let mut output = Vec::with_capacity(output_frames);
        while output.len() < output_frames {
            let index_floor = self.position.floor() as usize;
            if index_floor >= self.buffered_input.len() {
                break;
            }

            let index_ceil = index_floor + 1;
            if index_ceil >= self.buffered_input.len() {
                output.push(self.buffered_input[index_floor]);
                self.position += self.step;
                continue;
            }

            let fraction = self.position - index_floor as f32;
            let a = self.buffered_input[index_floor];
            let b = self.buffered_input[index_ceil];
            let left = a.x * (1.0 - fraction) + b.x * fraction;
            let right = a.y * (1.0 - fraction) + b.y * fraction;
            output.push(Vector2::new(left, right));

            self.position += self.step;
        }

        let consumed = self.position.floor() as usize;
        if consumed > 0 {
            let capped = consumed.min(self.buffered_input.len());
            self.buffered_input.drain(0..capped);
            self.position -= capped as f32;
            if self.position < 0.0 {
                self.position = 0.0;
            }
        }

        if output.len() < output_frames {
            let pad = output
                .last()
                .copied()
                .or_else(|| self.buffered_input.last().copied())
                .unwrap_or(Vector2::new(0.0, 0.0));
            output.resize(output_frames, pad);
        }

        output
    }

    fn recompute_step(&mut self) {
        self.step = self.input_rate as f32 / self.output_rate as f32;
    }
}

fn sanitize_sample_rate(rate: i32) -> usize {
    if rate <= 0 {
        MIX_RATE
    } else {
        rate as usize
    }
}

fn frame_count_for_output_rate(output_sample_rate: usize) -> usize {
    ((output_sample_rate as f32 * FRAME_SIZE as f32) / MIX_RATE as f32).round() as usize
}

#[godot_api]
impl IRefCounted for OpusCodec {
    fn init(base: Base<RefCounted>) -> Self {
        let mut en = Encoder::new(
            MIX_RATE as u32,
            opus::Channels::Mono,
            opus::Application::Voip,
        )
        .unwrap();
        en.set_bitrate(opus::Bitrate::Auto).unwrap();
        Self {
            encoder: en,
            decoder: Decoder::new(MIX_RATE as u32, opus::Channels::Mono).unwrap(),
            encode_resampler: StreamingStereoResampler::new(MIX_RATE, MIX_RATE),
            decode_resampler: StreamingStereoResampler::new(MIX_RATE, MIX_RATE),
            base,
        }
    }
}

#[godot_api]
impl OpusCodec {
    /// Get the frame size. This is how large the Opus packets are.
    #[func]
    fn get_frame_size(&self) -> i32 {
        FRAME_SIZE as i32 // 10ms at 48kHz
    }

    /// Get the used sample rate in hertz.
    #[func]
    fn get_sample_rate(&self) -> i32 {
        MIX_RATE as i32
    }

    /// Encode PCM data to Opus. Input should be exactly get_frame_size long.
    #[func]
    fn encode(&mut self, pcm_data: PackedVector2Array) -> PackedByteArray {
        self.encode_with_sample_rate(pcm_data, MIX_RATE as i32)
    }

    /// Encode PCM data to Opus while accepting arbitrary input sample rates.
    #[func]
    fn encode_with_sample_rate(
        &mut self,
        pcm_data: PackedVector2Array,
        input_sample_rate: i32,
    ) -> PackedByteArray {
        let input_rate = sanitize_sample_rate(input_sample_rate);
        self.encode_resampler.set_rates(input_rate, MIX_RATE);

        let resampled = self
            .encode_resampler
            .process(pcm_data.as_slice(), FRAME_SIZE);

        // Convert stereo to mono by averaging left and right channels
        let vec: Vec<f32> = resampled.iter().map(|vec| (vec.x + vec.y) * 0.5).collect();

        // Ensure we have exactly FRAME_SIZE samples
        if vec.len() != FRAME_SIZE {
            godot_error!(
                "OpusCodec: Expected {} samples, got {}. Returning nothing...",
                FRAME_SIZE,
                vec.len()
            );
            return PackedByteArray::new();
        }

        // Use a reasonable max size (should be much larger than needed for most cases)
        let max_size = 4000;
        let res = self.encoder.encode_vec_float(&vec, max_size);
        match res {
            Ok(value) => return PackedByteArray::from(value),
            Err(e) => {
                godot_error!("Opus encode error: {:?}", e);
            }
        }
        PackedByteArray::new()
    }

    /// Decode a Opus packet to PCM data.
    #[func]
    fn decode(&mut self, opus_packet: PackedByteArray) -> PackedVector2Array {
        self.decode_with_sample_rate(opus_packet, MIX_RATE as i32)
    }

    /// Decode an Opus packet and resample to the requested output sample rate.
    #[func]
    fn decode_with_sample_rate(
        &mut self,
        opus_packet: PackedByteArray,
        output_sample_rate: i32,
    ) -> PackedVector2Array {
        let mut output: Vec<f32> = vec![0.; FRAME_SIZE];

        // TODO lost packet handling with fec
        let result =
            self.decoder
                .decode_float(opus_packet.as_slice(), output.as_mut_slice(), false);

        match result {
            Ok(decoded_samples) => {
                let decoded_samples = decoded_samples.min(FRAME_SIZE);
                let decoded_stereo: Vec<Vector2> = output[..decoded_samples]
                    .iter()
                    .map(|num| Vector2::new(*num, *num))
                    .collect();

                let out_rate = sanitize_sample_rate(output_sample_rate);
                if out_rate == MIX_RATE {
                    return PackedVector2Array::from(decoded_stereo);
                }

                self.decode_resampler.set_rates(MIX_RATE, out_rate);
                let target_frames = frame_count_for_output_rate(out_rate).max(1);
                let resampled = self
                    .decode_resampler
                    .process(decoded_stereo.as_slice(), target_frames);
                return PackedVector2Array::from(resampled);
            }
            Err(e) => {
                godot_error!("Opus decode error: {:?}", e);
                return PackedVector2Array::new();
            }
        }
    }
}
