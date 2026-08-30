# ============================================================================
# Sketch Tool - main loader (UP-style)
#
# DD's ModManager loads EVERY .gd of the pack recursively as a ModScript
# and calls start()/update() on files that define them: this loader is
# therefore the ONLY file allowed to define those two functions. The
# implementation (library/sketch_impl.gd, boot/tick entry points) is
# re-read from disk at every start() - and since DD calls start() on
# every map load while its own GDScripts cache never refreshes,
# RELOADING A MAP RELOADS THE IMPLEMENTATION as long as this loader
# itself is unchanged. Same workflow as the Unofficial Patch.
#
# The implementation is compiled exactly like DD compiles ModScripts:
# same "var Global = {} / var Script=null" header prepended (Global is
# NOT an autoload, DD injects it as a per-instance dictionary), so the
# file stays valid both ways; the loader then hands its own injected
# Global over. Registration happens once per DD session: Editor.Tools
# persists across maps and a duplicate CreateModTool throws an UNCAUGHT
# C# exception that aborts ModManager.Start and kills every mod loaded
# after this one.
# ============================================================================

const IMPL_PATH = "library/sketch_impl.gd"
const META_IMPL = "SketchTool_active_impl"
const META_PANEL = "SketchTool_panel"
const TOOL_CATEGORY = "Design"
const TOOL_ID = "sketch_tool"
const TOOL_NAME = "Sketch Tool"


func start() -> void:
	print("[SketchTool] loader v3 start")
	# Tear the previous implementation down (map reload): drawings are
	# flushed to map data first, owned nodes freed, panel content cleared.
	if Engine.has_meta(META_IMPL):
		var old = Engine.get_meta(META_IMPL)
		if old != null and is_instance_valid(old) and old.has_method("teardown"):
			old.teardown()
		Engine.remove_meta(META_IMPL)

	# Register exactly once per DD session (Editor.Tools persists across
	# maps; GetToolPanel is useless here, mod tools never enter the
	# ToolPanels dictionary).
	var panel = null
	if Engine.has_meta(META_PANEL):
		var pm = Engine.get_meta(META_PANEL)
		if pm != null and is_instance_valid(pm):
			panel = pm
	if panel == null:
		panel = Global.Editor.Toolset.CreateModTool(self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME,
			Global.Root + "icons/sketch_tool.png")
		if panel == null:
			push_error("[SketchTool] CreateModTool failed")
			return
		Engine.set_meta(META_PANEL, panel)

	var script = _read_impl()
	if script == null:
		return
	var impl = script.new()
	impl.Global = Global
	impl.ext_panel = panel
	Engine.set_meta(META_IMPL, impl)
	impl.boot()
	print("[SketchTool] impl booted (map load = impl reload)")


# Reads and compiles the implementation exactly like DD's own
# LoadScriptSource does, bypassing both DD's GDScripts cache and the
# resource cache.
func _read_impl():
	var f = File.new()
	if f.open(Global.Root + IMPL_PATH, File.READ) != OK:
		push_error("[SketchTool] cannot read " + IMPL_PATH)
		return null
	var src = f.get_as_text()
	f.close()
	var sc = GDScript.new()
	sc.source_code = "var Global = {}\nvar Script=null\n\n" + src
	if sc.reload() != OK:
		push_error("[SketchTool] impl parse error, keeping the previous instance")
		return null
	return sc


func _impl():
	if Engine.has_meta(META_IMPL):
		var i = Engine.get_meta(META_IMPL)
		if i != null and is_instance_valid(i):
			return i
	return null


func update(delta: float) -> void:
	var i = _impl()
	if i != null:
		i.tick(delta)


func on_tool_enable(tool_id) -> void:
	var i = _impl()
	if i != null:
		i.on_tool_enable(tool_id)


func on_tool_disable(tool_id) -> void:
	var i = _impl()
	if i != null:
		i.on_tool_disable(tool_id)


func on_content_input(event) -> void:
	var i = _impl()
	if i != null:
		i.on_content_input(event)
