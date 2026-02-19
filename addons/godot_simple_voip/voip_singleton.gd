extends Node
class_name VOIPSingleton

## Emitted when new voice data is received from a peer.
signal peer_voice_data_received(peer_id: int, pcm_data: PackedVector2Array)

## VOIP will automatically create an audio bus with this name if it doesn't exist.
const BUS_NAME = "VOIP"

## Whether voice should be sent to peers. If false, this client
## will not send voice data to anyone.
@export var sending_voice := true

## If true, outgoing voice is Opus-compressed.
## Disable for debugging to send raw PCM frames over RPC.
@export var use_opus_compression := true

## The peers whose peer_id is in peer_filter will not be sent voice data.
## Can be used to save bandwidth.
@export var peer_filter: Array[int] = []

var _bus_idx := -1
var _capture: AudioEffectCapture = null
var _opus: OpusCodec
var _resampler: Resampler
var _opus_sample_rate := 48_000
var _opus_frame_size := 960
var _packet_duration_sec := 0.02
var _send_accumulator_sec := 0.0
var _input_sample_rate := 48_000
var _input_packet_frames := 960

var _voice_buffer: PackedVector2Array = []
var _voip_players: Array[AudioStreamPlayer] = []

const NETWORK_SAMPLE_RATE := 48_000
const VOIP_PACKET_FRAMES := 960
const VOIP_PACKET_SEC := 0.02

func _ready() -> void:
	_opus = OpusCodec.new()
	_resampler = Resampler.new()
	_opus_sample_rate = _opus.get_sample_rate()
	_opus_frame_size = _opus.get_frame_size()
	_packet_duration_sec = float(_opus_frame_size) / float(_opus_sample_rate)
	_input_sample_rate = int(AudioServer.get_mix_rate())
	_input_packet_frames = maxi(1, int(round(_input_sample_rate * _packet_duration_sec)))
	_setup_bus()
	_track_existing_players()
	get_tree().node_added.connect(_on_node_added)


func get_opus_sample_rate() -> int:
	return _opus_sample_rate


func get_opus_frame_size() -> int:
	return _opus_frame_size


func _setup_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(BUS_NAME)
	
	if _bus_idx != -1:
		# Bus exists, verify it has capture
		_verify_and_add_capture()
		return
	
	# Create new bus if it doesn't exist
	_bus_idx = AudioServer.bus_count
	AudioServer.add_bus(_bus_idx)
	AudioServer.set_bus_name(_bus_idx, BUS_NAME)
	
	# Add audio effects to process voice
	
	# Remove constant noise from the background
	var high_pass := AudioEffectHighPassFilter.new()
	high_pass.cutoff_hz = 100.0
	AudioServer.add_bus_effect(_bus_idx, high_pass)
	
	var low_pass := AudioEffectLowPassFilter.new()
	low_pass.cutoff_hz = 8000.0
	AudioServer.add_bus_effect(_bus_idx, low_pass)
	
	# Remove noise using neural network
	var rnnoise := AudioEffectRNNoise.new()
	AudioServer.add_bus_effect(_bus_idx, rnnoise)
	
	# Compress the louder sounds to be quieter
	var compressor := AudioEffectCompressor.new()
	compressor.threshold = -16
	AudioServer.add_bus_effect(_bus_idx, compressor)
	
	# Amplify everything to offset the compression
	var amplify := AudioEffectAmplify.new()
	amplify.volume_db = 16.0
	AudioServer.add_bus_effect(_bus_idx, amplify)
	
	# Ensure no clipping
	var limiter := AudioEffectHardLimiter.new()
	AudioServer.add_bus_effect(_bus_idx, limiter)
	
	# For capturing the mic input
	_capture = AudioEffectCapture.new()
	AudioServer.add_bus_effect(_bus_idx, _capture)
	
	# Silence the player's own mic locally after it's been captured
	var silence := AudioEffectAmplify.new()
	silence.volume_db = -70.0
	AudioServer.add_bus_effect(_bus_idx, silence)


func _verify_and_add_capture() -> void:
	# Check if capture effect already exists
	for i in range(AudioServer.get_bus_effect_count(_bus_idx)):
		if AudioServer.get_bus_effect(_bus_idx, i) is AudioEffectCapture:
			_capture = AudioServer.get_bus_effect(_bus_idx, i)
			return
	
	# Add capture if it doesn't exist
	_capture = AudioEffectCapture.new()
	AudioServer.add_bus_effect(_bus_idx, _capture)


func _process(delta: float) -> void:
	_refresh_stream_bindings()
	_process_voice(delta)


func _on_node_added(node: Node) -> void:
	if node is AudioStreamPlayer:
		var player := node as AudioStreamPlayer
		if player.stream is AudioStreamVOIP and not _voip_players.has(player):
			_voip_players.append(player)


func _track_existing_players() -> void:
	_collect_voip_players(get_tree().root)


func _collect_voip_players(node: Node) -> void:
	if node is AudioStreamPlayer:
		var player := node as AudioStreamPlayer
		if player.stream is AudioStreamVOIP and not _voip_players.has(player):
			_voip_players.append(player)

	for child in node.get_children():
		if child is Node:
			_collect_voip_players(child)


func _refresh_stream_bindings() -> void:
	for i in range(_voip_players.size() - 1, -1, -1):
		var player := _voip_players[i]
		if not is_instance_valid(player):
			_voip_players.remove_at(i)
			continue

		if not (player.stream is AudioStreamVOIP):
			_voip_players.remove_at(i)
			continue

		if not player.playing:
			continue

		var playback := player.get_stream_playback()
		if playback == null:
			continue

		var stream := player.stream as AudioStreamVOIP
		stream.configure_stream(_opus_sample_rate, _opus_frame_size)
		stream.bind_playback(playback)
		stream.pump_playback()


func _process_voice(delta: float) -> void:
	assert(_capture)

	var count := _capture.get_frames_available()
	if count > 0:
		var frames := _capture.get_buffer(count)
		_voice_buffer.append_array(frames)
	
	# Keep buffer size reasonable to avoid excessive memory usage
	if _voice_buffer.size() > 48_000 * 2:
		_voice_buffer = _voice_buffer.slice(_voice_buffer.size() - 48_000)

	if not sending_voice or multiplayer.get_peers().is_empty():
		# Don't keep stale voice when transmission is disabled.
		_voice_buffer.clear()
		_send_accumulator_sec = 0.0
		return

	_send_accumulator_sec += delta
	# Avoid runaway backlog after pauses/hitches.
	_send_accumulator_sec = minf(_send_accumulator_sec, _packet_duration_sec * 4.0)

	while _send_accumulator_sec >= _packet_duration_sec and _voice_buffer.size() >= _input_packet_frames:
		_send_accumulator_sec -= _packet_duration_sec
		_send_next_packet()


func _send_next_packet() -> void:
	if _voice_buffer.size() < _input_packet_frames:
		return

	var input_chunk := _voice_buffer.slice(0, _input_packet_frames)
	_voice_buffer = _voice_buffer.slice(_input_packet_frames)

	var opus_packet_pcm := _resample_to_network_packet(input_chunk)
	if opus_packet_pcm.size() != _opus_frame_size:
		return

	if use_opus_compression:
		var opus_data := _opus.encode(opus_packet_pcm)
		_rpc_receive_voice_bytes.rpc(opus_data)
	else:
		_rpc_receive_voice_pcm.rpc(opus_packet_pcm)


func _resample_to_network_packet(input_frames: PackedVector2Array) -> PackedVector2Array:
	if _input_sample_rate == _opus_sample_rate:
		if input_frames.size() == _opus_frame_size:
			return input_frames
		# Keep packet size exact.
		var exact := input_frames.duplicate()
		exact.resize(_opus_frame_size)
		return exact

	var resampled := _resampler.resample(input_frames, _input_sample_rate, _opus_sample_rate)
	if resampled.size() != _opus_frame_size:
		var exact := resampled.duplicate()
		exact.resize(_opus_frame_size)
		return exact

	return resampled


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_receive_voice_bytes(data: PackedByteArray) -> void:
	var pcm_data := _opus.decode(data)
	peer_voice_data_received.emit(
		multiplayer.get_remote_sender_id(),
		pcm_data,
	)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_receive_voice_pcm(pcm_data: PackedVector2Array) -> void:
	peer_voice_data_received.emit(
		multiplayer.get_remote_sender_id(),
		pcm_data,
	)
