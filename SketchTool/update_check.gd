# update_check.gd
# ─────────────────────────────────────────────────────────────────────────────
# Moulk's Mods Update Checker — shared, drop-in version check for all Moulk
# mods hosted on GitHub.
#
# HOW IT WORKS
# - Copy this file into the folder of any mod (next to the .ddmod file).
#   Dungeondraft automatically loads every .gd file inside a mod folder, so
#   no Main.gd integration is needed.
# - Each copy registers its mod (name / local version / URLs) into a shared
#   registry stored in Engine metadata. The copy with the highest
#   CHECKER_VERSION becomes the "owner" and performs a single check for ALL
#   registered mods: one HTTPS request per mod to raw.githubusercontent.com
#   (no API rate limit involved).
# - The remote version is read from the mod's .ddmod file on GitHub and
#   compared to the local .ddmod version. If at least one non-skipped update
#   is found, a single popup lists ALL available updates with clickable
#   download links.
#
# PER-MOD CONFIGURATION (either option works):
#   1) update_check.json next to the .ddmod:
#        {
#            "update_url":   "https://raw.githubusercontent.com/<user>/<repo>/<branch>/<path>/<Mod>.ddmod",
#            "download_url": "https://github.com/<user>/<repo>/releases/latest/download/<Mod>.zip"
#        }
#   2) Or the same two keys ("update_url", "download_url") added directly
#      inside the .ddmod file.
#
# PERSISTENCE: user://MoulkModsUpdateChecker.json
#   { "skipped": { "<unique_id>": "<skipped remote version>" } }
#
# Skip semantics: pressing "Skip" stores the current remote version of every
# listed mod. The popup reappears as soon as ANY registered mod publishes a
# version that was not skipped — and it then lists ALL pending updates again,
# including previously skipped ones.
# ─────────────────────────────────────────────────────────────────────────────

# Bump this when editing this file: among all loaded copies, the highest
# CHECKER_VERSION wins ownership of the check + popup.
const CHECKER_VERSION := 5

const META_REGISTRY := "_moulk_upd_registry"   # Dictionary: unique_id -> entry
const META_OWNER    := "_moulk_upd_owner"      # Dictionary: {ver: int, ref: WeakRef}
const META_DONE     := "_moulk_upd_done"       # bool: check finished this session
const META_HTTP     := "_moulk_upd_http"       # HTTPRequest node (instance guard)

const STATE_FILE := "user://MoulkModsUpdateChecker.json"

const LINK_GITHUB := "https://github.com/Moulkator/Dungeondraft-Mods/tree/main"

const LINK_COLOR       := Color("#54a9eb")
const LINK_COLOR_HOVER := Color("#7cc0f2")

# Delay (seconds of update() time) before the owner starts the check, so that
# every loaded mod has had a chance to register first.
const START_DELAY := 1.5

const ST_IDLE       := 0
const ST_WAIT_TREE  := 1
const ST_REQUESTING := 2
const ST_DONE       := 3

var _entry   := {}          # this mod's registry entry (empty if config missing)
var _state   := ST_IDLE
var _elapsed := 0.0
var _http : HTTPRequest = null
var _queue   := []          # entries left to check (owner only)
var _current := {}          # entry currently being requested
var _updates := []          # [{name, uid, local, remote, download}]
var _dialog : WindowDialog = null
var _margin : MarginContainer = null
var _big_font : DynamicFont = null  # shared by the title and the mod links, resynced each frame


func start() -> void:
	if Engine.has_meta(META_DONE):
		return
	_entry = _read_local_info()
	if _entry.empty():
		return
	# Register this mod into the shared registry.
	var reg := {}
	if Engine.has_meta(META_REGISTRY):
		reg = Engine.get_meta(META_REGISTRY)
	reg[_entry["uid"]] = _entry
	Engine.set_meta(META_REGISTRY, reg)
	# Owner election: take over if there is no valid owner yet, or if our
	# checker version is strictly higher than the current owner's.
	var take := true
	if Engine.has_meta(META_OWNER):
		var owner = Engine.get_meta(META_OWNER)
		if owner is Dictionary and owner.has("ref") and owner["ref"] is WeakRef:
			if owner["ref"].get_ref() != null and int(owner.get("ver", 0)) >= CHECKER_VERSION:
				take = false
	if take:
		Engine.set_meta(META_OWNER, {"ver": CHECKER_VERSION, "ref": weakref(self)})
	print("[MoulkUpdateChecker] Registered %s v%s (checker v%d)" % [_entry["name"], _entry["local"], CHECKER_VERSION])


func update(delta: float) -> void:
	_fit_dialog()
	if _state == ST_DONE or _entry.empty() or Engine.has_meta(META_DONE):
		return
	if not _is_owner():
		return
	_elapsed += delta
	if _state == ST_IDLE:
		if _elapsed < START_DELAY:
			return
		_start_check()
	elif _state == ST_WAIT_TREE:
		if _http != null and is_instance_valid(_http) and _http.is_inside_tree():
			_request_next()


func _is_owner() -> bool:
	if not Engine.has_meta(META_OWNER):
		return false
	var owner = Engine.get_meta(META_OWNER)
	if not (owner is Dictionary) or not (owner.get("ref") is WeakRef):
		return false
	return owner["ref"].get_ref() == self


# ── Check sequence (owner only) ──────────────────────────────────────────────

func _start_check() -> void:
	# Instance guard: free any stale HTTPRequest left over from a previous
	# map-load session that was interrupted mid-check.
	if Engine.has_meta(META_HTTP):
		var old = Engine.get_meta(META_HTTP)
		if old is Node and is_instance_valid(old):
			old.queue_free()
		Engine.remove_meta(META_HTTP)
	var loop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		_state = ST_DONE
		return
	_http = HTTPRequest.new()
	_http.set("timeout", 10)  # property exists in recent Godot 3.x; no-op otherwise
	_http.connect("request_completed", self, "_on_request_completed")
	Engine.set_meta(META_HTTP, _http)
	loop.root.call_deferred("add_child", _http)
	var reg = Engine.get_meta(META_REGISTRY)
	_queue = []
	for uid in reg:
		_queue.append(reg[uid])
	_updates = []
	_state = ST_WAIT_TREE


func _request_next() -> void:
	while not _queue.empty():
		_current = _queue.pop_front()
		var err = _http.request(String(_current["update_url"]))
		if err == OK:
			_state = ST_REQUESTING
			return
		print("[MoulkUpdateChecker] Request error %d for %s" % [err, _current["name"]])
	_finalize()


func _on_request_completed(result: int, response_code: int, _headers, body) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200:
		var parsed = JSON.parse(body.get_string_from_utf8())
		if parsed.error == OK and parsed.result is Dictionary and parsed.result.has("version"):
			var remote := String(parsed.result["version"])
			if _version_gt(remote, String(_current["local"])):
				_updates.append({
					"name": _current["name"],
					"uid": _current["uid"],
					"local": _current["local"],
					"remote": remote,
					"download": _current["download_url"],
				})
		else:
			print("[MoulkUpdateChecker] Bad .ddmod content for %s" % _current["name"])
	else:
		print("[MoulkUpdateChecker] Check failed for %s (result=%d, code=%d)" % [_current["name"], result, response_code])
	_request_next()


func _finalize() -> void:
	_state = ST_DONE
	Engine.set_meta(META_DONE, true)
	if _http != null and is_instance_valid(_http):
		_http.queue_free()
	_http = null
	if Engine.has_meta(META_HTTP):
		Engine.remove_meta(META_HTTP)
	if _updates.empty():
		print("[MoulkUpdateChecker] All mods are up to date.")
		return
	for u in _updates:
		print("[MoulkUpdateChecker] Update available: %s v%s -> v%s" % [u["name"], u["local"], u["remote"]])
	# Show the popup only if at least one update was NOT skipped at this exact
	# remote version. When shown, it lists ALL pending updates.
	var skipped: Dictionary = _load_state().get("skipped", {})
	var show := false
	for u in _updates:
		if String(skipped.get(u["uid"], "")) != String(u["remote"]):
			show = true
			break
	if show:
		call_deferred("_build_popup")


# ── Popup ────────────────────────────────────────────────────────────────────

func _build_popup() -> void:
	var loop = Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return
	_dialog = WindowDialog.new()
	_dialog.window_title = "Moulk's Mods Update Checker"
	_dialog.popup_exclusive = true
	_dialog.connect("popup_hide", self, "_on_popup_hidden")

	var margin := MarginContainer.new()
	margin.set("custom_constants/margin_left", 18)
	margin.set("custom_constants/margin_right", 18)
	margin.set("custom_constants/margin_top", 14)
	margin.set("custom_constants/margin_bottom", 14)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	_dialog.add_child(margin)
	_margin = margin

	var vbox := VBoxContainer.new()
	vbox.set("custom_constants/separation", 12)
	margin.add_child(vbox)

	# Shared big font for the first line and the mod links (RichTextLabel does
	# not support [size] tags in Godot 3). Its size follows the current theme
	# font (+5px) and is resynced every frame in _fit_dialog, so it tracks
	# DD's Enlarge UI live.
	_big_font = DynamicFont.new()
	var base_font = _dialog.get_font("font", "Label")
	if base_font != null and base_font is DynamicFont:
		_big_font.font_data = base_font.font_data
		_big_font.size = base_font.size + 5

	var title := Label.new()
	if _updates.size() == 1:
		title.text = "A new version of the following mod is available!"
	else:
		title.text = "A new version of the following mods is available!"
	title.align = Label.ALIGN_CENTER
	title.autowrap = true
	title.add_font_override("font", _big_font)
	vbox.add_child(title)

	# Mod list: one LinkButton per update, same big font as the title.
	var links := VBoxContainer.new()
	links.set("custom_constants/separation", 4)
	vbox.add_child(links)
	for u in _updates:
		var lb := LinkButton.new()
		lb.text = "\u2022  %s v%s" % [u["name"], u["remote"]]
		lb.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		lb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		lb.add_font_override("font", _big_font)
		lb.add_color_override("font_color", LINK_COLOR)
		lb.add_color_override("font_color_hover", LINK_COLOR_HOVER)
		lb.add_color_override("font_color_pressed", LINK_COLOR_HOVER)
		lb.connect("pressed", self, "_on_mod_link_pressed", [u["download"]])
		links.add_child(lb)

	var text := RichTextLabel.new()
	text.bbcode_enabled = true
	text.scroll_active = true
	text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Let the label report its content height as minimum size, so the dialog
	# can be fitted to its contents (see _fit_dialog).
	text.set("fit_content_height", true)
	text.bbcode_text = _build_bbcode()
	text.connect("meta_clicked", self, "_on_meta_clicked")
	vbox.add_child(text)

	var buttons := HBoxContainer.new()
	buttons.set("custom_constants/separation", 16)
	vbox.add_child(buttons)

	var later := Button.new()
	later.text = "Remind me later"
	later.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	later.connect("pressed", self, "_on_later_pressed")
	_outline_button(later)
	buttons.add_child(later)

	var skip := Button.new()
	skip.text = "Skip this version" if _updates.size() == 1 else "Skip these versions"
	skip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skip.connect("pressed", self, "_on_skip_pressed")
	_outline_button(skip)
	buttons.add_child(skip)

	# Parent inside the Editor subtree (like DD's own dialogs) so the editor
	# theme — including Enlarge UI — applies to the popup. Fallback to the
	# viewport root if the Editor is not available.
	var parent_node: Node = null
	if Global.Editor != null and is_instance_valid(Global.Editor):
		parent_node = Global.Editor.get_node_or_null("Windows")
		if parent_node == null:
			parent_node = Global.Editor
	if parent_node == null:
		parent_node = loop.root
	parent_node.add_child(_dialog)
	# Popup Blur compatibility (Unofficial Patch): register through its
	# Engine-metadata singleton if the submod is loaded and enabled.
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and pb.has_method("register"):
			pb.register(_dialog)
	_dialog.popup_centered(Vector2(560, 200))


# Adds a 1px grey outline to a button by duplicating its themed StyleBoxFlat
# for every visual state. Skips states whose stylebox is not a StyleBoxFlat.
func _outline_button(btn: Button) -> void:
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var sb = btn.get_stylebox(state)
		if sb != null and sb is StyleBoxFlat:
			var dup = sb.duplicate()
			dup.border_width_left = 1
			dup.border_width_right = 1
			dup.border_width_top = 1
			dup.border_width_bottom = 1
			dup.border_color = Color(0.55, 0.55, 0.55, 1.0)
			btn.add_stylebox_override(state, dup)


func _build_bbcode() -> String:
	var bb := "[center]"
	bb += "Click on the mod to download the new version, then replace your old mod "
	bb += "with the new one and restart Dungeondraft to finish the update.\n\n"
	bb += "You can also check my other mods [url=%s]here[/url].\n\n" % LINK_GITHUB
	bb += "Thanks for your support!"
	bb += "[/center]\n"
	bb += "[right]--- Moulk ---[/right]"
	return bb


func _on_meta_clicked(meta) -> void:
	OS.shell_open(String(meta))


func _on_mod_link_pressed(url: String) -> void:
	OS.shell_open(url)


func _on_later_pressed() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.hide()


func _on_skip_pressed() -> void:
	var state := _load_state()
	var skipped: Dictionary = state.get("skipped", {})
	for u in _updates:
		skipped[u["uid"]] = u["remote"]
	state["skipped"] = skipped
	_save_state(state)
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.hide()


func _on_popup_hidden() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		_dialog.queue_free()
	_dialog = null
	_margin = null
	_big_font = null


# Fits the dialog to its content every frame while it is visible. Handles
# late layout passes and DD's Enlarge UI (bigger fonts -> bigger minimum
# size) without any one-shot timing assumptions. Height is clamped to the
# viewport; the RichTextLabel scrolls if clamped.
func _fit_dialog() -> void:
	if _dialog == null or not is_instance_valid(_dialog) or not _dialog.visible:
		return
	if _margin == null or not is_instance_valid(_margin):
		return
	# Keep the big font in sync with the current theme font (+5px). This is
	# what makes the title and mod links follow DD's Enlarge UI live.
	if _big_font != null:
		var base = _dialog.get_font("font", "Label")
		if base != null and base is DynamicFont:
			if _big_font.font_data != base.font_data:
				_big_font.font_data = base.font_data
			if _big_font.size != base.size + 5:
				_big_font.size = base.size + 5
	# Note: no title_height added — a WindowDialog draws its title bar above
	# rect_size, which only covers the content area.
	var content_min = _margin.get_combined_minimum_size()
	var vp = _dialog.get_viewport_rect().size
	var w = min(max(560.0, content_min.x), vp.x * 0.9)
	var h = min(content_min.y, vp.y * 0.9)
	var target := Vector2(w, h)
	if (_dialog.rect_size - target).length() > 1.0:
		_dialog.rect_size = target
		_dialog.rect_position = ((vp - target) * 0.5).floor()


# ── Local mod info + config ──────────────────────────────────────────────────

# Reads name/version/unique_id from the mod's own .ddmod, plus update_url and
# download_url either from the .ddmod itself or from update_check.json.
func _read_local_info() -> Dictionary:
	var ddmod_path := _find_ddmod_path()
	if ddmod_path == "":
		print("[MoulkUpdateChecker] No .ddmod file found in " + String(Global.Root))
		return {}
	var ddmod := _load_json(ddmod_path)
	if ddmod.empty() or not ddmod.has("version") or not ddmod.has("unique_id"):
		print("[MoulkUpdateChecker] Could not parse " + ddmod_path)
		return {}
	var update_url := String(ddmod.get("update_url", ""))
	var download_url := String(ddmod.get("download_url", ""))
	if update_url == "" or download_url == "":
		var cfg := _load_json(String(Global.Root).plus_file("update_check.json"))
		if update_url == "":
			update_url = String(cfg.get("update_url", ""))
		if download_url == "":
			download_url = String(cfg.get("download_url", ""))
	if update_url == "" or download_url == "":
		print("[MoulkUpdateChecker] Missing update_url/download_url for %s (add them to the .ddmod or to update_check.json)" % String(ddmod.get("name", "?")))
		return {}
	return {
		"name": String(ddmod.get("name", ddmod["unique_id"])),
		"uid": String(ddmod["unique_id"]),
		"local": String(ddmod["version"]),
		"update_url": update_url,
		"download_url": download_url,
	}


func _find_ddmod_path() -> String:
	var dir := Directory.new()
	if dir.open(String(Global.Root)) != OK:
		return ""
	dir.list_dir_begin(true, true)
	var found := ""
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension() == "ddmod":
			found = String(Global.Root).plus_file(fname)
			break
		fname = dir.get_next()
	dir.list_dir_end()
	return found


func _load_json(path: String) -> Dictionary:
	var f := File.new()
	if not f.file_exists(path):
		return {}
	if f.open(path, File.READ) != OK:
		return {}
	var raw := f.get_as_text()
	f.close()
	var parsed = JSON.parse(raw)
	if parsed.error != OK or not (parsed.result is Dictionary):
		return {}
	return parsed.result


# ── Skip state persistence ───────────────────────────────────────────────────

func _load_state() -> Dictionary:
	return _load_json(STATE_FILE)


func _save_state(state: Dictionary) -> void:
	var f := File.new()
	if f.open(STATE_FILE, File.WRITE) != OK:
		print("[MoulkUpdateChecker] Could not write " + STATE_FILE)
		return
	f.store_string(JSON.print(state, "\t"))
	f.close()


# ── Version comparison ───────────────────────────────────────────────────────

# Returns true if version string a is strictly greater than b.
# Compares dot-separated numeric parts; missing parts count as 0.
func _version_gt(a: String, b: String) -> bool:
	var pa := a.strip_edges().split(".")
	var pb := b.strip_edges().split(".")
	var n = int(max(pa.size(), pb.size()))
	for i in range(n):
		var va := int(pa[i]) if i < pa.size() else 0
		var vb := int(pb[i]) if i < pb.size() else 0
		if va != vb:
			return va > vb
	return false
