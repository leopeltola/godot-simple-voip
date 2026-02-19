extends AudioStreamGenerator
class_name AudioStreamVOIP

## Which Peer's voice should be player
@export var peer_id: int = 0

var playback: AudioStreamGeneratorPlayback:
	set(val):
		playback = val
		push_warning("playback set: %s" % playback)
var _packet_queue: Array[Vector2] = []

func _init() -> void:
	#var player := VOIP.get_player_for_stream(self)
	#if player:
		#if not player.playing:
			#player.play()
		#playback = player.get_stream_playback()
	#else:
		#push_error("Could not find AudioStreamPlayer for AudioStreamVOIP.")
	print("Instantiated AudioStreamVOIP")
	VOIP.peer_voice_data_received.connect(
		func(speaker_peer_id: int, pcm_data: PackedVector2Array):
			if speaker_peer_id != peer_id:
				return
			if not playback:
				push_error("Received peer %s voice data but playback not set" % speaker_peer_id)
				return
			#print(pcm_data)
			for frame in pcm_data:
				if playback.can_push_buffer(1):
					#push_warning("Pushed frame to buffer for p %s" % speaker_peer_id)
					playback.push_frame(frame)
				else:
					#push_warning("Could not push frame to buffer")
					break
	)
