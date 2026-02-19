extends AudioStreamGenerator
class_name AudioStreamVOIP

## Which peer's voice should be played through this stream.
@export var peer_id: int = 0:
	set(value):
		if peer_id == value:
			return
		_set_voice_signal_enabled(false)
		peer_id = value
		_set_voice_signal_enabled(true)

var _playback: AudioStreamGeneratorPlayback = null
var _pending_frames: PackedVector2Array = PackedVector2Array()
var _pending_read_pos := 0
var _started := false
var _sample_rate := 48_000
var _frame_size := 960
var _start_buffer_frames := 2_880
var _max_pending_frames := 48_000


func _init() -> void:
	mix_rate = _sample_rate
	_set_voice_signal_enabled(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_set_voice_signal_enabled(false)


func bind_playback(playback: AudioStreamGeneratorPlayback) -> void:
	_playback = playback
	_flush_pending_to_playback()


func configure_stream(sample_rate: int, frame_size: int) -> void:
	if sample_rate <= 0 or frame_size <= 0:
		return

	# mix_rate should be set before play() creates playback.
	if _playback == null:
		mix_rate = sample_rate
	_sample_rate = sample_rate
	_frame_size = frame_size
	_start_buffer_frames = _frame_size * 3
	_max_pending_frames = _sample_rate


func pump_playback() -> void:
	_flush_pending_to_playback()


func _on_voice_data(speaker_peer_id: int, pcm_data: PackedVector2Array) -> void:
	if speaker_peer_id != peer_id or not pcm_data:
		return

	_pending_frames.append_array(pcm_data)
	if _pending_available() > _max_pending_frames:
		# Keep latency bounded if we ever fall behind.
		_pending_read_pos = _pending_frames.size() - _max_pending_frames
		_compact_pending_if_needed()

	_flush_pending_to_playback()


func _flush_pending_to_playback() -> void:
	if _playback == null or _pending_available() <= 0:
		return

	if not _started:
		if _pending_available() < _start_buffer_frames:
			return
		_started = true

	var frames_available := _playback.get_frames_available()
	if frames_available <= 0:
		return

	var available_pending := _pending_available()
	var to_push := mini(frames_available, available_pending)
	if to_push <= 0:
		return

	for i in range(to_push):
		_playback.push_frame(_pending_frames[_pending_read_pos + i])

	_pending_read_pos += to_push
	_compact_pending_if_needed()


func _set_voice_signal_enabled(enabled: bool) -> void:
	if peer_id == 0:
		return

	var voip := _get_voip_singleton()
	if voip == null:
		return

	if enabled:
		if not voip.peer_voice_data_received.is_connected(_on_voice_data):
			voip.peer_voice_data_received.connect(_on_voice_data)
	else:
		if voip.peer_voice_data_received.is_connected(_on_voice_data):
			voip.peer_voice_data_received.disconnect(_on_voice_data)


func _get_voip_singleton() -> Node:
	var main_loop := Engine.get_main_loop()
	if not (main_loop is SceneTree):
		return null

	var tree := main_loop as SceneTree
	if tree.root == null:
		return null
	if not tree.root.has_node("VOIP"):
		return null

	return tree.root.get_node("VOIP")


func _pending_available() -> int:
	return _pending_frames.size() - _pending_read_pos


func _compact_pending_if_needed() -> void:
	if _pending_read_pos <= 0:
		return

	if _pending_read_pos >= 4096 or _pending_read_pos * 2 >= _pending_frames.size():
		_pending_frames = _pending_frames.slice(_pending_read_pos)
		_pending_read_pos = 0
