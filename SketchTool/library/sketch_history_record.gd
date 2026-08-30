extends Reference

# Sketch Tool - History record.
#
# One record per committed stroke. Stores the pre- and post-images of the
# stroke's bounding rectangle (in sketch texture pixels) plus the uid of the
# sketch it belongs to. Undo/redo simply stamps the saved rectangle back into
# the sketch texture (replace blend), delegated to the main tool script.
#
# The handler is the sketch_tool.gd script instance. It may belong to a
# previous mod load (map reload keeps DD's history alive); the handler guards
# against its own freed nodes, we only guard against a null handler here.

var handler = null
var sketch_uid: int = -1
var rect: Rect2 = Rect2()
var pre_image = null   # Image
var post_image = null  # Image
# Optional: data to re-create the floating selection when undoing a
# selection commit/delete (rect_tex, img, restore_img, erase_img, center,
# size, rot, copy).
var sel_data = null
# Optional: room-label lists to restore on undo/redo (plan generations and
# canvas clears carry them).
var labels_before = null
var labels_after = null
# Optional: merged-shape store snapshots (shape commits carry them so an
# undone shape does not survive as an invisible merge candidate).
var shapes_before = null
var shapes_after = null


func undo() -> void:
	if handler == null:
		return
	handler.history_apply(sketch_uid, rect, pre_image, sel_data, labels_before,
		shapes_before)


func redo() -> void:
	if handler == null:
		return
	handler.history_apply(sketch_uid, rect, post_image, null, labels_after,
		shapes_after)
