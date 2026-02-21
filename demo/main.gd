extends Control


const PORT := 25562

@onready var _ip_edit: LineEdit = %IpEdit
@onready var _join_button: Button = %JoinButton
@onready var _host_button: Button = %HostButton
@onready var _disconnect_button: Button = %DisconnectButton
@onready var _opus_toggle: CheckBox = %OpusToggle
@onready var _high_pass_enabled: CheckBox = %HighPassEnabled
@onready var _high_pass_cutoff: HSlider = %HighPassCutoff
@onready var _high_pass_value: Label = %HighPassValue
@onready var _low_pass_enabled: CheckBox = %LowPassEnabled
@onready var _low_pass_cutoff: HSlider = %LowPassCutoff
@onready var _low_pass_value: Label = %LowPassValue
@onready var _rnnoise_enabled: CheckBox = %RNNoiseEnabled
@onready var _compressor_enabled: CheckBox = %CompressorEnabled
@onready var _compressor_threshold: HSlider = %CompressorThreshold
@onready var _compressor_value: Label = %CompressorValue
@onready var _amplify_enabled: CheckBox = %AmplifyEnabled
@onready var _amplify_db: HSlider = %AmplifyDb
@onready var _amplify_value: Label = %AmplifyValue
@onready var _limiter_enabled: CheckBox = %LimiterEnabled
@onready var _status_label: Label = %StatusLabel
@onready var _peers_label: Label = %PeersLabel
@onready var _log_label: RichTextLabel = %LogLabel

var _voip_players: Dictionary = {}
var _mic_player: AudioStreamPlayer = null
var _updating_effect_controls := false


func _ready() -> void:
	_wire_ui()
	_wire_multiplayer_signals()
	_setup_opus_toggle()
	_setup_effect_controls()
	_log_audio_rate_info()
	_setup_voip_stats_logging()
	_warn_if_low_processor_mode()
	_apply_cli_mute_if_requested()
	_setup_microphone_capture()
	_set_status("Idle")
	_update_peer_count()
	_log("Demo ready. Host or join to start VOIP.")


func _log_audio_rate_info() -> void:
	var runtime_mix := int(AudioServer.get_mix_rate())
	var project_mix := int(ProjectSettings.get_setting("audio/driver/mix_rate", runtime_mix))
	if has_node("/root/VOIP"):
		var opus_rate := VOIP.get_opus_sample_rate()
		var opus_frame := VOIP.get_opus_frame_size()
		var packet_ms := (float(opus_frame) / float(opus_rate)) * 1000.0
		_log("Audio rates -> AudioServer: %d Hz, ProjectSetting: %d Hz, Opus: %d Hz, frame: %d (%.2f ms)" % [runtime_mix, project_mix, opus_rate, opus_frame, packet_ms])
	else:
		_log("Audio rates -> AudioServer: %d Hz, ProjectSetting: %d Hz" % [runtime_mix, project_mix])


func _warn_if_low_processor_mode() -> void:
	if not ProjectSettings.has_setting("application/run/low_processor_mode"):
		return

	var enabled = bool(ProjectSettings.get_setting("application/run/low_processor_mode", false))
	if enabled:
		_log_error("Project setting application/run/low_processor_mode is ON. Background instance may starve VOIP and cause pops.")


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


func _wire_ui() -> void:
	_join_button.pressed.connect(_on_join_pressed)
	_host_button.pressed.connect(_on_host_pressed)
	_disconnect_button.pressed.connect(_on_disconnect_pressed)
	_opus_toggle.toggled.connect(_on_opus_toggled)


func _setup_opus_toggle() -> void:
	if not has_node("/root/VOIP"):
		_opus_toggle.disabled = true
		return

	var opus_enabled := VOIP.opus_compression_enabled
	_opus_toggle.button_pressed = opus_enabled
	_log("Opus compression: %s" % (_mode_text(opus_enabled)))


func _setup_effect_controls() -> void:
	if not has_node("/root/VOIP"):
		_set_effect_controls_enabled(false)
		return

	_apply_effect_config_to_controls(_read_effect_runtime_config_from_bus())

	_high_pass_enabled.toggled.connect(_on_effect_control_changed)
	_low_pass_enabled.toggled.connect(_on_effect_control_changed)
	_rnnoise_enabled.toggled.connect(_on_effect_control_changed)
	_compressor_enabled.toggled.connect(_on_effect_control_changed)
	_amplify_enabled.toggled.connect(_on_effect_control_changed)
	_limiter_enabled.toggled.connect(_on_effect_control_changed)

	_high_pass_cutoff.value_changed.connect(_on_high_pass_changed)
	_low_pass_cutoff.value_changed.connect(_on_low_pass_changed)
	_compressor_threshold.value_changed.connect(_on_compressor_threshold_changed)
	_amplify_db.value_changed.connect(_on_amplify_changed)

	_refresh_effect_value_labels()
	_update_effect_controls_for_role()


func _set_effect_controls_enabled(enabled: bool) -> void:
	_high_pass_enabled.disabled = not enabled
	_high_pass_cutoff.editable = enabled
	_low_pass_enabled.disabled = not enabled
	_low_pass_cutoff.editable = enabled
	_rnnoise_enabled.disabled = not enabled
	_compressor_enabled.disabled = not enabled
	_compressor_threshold.editable = enabled
	_amplify_enabled.disabled = not enabled
	_amplify_db.editable = enabled
	_limiter_enabled.disabled = not enabled


func _on_effect_control_changed(_enabled: bool) -> void:
	_push_effect_runtime_config()


func _on_high_pass_changed(_value: float) -> void:
	_refresh_effect_value_labels()
	_push_effect_runtime_config()


func _on_low_pass_changed(_value: float) -> void:
	_refresh_effect_value_labels()
	_push_effect_runtime_config()


func _on_compressor_threshold_changed(_value: float) -> void:
	_refresh_effect_value_labels()
	_push_effect_runtime_config()


func _on_amplify_changed(_value: float) -> void:
	_refresh_effect_value_labels()
	_push_effect_runtime_config()


func _refresh_effect_value_labels() -> void:
	_high_pass_value.text = "%d Hz" % int(round(_high_pass_cutoff.value))
	_low_pass_value.text = "%d Hz" % int(round(_low_pass_cutoff.value))
	_compressor_value.text = "%.1f dB" % _compressor_threshold.value
	_amplify_value.text = "%.1f dB" % _amplify_db.value


func _push_effect_runtime_config() -> void:
	if not has_node("/root/VOIP"):
		return
	if _updating_effect_controls:
		return
	if not _can_edit_effect_controls():
		return

	var config := _collect_effect_runtime_config_from_controls()
	_apply_effect_runtime_config_to_bus(config)

	if multiplayer.multiplayer_peer != null and multiplayer.is_server():
		_rpc_apply_effect_runtime_config.rpc(config)


func _collect_effect_runtime_config_from_controls() -> Dictionary:
	return {
		"high_pass_enabled": _high_pass_enabled.button_pressed,
		"high_pass_cutoff_hz": _high_pass_cutoff.value,
		"low_pass_enabled": _low_pass_enabled.button_pressed,
		"low_pass_cutoff_hz": _low_pass_cutoff.value,
		"rnnoise_enabled": _rnnoise_enabled.button_pressed,
		"compressor_enabled": _compressor_enabled.button_pressed,
		"compressor_threshold_db": _compressor_threshold.value,
		"amplify_enabled": _amplify_enabled.button_pressed,
		"amplify_db": _amplify_db.value,
		"limiter_enabled": _limiter_enabled.button_pressed,
	}


func _apply_effect_config_to_controls(config: Dictionary) -> void:
	_updating_effect_controls = true
	_high_pass_enabled.button_pressed = bool(config.get("high_pass_enabled", true))
	_high_pass_cutoff.value = float(config.get("high_pass_cutoff_hz", 100.0))
	_low_pass_enabled.button_pressed = bool(config.get("low_pass_enabled", true))
	_low_pass_cutoff.value = float(config.get("low_pass_cutoff_hz", 16000.0))
	_rnnoise_enabled.button_pressed = bool(config.get("rnnoise_enabled", true))
	_compressor_enabled.button_pressed = bool(config.get("compressor_enabled", true))
	_compressor_threshold.value = float(config.get("compressor_threshold_db", -7.0))
	_amplify_enabled.button_pressed = bool(config.get("amplify_enabled", true))
	_amplify_db.value = float(config.get("amplify_db", 7.0))
	_limiter_enabled.button_pressed = bool(config.get("limiter_enabled", true))
	_updating_effect_controls = false
	_refresh_effect_value_labels()


func _read_effect_runtime_config_from_bus() -> Dictionary:
	var bus_idx := AudioServer.get_bus_index("VOIP")
	if bus_idx == -1:
		return _collect_effect_runtime_config_from_controls()

	var high_pass: AudioEffectHighPassFilter = null
	var low_pass: AudioEffectLowPassFilter = null
	var rnnoise: AudioEffectRNNoise = null
	var compressor: AudioEffectCompressor = null
	var amplify: AudioEffectAmplify = null
	var limiter: AudioEffectHardLimiter = null

	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		var effect := AudioServer.get_bus_effect(bus_idx, i)
		if effect is AudioEffectHighPassFilter and high_pass == null:
			high_pass = effect as AudioEffectHighPassFilter
		elif effect is AudioEffectLowPassFilter and low_pass == null:
			low_pass = effect as AudioEffectLowPassFilter
		elif effect is AudioEffectRNNoise and rnnoise == null:
			rnnoise = effect as AudioEffectRNNoise
		elif effect is AudioEffectCompressor and compressor == null:
			compressor = effect as AudioEffectCompressor
		elif effect is AudioEffectAmplify:
			var amp := effect as AudioEffectAmplify
			if amplify == null or amp.volume_db > amplify.volume_db:
				amplify = amp
		elif effect is AudioEffectHardLimiter and limiter == null:
			limiter = effect as AudioEffectHardLimiter

	return {
		"high_pass_enabled": _is_bus_effect_enabled(bus_idx, high_pass, true),
		"high_pass_cutoff_hz": high_pass.cutoff_hz if high_pass != null else 100.0,
		"low_pass_enabled": _is_bus_effect_enabled(bus_idx, low_pass, true),
		"low_pass_cutoff_hz": low_pass.cutoff_hz if low_pass != null else 16000.0,
		"rnnoise_enabled": _is_bus_effect_enabled(bus_idx, rnnoise, true),
		"compressor_enabled": _is_bus_effect_enabled(bus_idx, compressor, true),
		"compressor_threshold_db": compressor.threshold if compressor != null else -7.0,
		"amplify_enabled": _is_bus_effect_enabled(bus_idx, amplify, true),
		"amplify_db": amplify.volume_db if amplify != null else 7.0,
		"limiter_enabled": _is_bus_effect_enabled(bus_idx, limiter, true),
	}


func _apply_effect_runtime_config_to_bus(config: Dictionary) -> void:
	var bus_idx := AudioServer.get_bus_index("VOIP")
	if bus_idx == -1:
		return

	var high_pass: AudioEffectHighPassFilter = null
	var low_pass: AudioEffectLowPassFilter = null
	var rnnoise: AudioEffectRNNoise = null
	var compressor: AudioEffectCompressor = null
	var amplify: AudioEffectAmplify = null
	var limiter: AudioEffectHardLimiter = null

	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		var effect := AudioServer.get_bus_effect(bus_idx, i)
		if effect is AudioEffectHighPassFilter and high_pass == null:
			high_pass = effect as AudioEffectHighPassFilter
		elif effect is AudioEffectLowPassFilter and low_pass == null:
			low_pass = effect as AudioEffectLowPassFilter
		elif effect is AudioEffectRNNoise and rnnoise == null:
			rnnoise = effect as AudioEffectRNNoise
		elif effect is AudioEffectCompressor and compressor == null:
			compressor = effect as AudioEffectCompressor
		elif effect is AudioEffectAmplify:
			var amp := effect as AudioEffectAmplify
			if amplify == null or amp.volume_db > amplify.volume_db:
				amplify = amp
		elif effect is AudioEffectHardLimiter and limiter == null:
			limiter = effect as AudioEffectHardLimiter

	if high_pass != null:
		high_pass.cutoff_hz = clampf(float(config.get("high_pass_cutoff_hz", high_pass.cutoff_hz)), 20.0, 2000.0)
		_set_bus_effect_enabled(bus_idx, high_pass, bool(config.get("high_pass_enabled", true)))
	if low_pass != null:
		low_pass.cutoff_hz = clampf(float(config.get("low_pass_cutoff_hz", low_pass.cutoff_hz)), 1000.0, 22000.0)
		_set_bus_effect_enabled(bus_idx, low_pass, bool(config.get("low_pass_enabled", true)))
	if rnnoise != null:
		_set_bus_effect_enabled(bus_idx, rnnoise, bool(config.get("rnnoise_enabled", true)))
	if compressor != null:
		compressor.threshold = clampf(float(config.get("compressor_threshold_db", compressor.threshold)), -60.0, 0.0)
		_set_bus_effect_enabled(bus_idx, compressor, bool(config.get("compressor_enabled", true)))
	if amplify != null:
		amplify.volume_db = clampf(float(config.get("amplify_db", amplify.volume_db)), -24.0, 24.0)
		_set_bus_effect_enabled(bus_idx, amplify, bool(config.get("amplify_enabled", true)))
	if limiter != null:
		_set_bus_effect_enabled(bus_idx, limiter, bool(config.get("limiter_enabled", true)))


func _is_bus_effect_enabled(bus_idx: int, effect: AudioEffect, default_value: bool) -> bool:
	if effect == null:
		return default_value
	var effect_idx := _find_effect_index(bus_idx, effect)
	if effect_idx == -1:
		return default_value
	return AudioServer.is_bus_effect_enabled(bus_idx, effect_idx)


func _set_bus_effect_enabled(bus_idx: int, effect: AudioEffect, enabled: bool) -> void:
	if effect == null:
		return
	var effect_idx := _find_effect_index(bus_idx, effect)
	if effect_idx == -1:
		return
	AudioServer.set_bus_effect_enabled(bus_idx, effect_idx, enabled)


func _find_effect_index(bus_idx: int, effect: AudioEffect) -> int:
	if effect == null:
		return -1
	for i in range(AudioServer.get_bus_effect_count(bus_idx)):
		if AudioServer.get_bus_effect(bus_idx, i) == effect:
			return i
	return -1


func _can_edit_effect_controls() -> bool:
	if multiplayer.multiplayer_peer == null:
		return true
	return multiplayer.is_server()


func _update_effect_controls_for_role() -> void:
	_set_effect_controls_enabled(_can_edit_effect_controls())


@rpc("any_peer", "reliable", "call_remote")
func _rpc_request_effect_runtime_config() -> void:
	if not multiplayer.is_server():
		return
	if not has_node("/root/VOIP"):
		return
	var requester_id := multiplayer.get_remote_sender_id()
	if requester_id == 0:
		return
	_rpc_apply_effect_runtime_config.rpc_id(requester_id, _read_effect_runtime_config_from_bus())


@rpc("authority", "reliable", "call_remote")
func _rpc_apply_effect_runtime_config(config: Dictionary) -> void:
	if not has_node("/root/VOIP"):
		return
	_apply_effect_runtime_config_to_bus(config)
	_apply_effect_config_to_controls(config)


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


func _wire_multiplayer_signals() -> void:
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _setup_microphone_capture() -> void:
	if not has_node("/root/VOIP"):
		_log_error("VOIP singleton not found. Enable the plugin first.")
		return

	_mic_player = AudioStreamPlayer.new()
	_mic_player.name = "LocalMicrophone"
	_mic_player.stream = AudioStreamMicrophone.new()
	_mic_player.bus = "VOIP"
	add_child(_mic_player)
	_mic_player.play()
	_log("Local microphone routed to VOIP bus.")


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

	_clear_voip_players()
	_set_status("Disconnected")
	_update_peer_count()
	_update_connection_ui()
	if has_node("/root/VOIP"):
		_apply_effect_config_to_controls(_read_effect_runtime_config_from_bus())

	if log_reason:
		_log("Disconnected.")


func _on_connected_to_server() -> void:
	_set_status("Connected (peer id: %d)" % multiplayer.get_unique_id())
	_log("Connected to server.")
	_update_connection_ui()
	_rpc_request_effect_runtime_config.rpc_id(1)


func _on_connection_failed() -> void:
	_set_status("Connection failed")
	_log_error("Connection failed.")
	disconnect_current_peer(false)


func _on_server_disconnected() -> void:
	_set_status("Server disconnected")
	_log_error("Lost connection to server.")
	disconnect_current_peer(false)


func _on_peer_connected(peer_id: int) -> void:
	_create_voip_player_for_peer(peer_id)
	_update_peer_count()
	_log("Peer connected: %d" % peer_id)
	if multiplayer.is_server() and has_node("/root/VOIP"):
		_rpc_apply_effect_runtime_config.rpc_id(peer_id, _read_effect_runtime_config_from_bus())


func _on_peer_disconnected(peer_id: int) -> void:
	_remove_voip_player_for_peer(peer_id)
	_update_peer_count()
	_log("Peer disconnected: %d" % peer_id)


func _create_voip_player_for_peer(peer_id: int) -> void:
	if _voip_players.has(peer_id):
		return

	var player := AudioStreamPlayer.new()
	player.name = "VOIPPeer_%d" % peer_id

	var voip_stream := AudioStreamVOIP.new()
	if has_node("/root/VOIP"):
		voip_stream.configure_stream(VOIP.get_opus_sample_rate(), VOIP.get_opus_frame_size())
	voip_stream.peer_id = peer_id
	player.stream = voip_stream

	add_child(player)
	player.play()
	_voip_players[peer_id] = player


func _remove_voip_player_for_peer(peer_id: int) -> void:
	if not _voip_players.has(peer_id):
		return

	var player: AudioStreamPlayer = _voip_players[peer_id]
	_voip_players.erase(peer_id)
	if is_instance_valid(player):
		player.queue_free()


func _clear_voip_players() -> void:
	for peer_id in _voip_players.keys():
		_remove_voip_player_for_peer(peer_id)


func _update_peer_count() -> void:
	_peers_label.text = "Connected peers: %d" % multiplayer.get_peers().size()


func _set_status(message: String) -> void:
	_status_label.text = "Status: %s" % message


func _update_connection_ui() -> void:
	var connected := multiplayer.multiplayer_peer != null
	_join_button.disabled = connected
	_host_button.disabled = connected
	_disconnect_button.disabled = not connected
	_update_effect_controls_for_role()


func _log(message: String) -> void:
	_log_label.append_text("[color=#BFE8FF]%s[/color]\n" % message)
	_log_label.scroll_to_line(_log_label.get_line_count())


func _log_error(message: String) -> void:
	_log_label.append_text("[color=#FF8A8A]%s[/color]\n" % message)
	_log_label.scroll_to_line(_log_label.get_line_count())
