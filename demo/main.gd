extends Control


const player_voip = preload("res://addons/godot_simple_voip/audio_stream_player_voip.gd")


func _ready() -> void:
	%JoinButton.pressed.connect(
		func():
			var peer := ENetMultiplayerPeer.new()
			peer.create_client(%IpEdit.text, 25562)
			multiplayer.multiplayer_peer = peer
	)
	%HostButton.pressed.connect(
		func():
			var peer := ENetMultiplayerPeer.new()
			peer.create_server(25562)
			multiplayer.multiplayer_peer = peer
	)
	
	multiplayer.peer_connected.connect(
		func(peer_id):
			create_voip_player_for_peer(peer_id)
			push_warning("Peer connected: %s" % peer_id)
	)


func create_voip_player_for_peer(peer_id: int) -> void:
	var voip := player_voip.new()
	voip.peer_id = peer_id
	voip.play()
	add_child(voip)
