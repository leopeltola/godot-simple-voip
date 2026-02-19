extends Control

const CAPTURE_BUS_NAME := "OpusLoopbackCapture"

@onready var _toggle_button: Button = %ToggleButton
@onready var _info_label: Label = %InfoLabel
@onready var _stats_label: Label = %StatsLabel

var _capture: AudioEffectCapture = null
var _opus: OpusCodec

var _frame_size := 960
var _sample_rate := 48_000

var _mic_player: AudioStreamPlayer
var _out_player: AudioStreamPlayer
var _out_playback: AudioStreamGeneratorPlayback = null

var _capture_buffer: PackedVector2Array = PackedVector2Array()
var _decoded_buffer: PackedVector2Array = PackedVector2Array()

var _running := true
var _encoded_packets := 0
var _decoded_packets := 0
var _stats_accum_sec := 0.0


func _ready() -> void:
	_opus = OpusCodec.new()
	_frame_size = _opus.get_frame_size()
	_sample_rate = _opus.get_sample_rate()

	_setup_capture_bus()
	_setup_players()

	_toggle_button.pressed.connect(_on_toggle_pressed)
	_toggle_button.text = "Stop loopback"
	_info_label.text = "Opus loopback: mic -> encode -> decode -> playback (Master)\nOpus rate: %d Hz, frame: %d samples" % [_sample_rate, _frame_size]


func _process(delta: float) -> void:
	if not _running:
		return

	_capture_and_encode_decode()
	_flush_decoded_to_playback()

	_stats_accum_sec += delta
	if _stats_accum_sec >= 1.0:
		_stats_accum_sec = 0.0
		_stats_label.text = "encoded/s: %d | decoded/s: %d | capture_q: %d | playback_q: %d" % [
			_encoded_packets,
			_decoded_packets,
			_capture_buffer.size(),
			_decoded_buffer.size(),
		]
		_encoded_packets = 0
		_decoded_packets = 0


func _setup_capture_bus() -> void:
	var bus_idx := AudioServer.get_bus_index(CAPTURE_BUS_NAME)
	if bus_idx == -1:
		bus_idx = AudioServer.bus_count
		AudioServer.add_bus(bus_idx)
		AudioServer.set_bus_name(bus_idx, CAPTURE_BUS_NAME)

	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		var fx := AudioServer.get_bus_effect(bus_idx, i)
		if fx is AudioEffectCapture:
			_capture = fx as AudioEffectCapture
			break

	if _capture == null:
		_capture = AudioEffectCapture.new()
		AudioServer.add_bus_effect(bus_idx, _capture)

	var silence := AudioEffectAmplify.new()
	silence.volume_db = -80.0
	AudioServer.add_bus_effect(bus_idx, silence)


func _setup_players() -> void:
	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "LoopbackMicrophone"
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = CAPTURE_BUS_NAME
	add_child(_mic_player)
	_mic_player.play()

	var out_stream := AudioStreamGenerator.new()
	out_stream.mix_rate = _sample_rate
	out_stream.buffer_length = 0.5

	_out_player = AudioStreamPlayer.new()
	_out_player.name = "LoopbackOutput"
	_out_player.stream = out_stream
	_out_player.bus = "Master"
	add_child(_out_player)
	_out_player.play()

	_out_playback = _out_player.get_stream_playback()


func _capture_and_encode_decode() -> void:
	if _capture == null:
		return

	var available := _capture.get_frames_available()
	if available > 0:
		_capture_buffer.append_array(_capture.get_buffer(available))

	while _capture_buffer.size() >= _frame_size:
		var frame := _capture_buffer.slice(0, _frame_size)
		_capture_buffer = _capture_buffer.slice(_frame_size)

		var encoded := _opus.encode(frame)
		if encoded.is_empty():
			continue
		_encoded_packets += 1

		var decoded := _opus.decode(encoded)
		if decoded.is_empty():
			continue
		_decoded_packets += 1
		_decoded_buffer.append_array(decoded)


func _flush_decoded_to_playback() -> void:
	if _out_playback == null or _decoded_buffer.is_empty():
		return

	var to_push := mini(_out_playback.get_frames_available(), _decoded_buffer.size())
	if to_push <= 0:
		return

	for i in range(to_push):
		_out_playback.push_frame(_decoded_buffer[i])

	if to_push == _decoded_buffer.size():
		_decoded_buffer.clear()
	else:
		_decoded_buffer = _decoded_buffer.slice(to_push)


func _on_toggle_pressed() -> void:
	_running = not _running
	_toggle_button.text = "Stop loopback" if _running else "Start loopback"

	if not _running:
		_capture_buffer.clear()
		_decoded_buffer.clear()
