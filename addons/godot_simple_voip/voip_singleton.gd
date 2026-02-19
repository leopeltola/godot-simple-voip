extends Node
class_name VOIPSingleton

## Emitted when new voice data is received from a peer.
signal peer_voice_data_received(peer_id: int, pcm_data: PackedVector2Array)
signal debug_stats_updated(stats: Dictionary)

## VOIP will automatically create an audio bus with this name if it doesn't exist.
const BUS_NAME = "VOIP"

## Whether voice should be sent to peers. If false, this client
## will not send voice data to anyone.
@export var sending_voice := true

## If true, outgoing voice is Opus-compressed.
## Disable for debugging to send raw PCM frames over RPC.
@export var use_opus_compression := true

## Capture ring buffer length in seconds.
## Increase this for local multi-instance tests where one window is unfocused.
@export_range(0.1, 5.0, 0.1) var capture_buffer_length_sec := 2.0

## Emit per-second packet timing/count telemetry to help debug dropouts.
@export var debug_packet_stats := true

## Max number of voice packets to send in a single frame when catching up
## after frame hitches or background throttling.
@export var max_packets_per_frame := 64

## The peers whose peer_id is in peer_filter will not be sent voice data.
## Can be used to save bandwidth.
@export var peer_filter: Array[int] = []

var _bus_idx := -1
var _capture: AudioEffectCapture = null
var _encode_opus: OpusCodec
var _decode_opus_by_peer: Dictionary = {}
var _resampler: Resampler
var _opus_sample_rate := 48_000
var _opus_frame_size := 960
var _packet_duration_sec := 0.02
var _input_sample_rate := 48_000
var _input_packet_frames := 960

var _voice_buffer: PackedVector2Array = []
var _voice_read_pos := 0
var _voip_players: Array[AudioStreamPlayer] = []

var _stats_sec_accum := 0.0

var _stats_capture_frames := 0
var _stats_sent_packets := 0
var _stats_sent_bytes := 0
var _stats_server_received_packets := 0
var _stats_server_relay_packets := 0
var _stats_client_received_packets := 0
var _stats_decoded_packets := 0
var _stats_emitted_packets := 0

var _last_send_ts := -1.0
var _send_dt_min := 999.0
var _send_dt_max := 0.0
var _send_dt_sum := 0.0
var _send_dt_count := 0

var _last_recv_ts := -1.0
var _recv_dt_min := 999.0
var _recv_dt_max := 0.0
var _recv_dt_sum := 0.0
var _recv_dt_count := 0

var _process_calls := 0
var _process_dt_sum := 0.0
var _process_dt_max := 0.0
var _last_process_ts := -1.0
var _process_gap_over_100ms := 0

const NETWORK_SAMPLE_RATE := 48_000
const VOIP_PACKET_FRAMES := 960
const VOIP_PACKET_SEC := 0.02

func _ready() -> void:
	_encode_opus = OpusCodec.new()
	_resampler = Resampler.new()
	_opus_sample_rate = _encode_opus.get_sample_rate()
	_opus_frame_size = _encode_opus.get_frame_size()
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
	_capture.buffer_length = capture_buffer_length_sec
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
			_capture.buffer_length = capture_buffer_length_sec
			return
	
	# Add capture if it doesn't exist
	_capture = AudioEffectCapture.new()
	_capture.buffer_length = capture_buffer_length_sec
	AudioServer.add_bus_effect(_bus_idx, _capture)


func _process(delta: float) -> void:
	_process_calls += 1
	_process_dt_sum += delta
	_process_dt_max = maxf(_process_dt_max, delta)
	if multiplayer.multiplayer_peer == null and not _decode_opus_by_peer.is_empty():
		_decode_opus_by_peer.clear()
	var now_sec := Time.get_ticks_usec() / 1_000_000.0
	if _last_process_ts > 0.0:
		if (now_sec - _last_process_ts) > 0.1:
			_process_gap_over_100ms += 1
	_last_process_ts = now_sec

	_refresh_stream_bindings()
	_process_voice()
	_update_debug_stats(delta)


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


func _process_voice() -> void:
	assert(_capture)

	var count := _capture.get_frames_available()
	if count > 0:
		var frames := _capture.get_buffer(count)
		_voice_buffer.append_array(frames)
		_stats_capture_frames += count
	
	# Keep buffer size reasonable to avoid excessive memory usage
	if _available_voice_frames() > 48_000 * 2:
		_voice_read_pos = _voice_buffer.size() - (48_000 * 2)
		_compact_voice_buffer_if_needed()

	if not sending_voice or multiplayer.get_peers().is_empty():
		# Don't keep stale voice when transmission is disabled.
		_voice_buffer.clear()
		_voice_read_pos = 0
		return

	var packets_sent_this_frame := 0
	while _available_voice_frames() >= _input_packet_frames and packets_sent_this_frame < max_packets_per_frame:
		_send_next_packet()
		packets_sent_this_frame += 1


func _send_next_packet() -> void:
	if _available_voice_frames() < _input_packet_frames:
		return

	var from := _voice_read_pos
	var to := _voice_read_pos + _input_packet_frames
	var input_chunk := _voice_buffer.slice(from, to)
	_voice_read_pos = to
	_compact_voice_buffer_if_needed()

	var opus_packet_pcm := _resample_to_network_packet(input_chunk)
	if opus_packet_pcm.size() != _opus_frame_size:
		return

	if use_opus_compression:
		var opus_data := _encode_opus.encode(opus_packet_pcm)
		_stats_sent_bytes += opus_data.size()
		_send_voice_bytes(opus_data)
	else:
		_stats_sent_bytes += opus_packet_pcm.size() * 8
		_send_voice_pcm(opus_packet_pcm)

	_stats_sent_packets += 1
	_mark_send_timing()


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


func _available_voice_frames() -> int:
	return _voice_buffer.size() - _voice_read_pos


func _compact_voice_buffer_if_needed() -> void:
	if _voice_read_pos <= 0:
		return

	if _voice_read_pos >= 4096 or _voice_read_pos * 2 >= _voice_buffer.size():
		_voice_buffer = _voice_buffer.slice(_voice_read_pos)
		_voice_read_pos = 0

func _send_voice_bytes(opus_data: PackedByteArray) -> void:
	if multiplayer.is_server():
		# Server-originated voice: send to all clients.
		for peer_id in multiplayer.get_peers():
			_rpc_client_receive_voice_bytes.rpc_id(peer_id, multiplayer.get_unique_id(), opus_data)
			_stats_server_relay_packets += 1
		return

	# Client-originated voice: upload to server for relay.
	_rpc_server_receive_voice_bytes.rpc_id(1, opus_data)


func _send_voice_pcm(pcm_data: PackedVector2Array) -> void:
	if multiplayer.is_server():
		for peer_id in multiplayer.get_peers():
			_rpc_client_receive_voice_pcm.rpc_id(peer_id, multiplayer.get_unique_id(), pcm_data)
			_stats_server_relay_packets += 1
		return

	_rpc_server_receive_voice_pcm.rpc_id(1, pcm_data)


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_server_receive_voice_bytes(opus_data: PackedByteArray) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		return
	_stats_server_received_packets += 1
	_mark_recv_timing()

	# Play remote client voice on server, if server has matching AudioStreamVOIP players.
	var decoder := _get_decoder_for_peer(sender_id)
	var pcm_data := decoder.decode(opus_data)
	_stats_decoded_packets += 1
	peer_voice_data_received.emit(sender_id, pcm_data)
	_stats_emitted_packets += 1

	# Relay client voice to all other clients.
	for peer_id in multiplayer.get_peers():
		if peer_id == sender_id:
			continue
		_rpc_client_receive_voice_bytes.rpc_id(peer_id, sender_id, opus_data)
		_stats_server_relay_packets += 1


@rpc("authority", "unreliable_ordered", "call_remote")
func _rpc_client_receive_voice_bytes(sender_id: int, opus_data: PackedByteArray) -> void:
	if sender_id == 0:
		return
	_stats_client_received_packets += 1
	_mark_recv_timing()
	var decoder := _get_decoder_for_peer(sender_id)
	var pcm_data := decoder.decode(opus_data)
	_stats_decoded_packets += 1
	peer_voice_data_received.emit(sender_id, pcm_data)
	_stats_emitted_packets += 1


func _get_decoder_for_peer(peer_id: int) -> OpusCodec:
	if _decode_opus_by_peer.has(peer_id):
		return _decode_opus_by_peer[peer_id]

	var decoder := OpusCodec.new()
	_decode_opus_by_peer[peer_id] = decoder
	return decoder


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_server_receive_voice_pcm(pcm_data: PackedVector2Array) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if sender_id == 0:
		return
	_stats_server_received_packets += 1
	_mark_recv_timing()

	peer_voice_data_received.emit(sender_id, pcm_data)
	_stats_emitted_packets += 1

	for peer_id in multiplayer.get_peers():
		if peer_id == sender_id:
			continue
		_rpc_client_receive_voice_pcm.rpc_id(peer_id, sender_id, pcm_data)
		_stats_server_relay_packets += 1


@rpc("authority", "unreliable_ordered", "call_remote")
func _rpc_client_receive_voice_pcm(sender_id: int, pcm_data: PackedVector2Array) -> void:
	_stats_client_received_packets += 1
	_mark_recv_timing()
	peer_voice_data_received.emit(sender_id, pcm_data)
	_stats_emitted_packets += 1


func get_debug_stats_snapshot() -> Dictionary:
	return _build_stats_snapshot()


func _mark_send_timing() -> void:
	var now := Time.get_ticks_usec() / 1_000_000.0
	if _last_send_ts > 0.0:
		var dt := now - _last_send_ts
		_send_dt_min = minf(_send_dt_min, dt)
		_send_dt_max = maxf(_send_dt_max, dt)
		_send_dt_sum += dt
		_send_dt_count += 1
	_last_send_ts = now


func _mark_recv_timing() -> void:
	var now := Time.get_ticks_usec() / 1_000_000.0
	if _last_recv_ts > 0.0:
		var dt := now - _last_recv_ts
		_recv_dt_min = minf(_recv_dt_min, dt)
		_recv_dt_max = maxf(_recv_dt_max, dt)
		_recv_dt_sum += dt
		_recv_dt_count += 1
	_last_recv_ts = now


func _update_debug_stats(delta: float) -> void:
	if not debug_packet_stats:
		return

	_stats_sec_accum += delta
	if _stats_sec_accum < 1.0:
		return

	var snapshot := _build_stats_snapshot()
	debug_stats_updated.emit(snapshot)

	print("[VOIP stats] role=%s mode=%s cap_frames=%d sent_pkt=%d sent_kbps=%.1f srv_in=%d relay=%d cli_in=%d decoded=%d emitted=%d send_dt_ms(avg/min/max)=%.2f/%.2f/%.2f recv_dt_ms(avg/min/max)=%.2f/%.2f/%.2f q_frames=%d peers=%d proc(avg/max)=%.2f/%.2fms proc_gap>100ms=%d" % [
		snapshot["role"],
		snapshot["mode"],
		snapshot["capture_frames"],
		snapshot["sent_packets"],
		snapshot["sent_kbps"],
		snapshot["server_received_packets"],
		snapshot["server_relay_packets"],
		snapshot["client_received_packets"],
		snapshot["decoded_packets"],
		snapshot["emitted_packets"],
		snapshot["send_dt_avg_ms"],
		snapshot["send_dt_min_ms"],
		snapshot["send_dt_max_ms"],
		snapshot["recv_dt_avg_ms"],
		snapshot["recv_dt_min_ms"],
		snapshot["recv_dt_max_ms"],
		snapshot["capture_queue_frames"],
		snapshot["peer_count"],
		snapshot["process_dt_avg_ms"],
		snapshot["process_dt_max_ms"],
		snapshot["process_gap_over_100ms"],
	])

	_reset_stats_window()


func _build_stats_snapshot() -> Dictionary:
	var send_avg := 0.0
	if _send_dt_count > 0:
		send_avg = (_send_dt_sum / float(_send_dt_count)) * 1000.0

	var recv_avg := 0.0
	if _recv_dt_count > 0:
		recv_avg = (_recv_dt_sum / float(_recv_dt_count)) * 1000.0

	var send_min := 0.0
	if _send_dt_min < 998.0:
		send_min = _send_dt_min * 1000.0

	var recv_min := 0.0
	if _recv_dt_min < 998.0:
		recv_min = _recv_dt_min * 1000.0

	var sent_kbps := (float(_stats_sent_bytes) * 8.0) / 1000.0

	return {
		"role": "server" if multiplayer.is_server() else "client",
		"mode": "opus" if use_opus_compression else "pcm",
		"capture_frames": _stats_capture_frames,
		"sent_packets": _stats_sent_packets,
		"sent_bytes": _stats_sent_bytes,
		"sent_kbps": sent_kbps,
		"server_received_packets": _stats_server_received_packets,
		"server_relay_packets": _stats_server_relay_packets,
		"client_received_packets": _stats_client_received_packets,
		"decoded_packets": _stats_decoded_packets,
		"emitted_packets": _stats_emitted_packets,
		"send_dt_avg_ms": send_avg,
		"send_dt_min_ms": send_min,
		"send_dt_max_ms": _send_dt_max * 1000.0,
		"recv_dt_avg_ms": recv_avg,
		"recv_dt_min_ms": recv_min,
		"recv_dt_max_ms": _recv_dt_max * 1000.0,
		"capture_queue_frames": _available_voice_frames(),
		"peer_count": multiplayer.get_peers().size(),
		"process_calls": _process_calls,
		"process_dt_avg_ms": (_process_dt_sum / maxf(1.0, float(_process_calls))) * 1000.0,
		"process_dt_max_ms": _process_dt_max * 1000.0,
		"process_gap_over_100ms": _process_gap_over_100ms,
	}


func _reset_stats_window() -> void:
	_stats_sec_accum = 0.0
	_stats_capture_frames = 0
	_stats_sent_packets = 0
	_stats_sent_bytes = 0
	_stats_server_received_packets = 0
	_stats_server_relay_packets = 0
	_stats_client_received_packets = 0
	_stats_decoded_packets = 0
	_stats_emitted_packets = 0

	_send_dt_min = 999.0
	_send_dt_max = 0.0
	_send_dt_sum = 0.0
	_send_dt_count = 0

	_recv_dt_min = 999.0
	_recv_dt_max = 0.0
	_recv_dt_sum = 0.0
	_recv_dt_count = 0

	_process_calls = 0
	_process_dt_sum = 0.0
	_process_dt_max = 0.0
	_process_gap_over_100ms = 0
