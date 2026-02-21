extends Control

const PORT := 25562

@onready var _ip_edit: LineEdit = %IpEdit
@onready var _join_button: Button = %JoinButton
@onready var _host_button: Button = %HostButton
@onready var _disconnect_button: Button = %DisconnectButton
@onready var _opus_toggle: CheckBox = %OpusToggle
@onready var _status_label: Label = %StatusLabel
@onready var _peers_label: Label = %PeersLabel
@onready var _log_label: RichTextLabel = %LogLabel

var _mic_player: AudioStreamPlayer = null
var _peer_audio: Dictionary = {}

var _sample_rate := 48_000
var _frame_size := 960
var _start_buffer_frames := 2_880


func _ready() -> void:
	_wire_ui()
	_wire_multiplayer_signals()
	_setup_voip()
	_setup_opus_toggle()
	_setup_voip_stats_logging()
	_warn_if_low_processor_mode()
	_apply_cli_mute_if_requested()
	_setup_microphone_capture()
	_set_status("Idle")
	_update_peer_count()
	_log("Generator demo ready. Host or join to start VOIP.")


func _process(_delta: float) -> void:
	for peer_id in _peer_audio.keys():
		_flush_peer_audio(peer_id)


func _wire_ui() -> void:
	_join_button.pressed.connect(_on_join_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	_opus_toggle.toggled.connect(_on_opus_toggled)


func _wire_multiplayer_signals() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _setup_voip() -> void:
	if not has_node("/root/VOIP"):
		_log_error("VOIP singleton not found. Enable the plugin first.")
		_opus_toggle.disabled = true
		return

	_sample_rate = VOIP.get_opus_sample_rate()
	_frame_size = VOIP.get_opus_frame_size()
	_start_buffer_frames = _frame_size * 3

	if not VOIP.peer_voice_data_received.is_connected(_on_peer_voice_data_received):
		VOIP.peer_voice_data_received.connect(_on_peer_voice_data_received)

	var runtime_mix := int(AudioServer.get_mix_rate())
	var project_mix := int(ProjectSettings.get_setting("audio/driver/mix_rate", runtime_mix))
	var packet_ms := (float(_frame_size) / float(_sample_rate)) * 1000.0
	_log("Audio rates -> AudioServer: %d Hz, ProjectSetting: %d Hz, Opus: %d Hz, frame: %d (%.2f ms)" % [runtime_mix, project_mix, _sample_rate, _frame_size, packet_ms])


func _warn_if_low_processor_mode() -> void:
	if not ProjectSettings.has_setting("application/run/low_processor_mode"):
		return

	var enabled = bool(ProjectSettings.get_setting("application/run/low_processor_mode", false))
	if enabled:
		_log_error("Project setting application/run/low_processor_mode is ON. Background instance may starve VOIP and cause pops.")


func _setup_opus_toggle() -> void:
	if not has_node("/root/VOIP"):
		_opus_toggle.disabled = true
		return

	var opus_enabled := VOIP.opus_compression_enabled
	_opus_toggle.button_pressed = opus_enabled
	_log("Opus compression: %s" % _mode_text(opus_enabled))


func _setup_voip_stats_logging() -> void:
	if not has_node("/root/VOIP"):
		return

	if VOIP.has_signal("debug_stats_updated") and not VOIP.debug_stats_updated.is_connected(_on_voip_stats_updated):
		VOIP.debug_stats_updated.connect(_on_voip_stats_updated)
		_log("VOIP packet telemetry enabled.")


func _on_voip_stats_updated(stats: Dictionary) -> void:
	_log("stats role=%s mode=%s sent=%d recv_cli=%d relay=%d q=%d send_dt=%.1fms recv_dt=%.1fms proc=%.1f/%.1fms gaps=%d" % [
		stats.get("role", "?"),
		stats.get("mode", "?"),
		int(stats.get("sent_packets", 0)),
		int(stats.get("client_received_packets", 0)),
		int(stats.get("server_relay_packets", 0)),
		int(stats.get("capture_queue_frames", 0)),
		float(stats.get("send_dt_avg_ms", 0.0)),
		float(stats.get("recv_dt_avg_ms", 0.0)),
		float(stats.get("process_dt_avg_ms", 0.0)),
		float(stats.get("process_dt_max_ms", 0.0)),
		int(stats.get("process_gap_over_100ms", 0)),
	])


func _setup_microphone_capture() -> void:
	if not has_node("/root/VOIP"):
		return

	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "LocalMicrophone"
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = "VOIP"
	add_child(_mic_player)
	_mic_player.play()
	_log("Local microphone routed to VOIP bus.")


func _apply_cli_mute_if_requested() -> void:
	var args := OS.get_cmdline_args()
	if not args.has("--mute"):
		return

	var master_idx := AudioServer.get_bus_index("Master")
	if master_idx == -1:
		_log_error("--mute requested, but Master bus was not found.")
		return

	AudioServer.set_bus_volume_db(master_idx, -80.0)
	_log("--mute detected: Master bus volume set to -80 dB.")


func _on_opus_toggled(enabled: bool) -> void:
	if not has_node("/root/VOIP"):
		_log_error("Opus toggle failed: VOIP singleton not found.")
		return

	VOIP.opus_compression_enabled = enabled
	_log("Opus compression: %s" % _mode_text(enabled))


func _mode_text(opus_enabled: bool) -> String:
	if opus_enabled:
		return "ON (compressed)"
	return "OFF (raw PCM debug)"


func _on_join_pressed() -> void:
	disconnect_current_peer(false)

	var address := _ip_edit.text.strip_edges()
	if address.is_empty():
		_log_error("Join failed: IP address is empty.")
		return

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(address, PORT)
	if err != OK:
		_log_error("Join failed (%s)." % error_string(err))
		return

	multiplayer.multiplayer_peer = peer
	_set_status("Connecting to %s:%d..." % [address, PORT])
	_log("Attempting to join %s:%d" % [address, PORT])
	_update_connection_ui()


func _on_host_pressed() -> void:
	disconnect_current_peer(false)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(PORT)
	if err != OK:
		_log_error("Host failed (%s)." % error_string(err))
		return

	multiplayer.multiplayer_peer = peer
	_set_status("Hosting on port %d" % PORT)
	_log("Server started on port %d" % PORT)
	_update_connection_ui()


func _on_disconnect_pressed() -> void:
	disconnect_current_peer(true)


func disconnect_current_peer(log_reason: bool = true) -> void:
	if multiplayer.multiplayer_peer:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null

	_clear_peer_audio()
	_set_status("Disconnected")
	_update_peer_count()
	_update_connection_ui()

	if log_reason:
		_log("Disconnected.")


func _on_connected_to_server() -> void:
	_set_status("Connected (peer id: %d)" % multiplayer.get_unique_id())
	_log("Connected to server.")
	_update_connection_ui()


func _on_connection_failed() -> void:
	_set_status("Connection failed")
	_log_error("Connection failed.")
	disconnect_current_peer(false)


func _on_server_disconnected() -> void:
	_set_status("Server disconnected")
	_log_error("Lost connection to server.")
	disconnect_current_peer(false)


func _on_peer_connected(peer_id: int) -> void:
	_ensure_peer_audio(peer_id)
	_update_peer_count()
	_log("Peer connected: %d" % peer_id)


func _on_peer_disconnected(peer_id: int) -> void:
	_remove_peer_audio(peer_id)
	_update_peer_count()
	_log("Peer disconnected: %d" % peer_id)


func _on_peer_voice_data_received(peer_id: int, pcm_data: PackedVector2Array) -> void:
	if pcm_data.is_empty():
		return

	_ensure_peer_audio(peer_id)
	var info: Dictionary = _peer_audio[peer_id]
	var pending: PackedVector2Array = info["pending"]
	pending.append_array(pcm_data)
	if pending.size() > _sample_rate:
		pending = pending.slice(pending.size() - _sample_rate)
	info["pending"] = pending
	_peer_audio[peer_id] = info

	_flush_peer_audio(peer_id)


func _ensure_peer_audio(peer_id: int) -> void:
	if _peer_audio.has(peer_id):
		return

	var stream := AudioStreamGenerator.new()
	stream.mix_rate = _sample_rate
	stream.buffer_length = 0.5

	var player := AudioStreamPlayer.new()
	player.name = "GENPeer_%d" % peer_id
	player.stream = stream
	add_child(player)
	player.play()

	var info := {
		"player": player,
		"playback": player.get_stream_playback(),
		"pending": PackedVector2Array(),
		"started": false,
	}
	_peer_audio[peer_id] = info


func _flush_peer_audio(peer_id: int) -> void:
	if not _peer_audio.has(peer_id):
		return

	var info: Dictionary = _peer_audio[peer_id]
	var player: AudioStreamPlayer = info["player"]
	if not is_instance_valid(player):
		_peer_audio.erase(peer_id)
		return

	var playback: AudioStreamGeneratorPlayback = info["playback"]
	if playback == null:
		playback = player.get_stream_playback()
		if playback == null:
			return
		info["playback"] = playback

	var pending: PackedVector2Array = info["pending"]
	var started: bool = info["started"]

	if pending.is_empty():
		_peer_audio[peer_id] = info
		return

	if not started and pending.size() < _start_buffer_frames:
		_peer_audio[peer_id] = info
		return

	started = true

	var to_push := mini(playback.get_frames_available(), pending.size())
	for i in range(to_push):
		playback.push_frame(pending[i])

	if to_push == pending.size():
		pending.clear()
	else:
		pending = pending.slice(to_push)

	info["pending"] = pending
	info["started"] = started
	_peer_audio[peer_id] = info


func _remove_peer_audio(peer_id: int) -> void:
	if not _peer_audio.has(peer_id):
		return

	var info: Dictionary = _peer_audio[peer_id]
	_peer_audio.erase(peer_id)
	if info.has("player") and is_instance_valid(info["player"]):
		(info["player"] as AudioStreamPlayer).queue_free()


func _clear_peer_audio() -> void:
	for peer_id in _peer_audio.keys():
		_remove_peer_audio(peer_id)


func _update_peer_count() -> void:
	_peers_label.text = "Connected peers: %d" % multiplayer.get_peers().size()


func _set_status(message: String) -> void:
	_status_label.text = "Status: %s" % message


func _update_connection_ui() -> void:
	var connected := multiplayer.multiplayer_peer != null
	_join_button.disabled = connected
	_host_button.disabled = connected
	_disconnect_button.disabled = not connected


func _log(message: String) -> void:
	_log_label.append_text("[color=#BFE8FF]%s[/color]\n" % message)
	_log_label.scroll_to_line(_log_label.get_line_count())


func _log_error(message: String) -> void:
	_log_label.append_text("[color=#FF8A8A]%s[/color]\n" % message)
	_log_label.scroll_to_line(_log_label.get_line_count())


func _exit_tree() -> void:
	if has_node("/root/VOIP") and VOIP.peer_voice_data_received.is_connected(_on_peer_voice_data_received):
		VOIP.peer_voice_data_received.disconnect(_on_peer_voice_data_received)
