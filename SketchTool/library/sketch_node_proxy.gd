extends Node2D

# Sketch Layer - Node proxy.
#
# The main tool script is a Reference and cannot live in the scene tree, so
# every node that needs _draw() or _process() delegates to a method on the
# handler. Assign handler / draw_method / process_method BEFORE add_child().

var handler = null
var draw_method: String = ""
var process_method: String = ""
var input_method: String = ""


func _ready() -> void:
	set_process(process_method != "")
	set_process_input(input_method != "")


func _draw() -> void:
	if handler != null and draw_method != "" and handler.has_method(draw_method):
		handler.call(draw_method, self)


func _process(delta: float) -> void:
	if handler != null and process_method != "" and handler.has_method(process_method):
		handler.call(process_method, delta)


func _input(event: InputEvent) -> void:
	if handler != null and input_method != "" and handler.has_method(input_method):
		handler.call(input_method, self, event)
