extends Node
class_name MultiplayerVOIP

## Synchronizes properties from the multiplayer authority to the remote peers.
##
## By default, VOIP sends the voice data to all connected peers.
## Which peers get sent voice data can be configured through `peer_filter`.

## Emitted when new voice data is received from a peer.
signal peer_voice_data_received(peer_id: int, pcm_data: PackedVector2Array)

## VOIP will automatically create an audio bus with this name. 
const BUS_NAME = "VOIP"

## Whether voice should be sent to peers. If false, this client
## will not send voice data to anyone.
@export var sending_voice := true
## The peers whose peer_id is in peer_filter will not be sent voice data.
## Can be used to save bandwidth.
@export var peer_filter: Array[int] = []

var _bus_idx := -1
var _capture: AudioEffectCapture = null
var _opus: OpusCodec

var _voice_buffer: PackedVector2Array = []
var _print_next := false

var _players: Array[Node] = []

func _ready() -> void:
	_opus = OpusCodec.new()
	_setup_bus()
	
	get_tree().node_added.connect(
		func(node: Node):
			if (
				node is AudioStreamPlayer
				or node is AudioStreamPlayer2D
				or node is AudioStreamPlayer3D
			):
				_players.append(node)
	)


func _setup_bus() -> void:
	if AudioServer.get_bus_index("Mic") != -1:
		# Bus has been set up manually
		# TODO check that it has capture
		return 
	_bus_idx = AudioServer.bus_count
	AudioServer.add_bus(_bus_idx)
	AudioServer.set_bus_name(_bus_idx, BUS_NAME)
	
	var player := AudioStreamPlayer.new()
	player.bus = BUS_NAME
	add_child(player, true, Node.INTERNAL_MODE_BACK)
	
	# Remove constant noise from the bg in case some gets through
	var high_pass := AudioEffectHighPassFilter.new()
	high_pass.cutoff_hz = 100.0
	AudioServer.add_bus_effect(_bus_idx, high_pass)
	
	var low_pass := AudioEffectLowPassFilter.new()
	low_pass.cutoff_hz = 8000.0
	AudioServer.add_bus_effect(_bus_idx, low_pass)
	
	# Remove noise, neural network
	var rnnoise := AudioEffectRNNoise.new()
	AudioServer.add_bus_effect(_bus_idx, rnnoise)
	
	# Compress the louder sounds to be quieter
	var compressor := AudioEffectCompressor.new()
	compressor.threshold = -16
	AudioServer.add_bus_effect(_bus_idx, compressor)
	
	# Amplify everything to offset the prev quieting
	# => speech with low volume is louder, more audible
	var amplify := AudioEffectAmplify.new()
	amplify.volume_db = 16.0
	AudioServer.add_bus_effect(_bus_idx, amplify)
	
	# Ensure no clipping just in case
	var limiter := AudioEffectHardLimiter.new()
	AudioServer.add_bus_effect(_bus_idx, limiter)
	
	# For capturing the mic input
	_capture = AudioEffectCapture.new()
	AudioServer.add_bus_effect(_bus_idx, _capture)
	
	# Silences the player's own mic locally after it's been captured
	var silence := AudioEffectAmplify.new()
	silence.volume_db = -70.0
	AudioServer.add_bus_effect(_bus_idx, silence)


func _physics_process(delta: float) -> void:
	_process_voice()


func _process_voice() -> void:
	if _voice_buffer.size() > 48_000*2:
		_voice_buffer = _voice_buffer.slice(_voice_buffer.size() - 48_000, _voice_buffer.size())
	if _print_next:
		_print_next = false
		var count := _capture.get_frames_available()
		var frames := _capture.get_buffer(count)
		_voice_buffer.append_array(frames)
		if _voice_buffer.size() >= 960:
			var to_encode := _voice_buffer.duplicate()
			_voice_buffer = _voice_buffer.slice(960, _voice_buffer.size())
			#for v in to_encode:
				#print(v)
			to_encode.resize(960)
			var opus_data := _opus.encode(to_encode)
			var decoded := _opus.decode(opus_data)
			for i in to_encode.size():
				print("%s -> %s" % [to_encode[i], decoded[i]])
			#if multiplayer.is_server():
				#print(opus_data)
	if not sending_voice or multiplayer.get_peers().is_empty():
		return
	
	assert(_capture)
	
	var count := _capture.get_frames_available()
	var frames := _capture.get_buffer(count)
	_voice_buffer.append_array(frames)
	
	while _voice_buffer.size() >= 960:
		var to_encode := _voice_buffer.duplicate()
		_voice_buffer = _voice_buffer.slice(960, _voice_buffer.size())
		to_encode.resize(960)
		var opus_data := _opus.encode(to_encode)
	
		_rpc_receive_voice_bytes.rpc(opus_data, count)
	#rpc_receive_voice_vecs.rpc(frames)


func get_player_for_stream(stream: AudioStream) -> Node:
	for pl in _players:
		if pl.stream == stream:
			return pl
	return null


@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_receive_voice_bytes(data: PackedByteArray, count: int) -> void:
	assert(data is PackedByteArray)
	var pcm_data := _opus.decode(data)
	#if not multiplayer.is_server():
		#print("Received pcm data from server: ", pcm_data)
	peer_voice_data_received.emit(
		multiplayer.get_remote_sender_id(), 
		pcm_data,
	)

@rpc("any_peer", "unreliable_ordered", "call_remote")
func _rpc_receive_voice_vecs(pcm_data: PackedVector2Array) -> void:
	assert(pcm_data is PackedVector2Array)
	peer_voice_data_received.emit(
		multiplayer.get_remote_sender_id(), 
		pcm_data,
	)
