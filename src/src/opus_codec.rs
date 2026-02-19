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
    #[allow(dead_code)]
    base: Base<RefCounted>,
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
        // Convert stereo to mono by averaging left and right channels
        debug_assert!(pcm_data.len() == FRAME_SIZE);
        let vec: Vec<f32> = pcm_data
            .as_slice()
            .iter()
            .map(|vec| (vec.x + vec.y) * 0.5)
            .collect();

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
        let mut output: Vec<f32> = vec![0.; FRAME_SIZE];

        // TODO lost packet handling with fec
        let result =
            self.decoder
                .decode_float(opus_packet.as_slice(), output.as_mut_slice(), false);

        match result {
            Ok(_decoded_samples) => {
                // Convert mono to stereo by duplicating the channel
                return PackedVector2Array::from(
                    output
                        .iter()
                        .map(|num| Vector2::new(*num, *num))
                        .collect::<Vec<_>>(),
                );
            }
            Err(e) => {
                godot_error!("Opus decode error: {:?}", e);
                return PackedVector2Array::new();
            }
        }
    }
}
