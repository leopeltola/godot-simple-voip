use godot::prelude::*;

#[derive(GodotClass)]
#[class(base=RefCounted)]
pub struct Resampler {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for Resampler {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl Resampler {
    /// Resample audio data using linear interpolation
    /// input_samples: the audio data to resample
    /// input_rate: the sample rate of the input data
    /// output_rate: the desired output sample rate
    #[func]
    pub fn resample(
        &self,
        input_samples: PackedVector2Array,
        input_rate: i32,
        output_rate: i32,
    ) -> PackedVector2Array {
        let input_data = input_samples.to_vec();
        let resampled = linear_resample_stereo(&input_data, input_rate, output_rate);
        PackedVector2Array::from(&resampled[..])
    }
}

/// Linear interpolation resampling function for stereo audio
fn linear_resample_stereo(input: &[Vector2], input_rate: i32, output_rate: i32) -> Vec<Vector2> {
    if input.is_empty() || input_rate <= 0 || output_rate <= 0 {
        return Vec::new();
    }

    let ratio = input_rate as f32 / output_rate as f32;
    let output_length = (input.len() as f32 / ratio).ceil() as usize;
    let mut output = Vec::with_capacity(output_length);

    for i in 0..output_length {
        let src_index = i as f32 * ratio;
        let index_floor = src_index.floor() as usize;
        let index_ceil = (index_floor + 1).min(input.len() - 1);

        if index_floor >= input.len() {
            break;
        }

        if index_floor == index_ceil {
            output.push(input[index_floor]);
        } else {
            let fraction = src_index - index_floor as f32;
            let left = input[index_floor].x * (1.0 - fraction) + input[index_ceil].x * fraction;
            let right = input[index_floor].y * (1.0 - fraction) + input[index_ceil].y * fraction;
            output.push(Vector2::new(left, right));
        }
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_linear_downsample_stereo() {
        let input = vec![
            Vector2::new(0.0, 0.0),
            Vector2::new(1.0, -1.0),
            Vector2::new(0.0, 0.0),
            Vector2::new(-1.0, 1.0),
        ];
        let result = linear_resample_stereo(&input, 4, 2);
        assert_eq!(result.len(), 2);
    }

    #[test]
    fn test_linear_upsample_stereo() {
        let input = vec![
            Vector2::new(0.0, 0.0),
            Vector2::new(1.0, -1.0),
            Vector2::new(0.0, 0.0),
            Vector2::new(-1.0, 1.0),
        ];
        let result = linear_resample_stereo(&input, 4, 8);
        assert_eq!(result.len(), 8);
    }

    #[test]
    fn test_empty_input_stereo() {
        let input = vec![];
        let result = linear_resample_stereo(&input, 48000, 44100);
        assert!(result.is_empty());
    }
}
