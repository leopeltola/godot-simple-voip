@tool
extends AudioStreamPlayer
class_name AudioStreamPlayerVOIP

## Which peer's voice should be played from this player. 
@export var peer_id: int = 0:
	set(val):
		peer_id = val
		if stream is AudioStreamVOIP:
			(stream as AudioStreamVOIP).peer_id = peer_id


func _ready() -> void:
	var s := AudioStreamVOIP.new()
	s.peer_id = peer_id
	stream = s
	play()
	stream.playback = get_stream_playback()
	push_warning("Initted VOIPPlayer for %s" % peer_id)


func _process(delta: float) -> void:
	if stream.playback:
		assert(stream.playback == get_stream_playback())
