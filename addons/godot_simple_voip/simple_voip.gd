@tool
extends EditorPlugin

const AUTOLOAD_NAME = "VOIP"


func _enter_tree() -> void:
	pass


func _exit_tree() -> void:
	pass


func _enable_plugin():
	# The autoload can be a scene or script file.
	add_autoload_singleton(AUTOLOAD_NAME, "multiplayer_voip.gd")
	


func _disable_plugin():
	remove_autoload_singleton(AUTOLOAD_NAME)
