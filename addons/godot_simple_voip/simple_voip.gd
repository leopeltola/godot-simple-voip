@tool
extends EditorPlugin

const AUTOLOAD_NAME = "VOIP"
const SINGLETON_SCRIPT = "voip_singleton.gd"


func _enable_plugin():
	# Register the VOIP singleton
	add_autoload_singleton(AUTOLOAD_NAME, "res://addons/godot_simple_voip/voip_singleton.gd")


func _disable_plugin():
	remove_autoload_singleton(AUTOLOAD_NAME)
