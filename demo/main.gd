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

var _voip_players: Dictionary = {}
var _mic_player: AudioStreamPlayer = null


func _ready() -> void:
	_wire_ui()
	_wire_multiplayer_signals()
	_setup_opus_toggle()
	_log_audio_rate_info()
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

	_opus_toggle.button_pressed = VOIP.use_opus_compression
	_log("Opus compression: %s" % (_mode_text(VOIP.use_opus_compression)))


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

	VOIP.use_opus_compression = enabled
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
	_create_voip_player_for_peer(peer_id)
	_update_peer_count()
	_log("Peer connected: %d" % peer_id)


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


func _log(message: String) -> void:
	_log_label.append_text("[color=#BFE8FF]%s[/color]\n" % message)
	_log_label.scroll_to_line(_log_label.get_line_count())


func _log_error(message: String) -> void:
	_log_label.append_text("[color=#FF8A8A]%s[/color]\n" % message)
	_log_label.scroll_to_line(_log_label.get_line_count())
