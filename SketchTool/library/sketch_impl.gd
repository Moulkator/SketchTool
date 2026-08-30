var script_class = "tool"

# ============================================================================
# Sketch Tool - main tool script
# ----------------------------------------------------------------------------
# Adds a "Sketch Tool" to the Effects tab that lets the user draw a rough
# draft overlay on top of the map: freehand strokes, straight lines,
# rectangles and ellipses (outlined or filled), plus an eraser.
#
# Architecture:
# * The sketch content lives in an offscreen Viewport ("A", accumulation
#   buffer, never cleared). It is displayed by a Sprite parented directly
#   under Global.World (same convention as DD's GridMesh: NEVER inside a
#   Level container such as Walls/Objects, whose C# iterations cast children
#   to native types and would crash). The Layer slider drives the Sprite's
#   z_index, so the sketch can sit anywhere in the map's Z order.
# * The stroke in progress is rendered full-opacity into a second Viewport
#   ("B", stroke buffer) and composited live by the display shader. On mouse
#   release, B is flattened once into A - at the stroke intensity for
#   drawing, or as an alpha-multiplying mask for erasing. This gives
#   Photoshop-style uniform stroke opacity (self-overlaps don't build up).
# * Undo/redo: each committed stroke pushes a custom record into DD's
#   History holding the pre/post pixels of the stroke's bounding box;
#   undo/redo stamps them back with a replace blend.
# * Persistence: sketches are stored per map in Global.ModMapData under
#   KEY_MAP_DATA, as cropped base64 PNGs + their world-space rectangle
#   (resolution independent). Several named sketches can be created; only
#   the active one is displayed/edited.
# * Export: the overlay is hidden whenever the Export window is visible and
#   for a grace period after its Okay button is pressed, so it never lands
#   in exported images (nor in the export preview).
#
# Known limitations (v1):
# * Persistence relies on Global.ModMapData being serialized into the map
#   file by DD. If that turns out to be wrong, switch _write_map_data /
#   _read_map_data to a user:// sidecar file.
# * A stroke started less than ~1 s before a manual save may not be
#   serialized yet (SAVE_DEBOUNCE). Serialization is also flushed on tool
#   switch and sketch switch.
# * Pre/post readbacks happen at stroke start/end; on very large maps
#   (4096 px sketch texture) this can cost a frame.
# * Undo after a map resize may stamp at a slightly wrong place (history
#   rects are in texture pixels; the texture is rebuilt on resize).
# ============================================================================

# Kept as "SketchLayer" for compatibility with maps saved by earlier builds.
const KEY_MAP_DATA = "Moulk.SketchLayer"
const META_OWNED = "Moulk_SketchLayer_owned"
const SETTINGS_FILE = "user://sketch_layer_settings.json"

var ext_panel = null           # set by the hot-reload loader
const TOOL_CATEGORY = "Effects"
const TOOL_ID = "sketch_tool"
const TOOL_NAME = "Sketch Tool"

# Sketch texture resolution: pixels per map cell (a DD cell is 256 world px),
# capped so the largest texture dimension never exceeds MAX_TEX_SIZE.
const RES_PER_CELL = 64.0
const MAX_TEX_SIZE = 4096.0

# If the sketch shows up vertically flipped on some driver, set this to true
# (render_target_v_flip behavior differs across GLES paths).
const FLIP_READBACK = false

const SAVE_DEBOUNCE = 1.0     # seconds of idle before serializing to map data
const EXPORT_GRACE = 10.0     # seconds the overlay stays hidden after Export OK
# Rebuilt circle-pass arcs: segments per quarter turn (DD's native
# Arc Point default is 16, i.e. ~17 points for a drawn quarter).
const ARC_SEGS_PER_QUARTER = 16
const ELLIPSE_SEGMENTS = 96

# Default presets seeded into the DD ColorPalette controls; the user's own
# presets are then managed and persisted by DD itself.
const CELL = 256.0
const WINDOW_COLOR = Color(0.45, 0.75, 1.0)
const DOOR_COLOR = Color(0.55, 0.35, 0.16)
const LABEL_COLOR = Color(0.55, 0.08, 0.08)

const PALETTE_PRESETS = ["ffffff", "000000", "5a9e3d", "1b4f8a", "7f7f7f", "c0392b", "e67e22", "f1c40f", "27ae60", "8e44ad", "16a085", "34495e"]

const DEBUG = false

const MODE_FREE = 0
const MODE_LINE = 1
const MODE_RECT = 2
const MODE_ELLIPSE = 3
const MODE_ERASE = 4
const MODE_BRUSH = 5
const MODE_SELECT = 6
const MODE_MOVE = 7
const MODE_PLAN = 8
const MODE_SETTINGS = 9
const MODE_TEXT = 10

# The accent blue of the whole UI: bright for tinted ICONS, muted for
# button BACKGROUNDS (the bright one washes white glyphs out).
const UI_BLUE = Color("5ab2ff")
const UI_BLUE_BG = Color("4d7598")

const SHAPE_OUTLINE = 0
const SHAPE_FILL = 1
const SHAPE_BOTH = 2

# ── Tool settings (global, saved in user://) ────────────────────────────────
var _mode = MODE_FREE
var _color = Color(1, 1, 1, 1)
var _width = 32.0           # world px
var _intensity = 1.0
var _eraser_width = 256.0   # world px
var _eraser_square = true
var _paint_square = false  # freehand / line brush shape (round default)
var _brush_width = 1024.0   # world px (wide paint tool)
var _brush_square = false
var _shape_style = SHAPE_OUTLINE   # session-only, always starts on Outline
var _merge_shapes = false      # shapes union-merge into overlapping shapes
var _show_tips = false             # session-only, tips hidden by default
var _fill_color = Color("7f7f7f")  # gray default: fills read as shading, not walls
var _show_button = true
var _btn_frac = null        # [fx, fy] user-dragged floating button position

# ── Per-map data (saved in ModMapData) ──────────────────────────────────────
# { "version": 1, "active": int, "next_uid": int, "layer_z": int,
#   "overlay_alpha": float, "visible": bool,
#   "sketches": [ {"uid": int, "name": String, "png": String(base64),
#                  "rect": [x, y, w, h] (world px)} ] }
var _map_data = null

# ── Scene nodes (per map load, guarded via Engine meta) ─────────────────────
var _owned = []            # nodes to free on next mod load
var _root = null           # Node2D under World, z = layer
var _display = null        # Sprite showing viewport A
var _display_mat = null    # ShaderMaterial (live stroke compositing)
var _view_a = null         # accumulation Viewport
var _view_b = null         # stroke buffer Viewport
var _stroke_item = null    # proxy Node2D inside B (draws the stroke mask)
var _cursor_item = null    # proxy Node2D under root (brush ring)
var _listener = null       # proxy Node2D driving _on_process
var _float_btn = null
var _float_handle = null
var _float_close = null
var _float_fold_btn = null
var _float_snap = null            # snapshot slot
var _float_sets = null            # settings tab shortcut
var _float_origin = null          # bar anchor (the handle sits here)
var _float_vertical = false       # bar flows downward instead of rightward
var _float_invert = false         # sub-rows on the other side of the bar
var _float_snap_area = false      # snapshot slot runs "Select Area"
var _float_segrow = []            # plan segment sub-tools row
var _float_selrow = []            # select transform sub-tools row
var _float_erarow = []            # eraser shape sub-tools row
var _float_folded = false
var _float_mode_slot = "draw"     # "draw" / "move" / "select" / "erase"
var _float_draw_sub = MODE_FREE   # last draw sub-tool used from the bar
var _float_conv_prev = false      # convert slot runs "previous settings"
var _float_subrow = []            # draw sub-tool buttons under the bar
var _float_subrow_open = false
var _float_seg_open = false
var _float_snap_open = false      # snapshot options row
var _float_conv_open = false      # convert options row
var _float_snaprow = []
var _float_convrow = []
var _float_ind = null             # kind/style indicator under the active draw tool
var _float_move = null
var _float_sel = null
var _float_era = null
var _float_sel_open = false
var _float_era_open = false
var _float_menu = null            # vertical alternative menu (right-click)
var _float_tip = null             # custom always-on-top tooltip
var _float_tip_lbl = null
var _float_tip_btn = null         # hovered button waiting for its tip
var _float_tip_wait = 0.0         # seconds without mouse motion
var _float_tip_mouse = Vector2()
var _float_toast_panel = null
var _float_toast_lbl = null
var _float_toast_t = 0.0
var _float_plan = null
var _float_text = null
var _float_rand = null
var _float_convert = null
var _float_show = null
var _float_gen = null
var _float_draw = null
var _float_clear2 = null      # floating Sketch toggle button over the map
var _rename_dialog = null
var _rename_edit = null
var _rename_mode = "rename"    # "rename" or "new" (create on confirm)
var _delete_dialog = null

var _tex_size = Vector2(64, 64)
var _tex_scale = 0.25      # tex px per world px
var _last_wox = Vector2()

# ── Materials ───────────────────────────────────────────────────────────────
var _mat_erase = null      # blend_mul: multiplies the dst down by the mask
var _mat_replace = null    # blend_disabled: writes pixels verbatim
var _mat_clear = null      # blend_disabled: writes transparent black
var _mat_premul = null     # premultiplied-alpha "over" compositing

# ── Panel UI refs ───────────────────────────────────────────────────────────
var _tool_panel = null
var _sec = null            # main section VBox (children captured for groups)
var _dropdown = null
var _cat_btns = []         # Draw / Move / Select / Erase
var _draw_btns = []        # Freehand / Line / Brush / Rectangle / Ellipse
var _draw_row = null       # row of drawing modes, hidden outside Draw
var _draw_sep = null
var _last_draw_mode = MODE_FREE
var _move_contiguous = false   # Move tool: whole sketch vs contiguous blob
var _grp_move = []
var _flood_thread = null       # background contiguous-region extraction
var _cv_thread = null
var _cv_area = null            # world Rect2: clip the next conversion
# PortalToolFix's "Above Walls" z for freestanding portals: the Portals
# container sits at z 500, Walls at 600, so 500 + 150 = 650 renders
# above the walls - and PortalToolFix recognizes exactly this value as
# its own flag, persisting these portals per map when both mods run.
const FS_ABOVE_WALLS_Z = 150
var _cv_area_pick = false      # next plan drag selects the convert area
var _cvw = null                # wizard choices for the conversion
var _cvw_dlg = null
var _cvw_esc_down = false      # Escape edge detector for the wizard
var _cvw_dump_done = false     # one panel-tree dump per session, tops
var _cvw_primed = false        # one unconditional color-prime per session
var _cvw_page = 0
var _cvw_pages = []
var _cvw_lists = {}
var _cvw_checks = {}
var _cvw_btn = null
var _cvw_back = null
var _cvw_area_btn = null
var _cvw_tab_btns = []
var _cvw_srcs = {}
var _cvw_snaps = {}
var _cvw_base_icon = {}
var _cvw_search_edits = {}
var _cvw_zoom_sliders = {}
var _cvw_fit_pending = 0   # frames left to try the 4-column fit
var _cvw_favs = {}
var _cvw_fav_toggles = {}
var _cvw_used_cache = {}       # per-key set of asset paths used on the map
var _cvw_ss_extra = 0          # optional Soft Shadows rows in the wizard
var _cvw_sort = {}             # per-page OWN sort (fallback when global unsupported)
var _cvw_sort_global = 0       # sort shared across tabs: 0 default, 1 A-Z, 2 pack, 3 size
var _cvw_sort_btns = {}        # per-page sort OptionButton
var _cvw_pillar_scale = 1.0    # placement scale of converted pillars
var _cvw_pillar_scale_spin = null
var _cvw_pillar_scale_slider = null
var _cvw_pillar_scale_sync = false
var _cvw_wall_px_lbl = null    # "Wall: N px" readout on the pillar page
var _cvw_size_thread = null    # background visible-size computation
var _cvw_size_mutex = null
var _cvw_size_results = []     # [key, original_index, Vector2]
var _cvw_size_done = false
var _cvw_size_mainq = []       # [key, oi, path] resolved via load() on main
var _cvw_wall_strips = {}
var _cvw_floor_map = []        # floor page: item index -> ["pat"/"tile", tool index]      # original index -> [strip_w, strip_h] (AtlasTexture walls)
var _cvw_overlays = {}         # page index -> dark "feature off" overlay
var _cvw_sum_box = null        # overview page content box
var _cvw_area_toggle = null    # ON: Convert Sketch waits for a rectangle
var _cvw_go_btn = null         # footer Convert Sketch (overview only)
var _cvw_crop_cache = {}       # texture instance id -> cropped AtlasTexture
var _cvw_us = -1.0             # UI scale of the wizard (EnlargeUI-aware), cached
# DEBUG SWITCH - corner-door rule visual marks on the Plan overlay:
# PINK = doors replaced by holes, GREEN = doors shifted half a cell.
# Flip to true when investigating the rule, keep false for releases.
const PLAN_DEBUG_MARKS = false
var _plan_dbg_drop = []        # pink debug: door spans replaced by holes
var _plan_dbg_shift = []       # green debug: door spans that were shifted
var _cv_wait_dlg = null        # "Converting sketch..." popup
var _cv_wait_countdown = -1    # frames before hiding it (soft shadows settle)
var _cv_size_cache = null      # path.md5 -> "WxH" (user:// persisted)
var _cvw_order = {}            # per-page display order of original indices
var _flood_ctx = null

# Floorplan generator state.
var _plan_drag = null          # {anchor, rect} while dragging the area
var _plan_pending = null       # payload waiting for the op queue
var _last_plan_payload = null  # last generated payload (transforms, saving)
var _lbl_drag = null           # {idx, off} while dragging a label
var _lbl_hover = -1
var _txt_sel = -1            # label selected by the Text tool
var _txt_drag = null
var _text_color = Color(1, 1, 1, 1)
var _text_size = 60.0
var _text_rot = 0.0    # degrees, for new texts / the selected one
var _slider_text_rot = null
var _rl_col = ""       # room label color override (html, "" = factory)
var _rl_s = 0.0        # room label scale override (0 = factory)
var _txt_edit = null
var _txt_target = null       # int (rename) or Vector2 (create)
var _txt_close_ms = 0        # when the inline editor last closed
var _grp_text = []
var _txt_color_btn = null
var _slider_text_size = null            # hovered label index in Move mode
var _seg_type = -1             # -1 off, 0 wall, 1 window, 2 door, 3 erase
var _seg_erase_rmb = false     # right-click drag erases
var _seg_tower_r = 1.5         # tower radius in cells (alt+wheel, 0.5 steps)
var _seg_tower_orient = 6      # opening position, 1/8-turn notches (0..7)
var _seg_mid_press = null      # middle press position: click cycles, drag pans
var _seg_lock = null           # drag stays on the starting line
var _seg_orient_mode = 0       # explicit orientation: 0 h, 1 v, 2 d1, 3 d2 (wheel cycles)
var _prev_tool_name = "SelectTool"  # last non-sketch tool (Sketch button returns there)
var _seg_batch = []            # segments accumulated during a drag
var _seg_dragging = false
var _seg_last_key = ""
var _seg_item = null           # hover preview overlay
var _sub_item = null           # blue overlay while dragging a subtract shape
var _seg_btns = []
var _seg_btns2 = []            # mirror row in the Draw category
var _plan_sliders_sep = null   # divider above the sliders: hides with them
var _tips_sep = null           # divider before Show Tips: hidden in Plan mode
var _seg_row2 = null
var _grp_seg = []
var _convert_records = []      # keeps conversion records alive GDScript-side
var _shape_ghost = null        # shape being placed under the mouse
var _shape_area_pick = false   # next plan drag selects an area to save
var _shape_pending_save = null
var _shape_dialog_action = ""
var _shape_name_dialog = null
var _shape_name_edit = null
var _shape_del_dialog = null
var _shape_dropdown = null
var _shape_dropdown2 = null    # mirror dropdown in the non-Plan actions block
var _grp_actions2 = []         # Clear / Convert / shape rows outside Plan
var _sel_del_frame = null      # Delete (floating selection): Select tool only
var _shape_ghost_size = Vector2()
var _ghost_item = null
var _plan_render = null        # payload currently rendered into B
var _plan_rect = Rect2()       # commit rect (tex px)
var _plan_countdown = -1
var _last_plan_area = null     # last generated world rect (Reroll)
var _last_plan_undo = null     # {rect (tex), pre (Image), labels_n}: Reroll
var _labels_item = null        # world overlay drawing the room labels
var _plan_big_font = null      # enlarged DynamicFont (crisp labels)
var _plan_pend_labels = []
var _plan_was_clear = false
var _clear_labels_before = null
var _plan_cur_towers = []      # [corner cell pos, radius] per build variant
var _plan_diag_pts = []        # lattice points already used by diagonals
var _plan_bevel_tris = []      # [px, py, k, bsize] per bevel, for emission clipping
var _plan_all_runs = []        # all runs of the current variant (clearance)
var _plan_corr_ids = {}        # corridor room ids (must keep their width)
var _plan_archetype = {}       # active archetype def ({} = Custom)
var _plan_last_shape = ""      # envelope shape picked by the last build
var _plan_env_circle = null    # [cx, cy, r] in cells when the envelope is a disc
var _plan_env_symx = false     # envelope is x-symmetric: accretion mirrors its bays
var _plan_net_chambers = []    # sparse networks: one array of Rect2s per chamber
var _plan_oriel_pts = []       # bow-window bay corners: always chamfered by the bevel pass
var _plan_proc_suite = null    # [nave, chancel, sanctuary] Rect2s when the envelope IS the suite
var _plan_proc_bumps = []      # open alcove rects welded onto the nave (side chapels, porch)
var _plan_proc_apse = null     # [cx_cells, cy_cells, r_cells] rounded apse to emit
var _plan_proc_annex = []      # [[Rect2, cat], ...] one-room annexes (transept arms, sacristies)
var _plan_bailey = null        # {court, keep, gate} rects when the envelope is a walled bailey
var _plan_small_mode = false   # few-big-rooms mode for small footprints
var _plan_prison_leftover = 0  # rotating label index for off-size prison rooms
var _plan_arch_dd = null       # archetype OptionButton
var _plan_min = 3
var _plan_max = 8
var _plan_complexity = 0.5
var _plan_corr = 0.5           # corridor density
var _plan_orig = 0.5           # Exterior Shape
var _plan_room_irr = 0.3       # Room Irregularity (L-rooms, chamfers)
var _plan_labels = false
var _plan_openings = true      # generate doors and windows
var _plan_tower_count = 2
var _ui_rng = null             # UI-side RNG, never touched by seed()
var _plan_rand_flags = {"min": false, "max": false, "cpx": false, "corr": false, "orig": false, "irr": false, "towers": false}
var _plan_rand_btns = {}
var _btn_rand_global = null
var _plan_ext_only = false
var _plan_lock_ext = false     # External Seed locked (silhouette)
var _plan_lock_int = false     # Internal Seed locked (room layout)
var _seed_edit_ext = null
var _seed_edit_int = null
var _lock_btn_ext = null
var _lock_btn_int = null
var _rr_btn_ext = null
var _rr_btn_int = null
var _plan_cur_seed_ext = 0
var _plan_cur_seed_int = 0
var _grp_plan = []
var _slider_plan_min = null
var _slider_plan_max = null
var _slider_plan_cpx = null
var _slider_plan_corr = null
var _slider_plan_orig = null
var _slider_plan_towers = null
var _slider_plan_irr = null
var _plan_slider_ui = []       # labels + slider rows, hidden under an archetype
var _style_btns = []
var _eraser_shape_boxes = []
var _paint_shape_boxes = []
var _brush_shape_boxes = []
var _slider_brush_width = null
var _chk_tips = null
var _grp_shape_style = []  # controls shown only for Rectangle/Ellipse
var _grp_fill_color = []   # controls shown only when the style includes Fill
var _grp_stroke_color = [] # stroke color, hidden for Eraser and Fill-only style
var _grp_stroke_width = [] # stroke width, only for Freehand/Line/Shapes
var _grp_opacity = []      # opacity, hidden for the Eraser
var _lbl_stroke_color = null
var _quick_btns = []
var _quick_row = null
var _brush_qsb = null
var _brush_swatch = null   # colour bar under the Brush kind glyph
var _quick_sep = null      # divider above the paint-kind row
var _brush_qsb2 = null
var _paint_kind = 0            # 0 free brush, 1 wall, 2 window, 3 door
var _snap_probe_done = false
var _grp_brush = []        # brush shape/width, Brush only
var _grp_tips = []         # shortcuts note, shown by the Show Tips toggle
var _grp_eraser = []       # controls shown only for the Eraser tool
var _chk_visible = null
var _chk_button = null
var _slider_layer = null
var _slider_alpha = null
var _slider_width = null
var _width_lbl = null
var _wsteps = []   # fixed non-linear width steps: fine low, coarse high
var _slider_intensity = null
var _slider_e_width = null
var _color_btn = null
var _fill_color_btn = null
var _sync_ui = false       # true while programmatically updating controls

# ── Runtime state ───────────────────────────────────────────────────────────
var _tool_active = false
var _button_unlocked = false   # floating button appears after first activation
var _stroke = null             # current stroke dict or null
var _stroke_dragging = false
var _commit_countdown = -1     # frames until B is flattened into A
var _pre_image = null          # full A snapshot taken at stroke start
var _last_free_pt = null       # last freehand endpoint (Shift+click line)
var _stroke_button = BUTTON_LEFT
var _btn_drag_active = false
var _btn_drag_moved = false
var _btn_press_pos = Vector2()
var _btn_start_pos = Vector2()

var _ops = []                  # queued composite operations into A
var _op_busy = 0               # frames left on the running op
var _op_nodes = []
var _op_callback = ""
var _op_callback_args = []

var _save_countdown = -1.0
var _export_grace = 0.0
var _export_hidden = false
var _ok_hooked = false
var _mapsize_hooked = false
var _mapsize_left = null
var _mapsize_top = null
var _resize_offset = Vector2()
var _resize_check_frames = 0   # per-frame resize polling right after Okay
var _saved_cursor_mode = -1
var _content_ctrl = null

# Selection tool state. _sel is null or a Dictionary:
# state: "marquee" (dragging the rect), "liftwait" (waiting for the op queue
# before lifting), "float" (floating selection).
# rect_world/rect_tex: source region; img/tex: lifted pixels; pre: full A
# snapshot at lift time; copy: Ctrl was held (source not erased);
# center (world), rot (radians), drag ({grab, start} or null).
var _sel = null
var _sel_sprite = null
var _sel_commit_sprite = null
var _sel_item = null
var _slider_rotation = null
var _grp_select = []
var _grp_sketchmgr = []    # Sketches manager, shown in the Settings tab
var _grp_display = []      # Show Sketch / Floatbar / Layer / Opacity (Settings tab)
var _tips_notes = {}       # per-mode tips notes
var _chk_fvert = null
var _chk_finv = null
var _float_corner_btns = []
var _grp_act_shapes = []   # convert + snapshot + load block of the actions
var _key_prev = {}
var _startup_lock = true       # blocks map-state callbacks until re-apply
var _reapply_queue = [0.5, 1.0]
var _throttle_a = 0.0          # 0.25 s: button position, ring refresh
var _throttle_b = 0.0          # 1.0 s: export hook retry, map resize check

var _RecordScript = null
var _ProxyScript = null

var _dbg_input_logged = 0
var _dbg_process_logged = false


func _dbg(msg: String) -> void:
	if DEBUG:
		print("[SketchTool][DBG] ", msg)


# ============================================================================
# Startup
# ============================================================================

# Map-reload teardown: best effort, never blocks the reload.
# Show/hide the sketch through the normal checkbox handler (used by the
# conversion undo/redo).
func set_sketch_shown(v: bool) -> void:
	if _chk_visible != null and is_instance_valid(_chk_visible):
		_chk_visible.pressed = v
	_on_visible_toggled(v)


func teardown() -> bool:
	if _cv_thread != null or _flood_thread != null:
		printerr("[SketchTool] teardown: background thread still running (leaked)")
	_flush_serialize()
	_write_map_data()
	if _tool_panel != null and is_instance_valid(_tool_panel) and _tool_panel.Align != null:
		for c in _tool_panel.Align.get_children():
			c.queue_free()
	for n in _owned:
		if n != null and is_instance_valid(n):
			n.queue_free()
	_owned = []
	Engine.set_meta(META_OWNED, _owned)
	# The wizard dialog was in _owned: drop the stale reference, or the
	# next _cvw_open dereferences a freed node and dies before the popup.
	_cvw_dlg = null
	if _cvw_size_thread != null:
		_cvw_size_thread.wait_to_finish()
		_cvw_size_thread = null
	return true


func boot() -> void:
	printerr("[SketchTool] build 2026-08-12-BRIDGE3")
	# Free nodes left over by a previous mod load (map reload).
	if Engine.has_meta(META_OWNED):
		for n in Engine.get_meta(META_OWNED):
			if n != null and is_instance_valid(n):
				n.queue_free()
	_owned = []
	Engine.set_meta(META_OWNED, _owned)

	_ProxyScript = ResourceLoader.load(Global.Root + "library/sketch_node_proxy.gd", "GDScript", true)
	_RecordScript = ResourceLoader.load(Global.Root + "library/sketch_history_record.gd", "GDScript", true)
	if _ProxyScript == null or _RecordScript == null:
		push_error("[SketchTool] library scripts missing, aborting")
		return

	_load_settings()
	_read_map_data()
	_create_materials()
	_build_world_nodes()
	_register_tool_panel()
	_toolset_place_under_roof()
	_build_float_button()
	_build_dialogs()

	# Initial content: clear A, then stamp the active sketch's saved image.
	_queue_clear()
	_queue_load_active()
	_apply_display()
	# A map that carries sketch content shows the floating button right
	# away (the user toggle still wins).
	if _show_button and _float_btn != null and is_instance_valid(_float_btn):
		var has_content = false
		for sk in _map_data["sketches"]:
			if String(sk.get("png", "")) != "":
				has_content = true
				break
		if has_content:
			# Through the unlock flag: the periodic visibility sync ANDs
			# it in and was re-hiding the button right after boot.
			_button_unlocked = true
			_update_button_visibility()
			_float_sync_side_buttons()
	print("[SketchTool] Initialized (tex ", _tex_size, ", scale ", _tex_scale, ")")


func tick(_delta: float) -> void:
	_cvw_size_poll()
	# Exclusive popups swallow Escape: close the wizard by hand on the
	# key's press edge (poll-based, so it works whatever holds focus).
	var esc_dn = Input.is_key_pressed(KEY_ESCAPE)
	if esc_dn and not _cvw_esc_down and _cvw_dlg != null \
			and is_instance_valid(_cvw_dlg) and _cvw_dlg.visible:
		_cvw_dlg.hide()
	_cvw_esc_down = esc_dn
	if _float_menu != null and is_instance_valid(_float_menu):
		# Stays open while the mouse wanders; a CLICK outside closes it.
		# Armed only once the opening right-click is released.
		var pressed_now = Input.is_mouse_button_pressed(BUTTON_LEFT) \
				or Input.is_mouse_button_pressed(BUTTON_RIGHT)
		if not bool(_float_menu.get_meta("armed")):
			if not pressed_now:
				_float_menu.set_meta("armed", true)
		elif pressed_now:
			var mp = _float_menu.get_global_mouse_position()
			if not Rect2(_float_menu.rect_global_position, _float_menu.rect_size) \
					.has_point(mp):
				# A click on the ANCHOR itself is left to the anchor's
				# pressed handler, which toggles the menu closed -
				# closing here made the same click reopen it.
				var anch = _float_menu.get_meta("anchor")
				var on_anchor = anch != null and is_instance_valid(anch) \
					and Rect2(anch.rect_global_position, anch.rect_size).has_point(mp)
				if not on_anchor:
					_float_close_menu()
	_float_refresh_states()
	if _cvw_fit_pending > 0:
		# The wizard lists get a real width a few frames after popup.
		if _cvw_dlg == null or not is_instance_valid(_cvw_dlg):
			_cvw_fit_pending = 0
		elif _cvw_fit_columns():
			_cvw_fit_pending = 0
		else:
			_cvw_fit_pending -= 1
	if _float_toast_t > 0.0:
		_float_toast_t -= _delta
		if _float_toast_t <= 0.0 and _float_toast_panel != null \
				and is_instance_valid(_float_toast_panel):
			_float_toast_panel.visible = false
	if _float_tip_btn != null:
		if not is_instance_valid(_float_tip_btn) or not _float_tip_btn.visible:
			_float_tip_btn = null
			_float_tip_hide()
		else:
			var tm = _float_tip_btn.get_global_mouse_position()
			if tm.distance_to(_float_tip_mouse) > 2.0:
				# Moving resets the countdown (and hides an open tip).
				_float_tip_mouse = tm
				_float_tip_wait = 0.0
				_float_tip_hide()
			elif _float_tip == null or not is_instance_valid(_float_tip) \
					or not _float_tip.visible:
				_float_tip_wait += _delta
				if _float_tip_wait >= 1.0:
					_float_tip_show(_float_tip_btn)
	if _cv_wait_countdown > 0:
		_cv_wait_countdown -= 1
		if _cv_wait_countdown == 0 and _cv_wait_dlg != null \
				and is_instance_valid(_cv_wait_dlg):
			_cv_wait_dlg.hide()
	if _tool_active:
		# The cursor overlay used to refresh on mouse motion only:
		# popups and focus loss starve those events and the brush ring
		# lags behind. One update() per frame on a tiny overlay is
		# free.
		_update_cursor()
		if _cv_area_pick:
			if _cursor_item != null and is_instance_valid(_cursor_item):
				_cursor_item.visible = true
				_cursor_item.update()
			Input.set_default_cursor_shape(Input.CURSOR_CROSS)
	var atn = Global.Editor.get("ActiveToolName")
	if atn != null and String(atn) != TOOL_ID and String(atn) != "":
		_prev_tool_name = String(atn)
	# All per-frame work runs in the listener's _process (it keeps running
	# during modal windows such as Export, unlike mod update()).
	pass


# ============================================================================
# Settings (global, user://)
# ============================================================================

func _load_settings() -> void:
	# Disk file: ONLY the UI prefs that should survive a DD restart (floating
	# button visibility and position). Every tool setting restarts fresh.
	var f = File.new()
	if f.file_exists(SETTINGS_FILE) and f.open(SETTINGS_FILE, File.READ) == OK:
		var parsed = JSON.parse(f.get_as_text())
		f.close()
		if parsed.error == OK and parsed.result is Dictionary:
			var d = parsed.result
			_show_button = bool(d.get("show_button", _show_button))
			_float_folded = bool(d.get("float_folded", false))
			_float_mode_slot = String(d.get("float_mode", "draw"))
			_float_conv_prev = bool(d.get("float_conv_prev", false))
			_float_snap_area = bool(d.get("float_snap_area", false))
			_rl_col = String(d.get("rl_col", ""))
			_rl_s = float(d.get("rl_s", 0.0))
			_plan_labels = bool(d.get("plan_labels", _plan_labels))
			var bf = d.get("btn_frac", null)
			if bf is Array and bf.size() == 2:
				_btn_frac = [float(bf[0]), float(bf[1])]
	# Every tool setting (mode, colors, widths, opacity, eraser, style, tips)
	# intentionally resets to its default on every map load: nothing is
	# carried over between maps or sessions.


func _save_settings() -> void:
	var d = {"v": 3, "show_button": _show_button,
		"float_folded": _float_folded, "float_mode": _float_mode_slot,
		"float_conv_prev": _float_conv_prev, "float_snap_area": _float_snap_area,
		"rl_col": _rl_col, "rl_s": _rl_s, "plan_labels": _plan_labels}
	if _btn_frac != null:
		d["btn_frac"] = _btn_frac
	var f = File.new()
	if f.open(SETTINGS_FILE, File.WRITE) == OK:
		f.store_line(JSON.print(d, "\t"))
		f.close()


# ============================================================================
# Per-map data (ModMapData)
# ============================================================================

func _default_map_data():
	return {
		"version": 1,
		"active": 0,
		"next_uid": 2,
		"layer_z": 800,
		"overlay_alpha": 1.0,
		"visible": true,
		"sketches": [{"uid": 1, "name": "Sketch 1", "png": "", "rect": [0, 0, 0, 0]}]
	}


func _read_map_data() -> void:
	_map_data = _default_map_data()
	if Global.get("ModMapData") == null:
		return
	var d = Global.ModMapData.get(KEY_MAP_DATA)
	if d is Dictionary and d.has("sketches") and d["sketches"] is Array and d["sketches"].size() > 0:
		_map_data = d
		_map_data["active"] = int(clamp(int(_map_data.get("active", 0)), 0, d["sketches"].size() - 1))


func _write_map_data() -> void:
	if Global.get("ModMapData") == null:
		return
	Global.ModMapData[KEY_MAP_DATA] = _map_data


func _active_sketch():
	return _map_data["sketches"][int(_map_data["active"])]


func _sketch_index_by_uid(uid: int) -> int:
	var arr = _map_data["sketches"]
	for i in range(arr.size()):
		if int(arr[i]["uid"]) == uid:
			return i
	return -1


# ============================================================================
# Materials & shaders
# ============================================================================

func _make_shader_material(code: String):
	var sh = Shader.new()
	sh.code = code
	var mat = ShaderMaterial.new()
	mat.shader = sh
	return mat


func _create_materials() -> void:
	# Eraser: blend_mul multiplies both RGB and alpha of the destination.
	# RGB is kept (x1), alpha is scaled down by the stroke mask coverage.
	# The whole texture pipeline works in PREMULTIPLIED alpha: RGB stored in
	# the accumulation buffer is already scaled by coverage, which removes
	# the dark fringes that straight-alpha blending leaves on AA edges.
	_mat_premul = CanvasItemMaterial.new()
	_mat_premul.blend_mode = CanvasItemMaterial.BLEND_MODE_PREMULT_ALPHA
	# Eraser: scales ALL channels down (premultiplied-consistent). The x4
	# sharpening removes the m*(1-m) ghost outline left when erasing over
	# the antialiased edge of a painted stroke.
	_mat_erase = _make_shader_material("""shader_type canvas_item;
render_mode blend_mul;
uniform float strength = 1.0;
void fragment() {
	float m = clamp(texture(TEXTURE, UV).a * 4.0, 0.0, 1.0);
	float f = 1.0 - strength * m;
	COLOR = vec4(f, f, f, f);
}
""")
	# Replace: writes the source pixels verbatim (alpha included).
	_mat_replace = _make_shader_material("""shader_type canvas_item;
render_mode blend_disabled;
void fragment() {
	COLOR = texture(TEXTURE, UV);
}
""")
	# Clear: writes transparent black verbatim.
	_mat_clear = _make_shader_material("""shader_type canvas_item;
render_mode blend_disabled;
void fragment() {
	COLOR = vec4(0.0);
}
""")
	# Display: shows A (premultiplied), composites the live stroke buffer B
	# on top (premul "over"), applies the overlay opacity, and outputs with
	# premultiplied blending.
	_display_mat = _make_shader_material("""shader_type canvas_item;
render_mode blend_premul_alpha;
uniform sampler2D stroke_tex;
uniform float stroke_mode = 0.0;
uniform float stroke_intensity = 1.0;
uniform float overlay_alpha = 1.0;
void fragment() {
	vec4 base = texture(TEXTURE, UV);
	if (stroke_mode > 1.5) {
		float m = clamp(texture(stroke_tex, UV).a * 4.0, 0.0, 1.0);
		base *= 1.0 - stroke_intensity * m;
	} else if (stroke_mode > 0.5) {
		vec4 s = texture(stroke_tex, UV) * stroke_intensity;
		base = s + base * (1.0 - s.a);
	}
	COLOR = base * overlay_alpha;
}
""")


# ============================================================================
# World nodes
# ============================================================================

func _compute_tex_size() -> void:
	var wox = Global.World.WoxelDimensions
	_last_wox = wox
	var s = RES_PER_CELL / 256.0
	var m = max(wox.x, wox.y) * s
	if m > MAX_TEX_SIZE:
		s = MAX_TEX_SIZE / max(wox.x, wox.y)
	_tex_scale = s
	_tex_size = Vector2(max(1, round(wox.x * s)), max(1, round(wox.y * s)))


func _make_viewport(clear_always: bool):
	var v = Viewport.new()
	v.size = _tex_size
	v.transparent_bg = true
	v.usage = Viewport.USAGE_2D
	v.disable_3d = true
	v.gui_disable_input = true
	v.render_target_v_flip = true
	v.render_target_update_mode = Viewport.UPDATE_DISABLED
	if clear_always:
		v.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
	else:
		v.render_target_clear_mode = Viewport.CLEAR_MODE_NEVER
	return v


func _make_proxy(draw_method: String, process_method: String):
	var n = _ProxyScript.new()
	n.handler = self
	n.draw_method = draw_method
	n.process_method = process_method
	return n


func _build_world_nodes() -> void:
	_compute_tex_size()

	_root = Node2D.new()
	_root.name = "SketchLayerRoot"
	_root.z_index = int(clamp(int(_map_data["layer_z"]), -4000, 4000))
	Global.World.add_child(_root)
	_owned.append(_root)

	_view_a = _make_viewport(false)
	_view_a.name = "SketchViewA"
	_root.add_child(_view_a)

	_view_b = _make_viewport(true)
	_view_b.name = "SketchViewB"
	_root.add_child(_view_b)

	_stroke_item = _make_proxy("_draw_stroke_buffer", "")
	_stroke_item.name = "SketchStrokeItem"
	_view_b.add_child(_stroke_item)

	_display = Sprite.new()
	_display.name = "SketchDisplay"
	_display.centered = false
	_display.position = Vector2()
	_display.texture = _view_a.get_texture()
	_view_a.get_texture().flags = 0
	_view_b.get_texture().flags = 0
	_display.scale = Vector2(1.0 / _tex_scale, 1.0 / _tex_scale)
	_display.material = _display_mat
	_display_mat.set_shader_param("stroke_tex", _view_b.get_texture())
	_display_mat.set_shader_param("stroke_mode", 0.0)
	_display_mat.set_shader_param("overlay_alpha", float(_map_data["overlay_alpha"]))
	_root.add_child(_display)

	_labels_item = _make_proxy("_draw_labels", "")
	_labels_item.name = "SketchLabelsOverlay"
	_labels_item.visible = false
	_root.add_child(_labels_item)

	_sel_item = _make_proxy("_draw_select", "")
	_sel_item.name = "SketchSelectOverlay"
	_sel_item.visible = false
	_root.add_child(_sel_item)

	_cursor_item = _make_proxy("_draw_cursor", "")
	_cursor_item.name = "SketchCursor"
	_cursor_item.visible = false
	_root.add_child(_cursor_item)

	_listener = _make_proxy("", "_on_process")
	_listener.input_method = "_on_raw_input"
	_listener.name = "SketchListener"
	_root.add_child(_listener)


func _rebuild_world_nodes() -> void:
	# Map was resized: serialize with the old texture, rebuild at the new
	# size and re-stamp the saved image (world rect is resolution independent).
	_cancel_stroke()
	_flush_or_bypass()
	if _resize_offset != Vector2():
		# Shift every sketch so it stays aligned with the map content after
		# cells were added/removed on the left/top side.
		for sk in _map_data["sketches"]:
			var r = sk["rect"]
			if r is Array and r.size() == 4:
				sk["rect"] = [float(r[0]) + _resize_offset.x, float(r[1]) + _resize_offset.y, float(r[2]), float(r[3])]
			if sk.has("labels"):
				for lb in sk["labels"]:
					lb["x"] = float(lb["x"]) + _resize_offset.x
					lb["y"] = float(lb["y"]) + _resize_offset.y
		_resize_offset = Vector2()
		_write_map_data()
	for n in [_root]:
		if n != null and is_instance_valid(n):
			_owned.erase(n)
			n.queue_free()
	_build_world_nodes()
	_queue_clear()
	_queue_load_active()
	_apply_display()
	print("[SketchTool] Rebuilt after map resize (tex ", _tex_size, ")")


func _nodes_ok() -> bool:
	return _root != null and is_instance_valid(_root) \
		and _view_a != null and is_instance_valid(_view_a) \
		and _view_b != null and is_instance_valid(_view_b)


# ============================================================================
# Tool panel UI
# ============================================================================

# Moves the Sketch Tool button right under the Roof Tool inside its
# Toolset category (CreateModTool only appends at the end). Purely a
# defensive scan - unknown structure leaves the order untouched.
func _toolset_place_under_roof() -> void:
	var ts = Global.Editor.get("Toolset")
	if ts == null or not (ts is Node):
		return
	var mine = _toolset_find_button(ts, ["sketch_tool", "sketch tool"])
	var roof = _toolset_find_button(ts, ["rooftool", "roof tool", "roof"])
	if mine == null or roof == null:
		printerr("[SketchTool] toolset reposition skipped (buttons not found)")
		return
	var rp = roof.get_parent()
	if rp == null:
		return
	if mine.get_parent() != rp:
		mine.get_parent().remove_child(mine)
		rp.add_child(mine)
	rp.move_child(mine, roof.get_index() + 1)


# First BaseButton in the subtree whose name, tooltip or text matches
# one of the needles (case-insensitive; exact name match wins).
func _toolset_find_button(root: Node, needles: Array):
	var best = null
	var stack = [root]
	while not stack.empty():
		var n = stack.pop_back()
		if n is BaseButton:
			var nm = String(n.name).to_lower()
			var tip = ""
			if n is Control:
				tip = String(n.hint_tooltip).to_lower()
			var txt = String(n.get("text")).to_lower() if n.get("text") != null else ""
			for nd in needles:
				var ndl = String(nd).to_lower()
				if nm == ndl:
					return n
				if best == null and (nm.find(ndl) >= 0 or tip.find(ndl) >= 0 \
						or txt.find(ndl) >= 0):
					best = n
		for ch in n.get_children():
			stack.append(ch)
	return best


func _register_tool_panel() -> void:
	if ext_panel != null:
		# Hot-reload path: the loader registered the tool once and hands
		# the existing panel over; re-registering the same tool id would
		# duplicate it in the toolset.
		_tool_panel = ext_panel
	else:
		var icon = Global.Root + "icons/sketch_tool.png"
		_tool_panel = Global.Editor.Toolset.CreateModTool(self, TOOL_CATEGORY, TOOL_ID, TOOL_NAME, icon)
	if _tool_panel == null:
		push_error("[SketchTool] CreateModTool failed")
		return

	# Small right padding so controls aren't glued to the panel edge. DD keeps
	# a direct reference to Align (C# field), so reparenting it under a
	# MarginContainer is safe for DD's own accesses.
	var align = _tool_panel.Align
	if align != null and is_instance_valid(align) and not (align.get_parent() is MarginContainer):
		var wrap = MarginContainer.new()
		wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		wrap.add_constant_override("margin_right", 10)
		var align_parent = align.get_parent()
		align_parent.remove_child(align)
		align_parent.add_child(wrap)
		wrap.add_child(align)

	# Tool selector: category row (Draw - Move - Select - Erase) on top, and
	# the drawing modes row below it, visible only while Draw is active.
	var cat_group = ButtonGroup.new()
	var cat_row = HBoxContainer.new()
	cat_row.set("custom_constants/separation", 0)
	var cat_defs = [
		[["mode_draw"], "Draw", -1],
		[["move", "mode_move"], "Move", MODE_MOVE],
		[["mode_select"], "Select", MODE_SELECT],
		[["mode_eraser"], "Eraser", MODE_ERASE],
		[["text"], "Text", MODE_TEXT],
		[["mode_plan"], "Plan", MODE_PLAN],
		[["settings"], "Settings", MODE_SETTINGS]
	]
	_cat_btns = []
	for def in cat_defs:
		var cb = Button.new()
		cb.toggle_mode = true
		cb.group = cat_group
		cb.focus_mode = Control.FOCUS_NONE
		cb.hint_tooltip = def[1]
		var ctex = _load_icon_any(def[0])
		if ctex != null:
			cb.icon = _ui_icon(ctex)
		else:
			cb.text = def[1]
		cb.connect("pressed", self, "_on_cat_pressed", [def[2]])
		# Slimmer side padding: seven tabs have to share the panel.
		for sbk in ["normal", "hover", "pressed", "focus", "disabled"]:
			var csb = cb.get_stylebox(sbk)
			if csb != null:
				csb = csb.duplicate()
				csb.content_margin_left = 5
				csb.content_margin_right = 5
				cb.add_stylebox_override(sbk, csb)
		cat_row.add_child(cb)
		_cat_btns.append(cb)
	_tool_panel.Align.add_child(cat_row)
	_draw_sep = HSeparator.new()
	_tool_panel.Align.add_child(_draw_sep)

	var draw_group = ButtonGroup.new()
	_draw_row = HBoxContainer.new()
	_draw_row.alignment = BoxContainer.ALIGN_CENTER
	var draw_defs = [
		["mode_freehand", "Freehand", MODE_FREE],
		["mode_line", "Line", MODE_LINE],
		["mode_rect", "Rectangle", MODE_RECT],
		["mode_ellipse", "Ellipse", MODE_ELLIPSE]
	]
	_draw_btns = []
	for def in draw_defs:
		var mb = Button.new()
		mb.toggle_mode = true
		mb.group = draw_group
		mb.focus_mode = Control.FOCUS_NONE
		mb.hint_tooltip = def[1]
		var tex = _load_icon(def[0])
		if tex != null:
			mb.icon = _ui_icon(tex)
		else:
			mb.text = def[1]
		mb.connect("pressed", self, "_on_draw_mode_pressed", [def[2]])
		_draw_row.add_child(mb)
		_draw_btns.append(mb)
	_tool_panel.Align.add_child(_draw_row)
	if _mode != MODE_SELECT and _mode != MODE_MOVE and _mode != MODE_ERASE and _mode != MODE_PLAN:
		_last_draw_mode = _mode
	_update_mode_buttons()

	_sec = _tool_panel.BeginSection(false)

	# -- Shape style (Rectangle/Ellipse only), single row --------------------
	var mark = _sec.get_child_count()
	var style_labels = ["Outline", "Fill", "Both"]
	var style_icons = ["style_outline", "style_fill", "style_both"]
	var style_row = HBoxContainer.new()
	style_row.alignment = BoxContainer.ALIGN_CENTER
	var style_lbl = Label.new()
	style_lbl.text = "Shape Style"
	style_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	style_row.add_child(style_lbl)
	var style_group = ButtonGroup.new()
	for i in range(style_labels.size()):
		# Icon-only buttons at natural size, left-aligned; the label lives
		# in the tooltip.
		var sb = Button.new()
		var sicon = _load_icon(style_icons[i])
		if sicon != null:
			sb.icon = _ui_icon(sicon)
		else:
			sb.text = style_labels[i]
		sb.hint_tooltip = style_labels[i]
		sb.toggle_mode = true
		sb.group = style_group
		sb.focus_mode = Control.FOCUS_NONE
		sb.connect("pressed", self, "_on_shape_style_pressed", [i])
		style_row.add_child(sb)
		_style_btns.append(sb)
		if i == _shape_style:
			sb.pressed = true
	_sec.add_child(style_row)
	var chk_mg = _tool_panel.CreateCheckButton("Merge Shapes", "sk_merge_shapes", _merge_shapes)
	chk_mg.hint_tooltip = "New rectangles and ellipses UNION with the shapes they overlap: crossing outline parts inside the merged silhouette are erased. Best used while blocking out a building's massing."
	chk_mg.connect("toggled", self, "_on_merge_shapes_toggled")
	_merge_shapes = chk_mg.pressed
	_grp_shape_style = _capture_since(mark)

	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Fill Color")
	_fill_color_btn = _tool_panel.CreateColorPalette("sk_fill_color", true, _fill_color.to_html(), PALETTE_PRESETS, false, false)
	_fill_color_btn.connect("color_changed", self, "_on_fill_color_changed")
	_grp_fill_color = _capture_since(mark)

	# -- Stroke settings (hidden for the Eraser) -----------------------------
	var qrow = HBoxContainer.new()
	qrow.alignment = BoxContainer.ALIGN_CENTER
	qrow.set("custom_constants/separation", 14)
	_quick_btns = []
	# Free brush + the three fixed paint kinds. Fixed kinds lock color,
	# width (walls 32, portals 16) and opacity; the brush dot's
	# background follows the free color from the picker. Icons live in
	# their own TextureRect so the button state never tints them.
	_quick_sep = HSeparator.new()
	_sec.add_child(_quick_sep)
	for qdef in [["Brush (free color and size)", "brush", Color(0.35, 0.35, 0.35), 0],
			["Wall", "wall", Color(0, 0, 0), 1],
			["Window", "window", WINDOW_COLOR, 2],
			["Door", "door", DOOR_COLOR, 3]]:
		var qb = Button.new()
		qb.toggle_mode = true
		qb.focus_mode = Control.FOCUS_NONE
		qb.hint_tooltip = qdef[0]
		# Office-suite "font color" look: white glyph + a small colour
		# bar underneath (the STROKE colour, not a tool state) - the
		# segment sub-tools keep their bare glyphs, so the bar itself
		# reads as "this is a colour".
		# Plain theme toggle, exactly like the draw-mode row above:
		# same background, same pressed accent.
		var qside = int(round(48.0 * _ui_scale()))
		qb.rect_min_size = Vector2(qside, qside)
		var qvb = VBoxContainer.new()
		qvb.anchor_right = 1.0
		qvb.anchor_bottom = 1.0
		qvb.alignment = BoxContainer.ALIGN_CENTER
		qvb.set("custom_constants/separation", 2)
		qvb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var qcc = CenterContainer.new()
		qcc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var qtr = TextureRect.new()
		qtr.texture = _make_white_icon(qdef[1], 24)
		qtr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		qb.set_meta("glyph", qtr)
		qcc.add_child(qtr)
		qvb.add_child(qcc)
		var qcc2 = CenterContainer.new()
		qcc2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var swatch = ColorRect.new()
		swatch.color = qdef[2]
		swatch.rect_min_size = Vector2(int(round(24.0 * _ui_scale())), 5)
		swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
		qcc2.add_child(swatch)
		qvb.add_child(qcc2)
		qb.add_child(qvb)
		if int(qdef[3]) == 0:
			# The brush swatch tracks the live Stroke Color.
			_brush_swatch = swatch
			swatch.color = _color
		qb.connect("pressed", self, "_on_paint_kind", [int(qdef[3])])
		qrow.add_child(qb)
		_quick_btns.append(qb)
	_sec.add_child(qrow)
	_quick_row = qrow
	_kind_sync()
	mark = _sec.get_child_count()
	_lbl_stroke_color = _tool_panel.CreateLabel("Stroke Color")
	_color_btn = _tool_panel.CreateColorPalette("sk_color", true, _color.to_html(), PALETTE_PRESETS, false, false)
	_color_btn.connect("color_changed", self, "_on_color_changed")
	_grp_stroke_color = _capture_since(mark)
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Width")
	_wsteps_ensure()
	var wrow = HBoxContainer.new()
	_slider_width = HSlider.new()
	_slider_width.min_value = 0
	_slider_width.max_value = _wsteps.size() - 1
	_slider_width.step = 1
	_slider_width.value = _wstep_index(_width)
	_slider_width.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slider_width.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_slider_width.connect("value_changed", self, "_on_width_changed")
	wrow.add_child(_slider_width)
	_width_lbl = Label.new()
	_width_lbl.rect_min_size = Vector2(52, 0)
	_width_lbl.align = Label.ALIGN_RIGHT
	wrow.add_child(_width_lbl)
	_sec.add_child(wrow)
	_width_label_sync()
	_add_reset_button(_slider_width, float(_wstep_index(32.0)))
	_tool_panel.CreateLabel("Brush Shape")
	var pshape_labels = ["Round", "Square"]
	var pshape_boxes = _tool_panel.CreateRadioMenu("sk_paint_shape", pshape_labels)
	_paint_shape_boxes = pshape_boxes
	for psi in range(pshape_boxes.size()):
		pshape_boxes[psi].connect("pressed", self, "_on_paint_shape_pressed", [psi])
		pshape_boxes[psi].text = pshape_labels[psi]
	var pshp = 0
	if _paint_square:
		pshp = 1
	if pshp < pshape_boxes.size():
		pshape_boxes[pshp].pressed = true
	_radio_row(pshape_boxes)
	_grp_stroke_width = _capture_since(mark)

	# -- Brush settings (Brush only) -----------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Brush Shape")
	var b_shape_labels = ["Round", "Square"]
	var b_shape_boxes = _tool_panel.CreateRadioMenu("sk_brush_shape", b_shape_labels)
	_brush_shape_boxes = b_shape_boxes
	for i in range(b_shape_boxes.size()):
		b_shape_boxes[i].connect("pressed", self, "_on_brush_shape_pressed", [i])
		b_shape_boxes[i].text = b_shape_labels[i]
	var bshp = 0
	if _brush_square:
		bshp = 1
	if bshp < b_shape_boxes.size():
		b_shape_boxes[bshp].pressed = true
	_tool_panel.CreateLabel("Width")
	_slider_brush_width = _tool_panel.CreateSlider("sk_brush_width", _brush_width, 128.0, 4096.0, 1.0, true)
	_slider_brush_width.connect("value_changed", self, "_on_brush_width_changed")
	_widen_slider_spinbox(_slider_brush_width, 78.0)
	_add_reset_button(_slider_brush_width, 1024.0)
	_grp_brush = _capture_since(mark)

	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Opacity")
	_slider_intensity = _tool_panel.CreateSlider("sk_intensity", _intensity, 0.05, 1.0, 0.01, false)
	_slider_intensity.connect("value_changed", self, "_on_intensity_changed")
	_add_reset_button(_slider_intensity, 1.0)
	_grp_opacity = _capture_since(mark)

	# -- Segment editor sub-tools (Plan): first row of the section --------
	mark = _sec.get_child_count()
	var seg_row = HBoxContainer.new()
	_sec.add_child(HSeparator.new())
	var seg_defs = [["wall", "Wall segments (wheel: orientation, middle click: next type; drag chains along the line)", 0],
		["window", "Window segments (wheel: orientation, middle click: next type)", 1],
		["door", "Door segments (wheel: orientation, middle click: next type)", 2],
		["tower", "Tower (3/4 circle; wheel: rotate opening in 1/8 turns, alt+wheel: radius, right-click: erase the disc, middle click: next type)", 4],
		["erase", "Erase segments (right-click drag erases too)", 3]]
	_seg_btns = []
	for si in range(seg_defs.size()):
		var sb2 = Button.new()
		sb2.toggle_mode = true
		sb2.focus_mode = Control.FOCUS_NONE
		sb2.hint_tooltip = seg_defs[si][1]
		# The default pressed style is barely visible: plain blue.
		var sbp = StyleBoxFlat.new()
		sbp.bg_color = UI_BLUE_BG
		sbp.corner_radius_top_left = 4
		sbp.corner_radius_top_right = 4
		sbp.corner_radius_bottom_left = 4
		sbp.corner_radius_bottom_right = 4
		sb2.add_stylebox_override("pressed", sbp)
		var stex = _make_small_icon(_load_icon(seg_defs[si][0]), 22)
		if stex != null:
			# Button.icon hugs the left edge on this Godot fork
			# (icon_align is a no-op): center a TextureRect instead.
			sb2.rect_min_size = Vector2(0, 30)
			var scc = CenterContainer.new()
			scc.anchor_right = 1.0
			scc.anchor_bottom = 1.0
			scc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var str2 = TextureRect.new()
			str2.texture = stex
			str2.mouse_filter = Control.MOUSE_FILTER_IGNORE
			scc.add_child(str2)
			sb2.add_child(scc)
		else:
			sb2.text = seg_defs[si][1].split(" ")[0]
		sb2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sb2.set_meta("seg_tid", int(seg_defs[si][2]))
		sb2.pressed = int(seg_defs[si][2]) == _seg_type
		sb2.connect("pressed", self, "_on_seg_type", [int(seg_defs[si][2])])
		seg_row.add_child(sb2)
		_seg_btns.append(sb2)
	_sec.add_child(seg_row)
	_grp_seg = _capture_since(mark)

	# -- Floorplan generator (Plan only) -------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Floorplan")
	var plan_hint = Label.new()
	plan_hint.text = "Drag a rectangle on the map to generate."
	plan_hint.autowrap = true
	_sec.add_child(plan_hint)
	# Archetype: one architectural personality per entry, applied as a
	# slider preset plus a room-name theme. Custom leaves everything alone.
	var arch_row = HBoxContainer.new()
	var arch_lbl = Label.new()
	arch_lbl.text = "Archetype"
	arch_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	arch_row.add_child(arch_lbl)
	_plan_arch_dd = OptionButton.new()
	_plan_arch_dd.focus_mode = Control.FOCUS_NONE
	_plan_arch_dd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var dd_pos = 0
	for ai in range(PLAN_ARCHETYPES.size()):
		if bool(PLAN_ARCHETYPES[ai].get("hidden", false)):
			# The full table stays in code; the dropdown only shows the
			# curated set being actively worked on.
			continue
		_plan_arch_dd.add_item(String(PLAN_ARCHETYPES[ai]["name"]), ai)
		_plan_arch_dd.get_popup().set_item_tooltip(dd_pos, String(PLAN_ARCHETYPES[ai].get("desc", "")))
		dd_pos += 1
	_plan_arch_dd.selected = 0
	_plan_arch_dd.hint_tooltip = String(PLAN_ARCHETYPES[0].get("desc", ""))
	_plan_arch_dd.connect("item_selected", self, "_on_plan_archetype_selected")
	arch_row.add_child(_plan_arch_dd)
	_sec.add_child(arch_row)
	# Shape library: Save / Load / Rename / Delete on one line, then the
	# shape dropdown, then the generator actions.
	_vspace()
	var row_shp = HBoxContainer.new()
	for shb in [_icon_button("save", "Snapshot: save a shape (last roll, whole sketch or an area)", "_on_shape_save_menu", "Save"),
			_icon_button("rename", "Rename the selected shape", "_on_shape_rename", "Ren"),
			_icon_button("delete", "Delete the selected shape", "_on_shape_delete", "Del")]:
		var sh_fr = _white_frame(shb)
		sh_fr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_shp.add_child(sh_fr)
	_sec.add_child(row_shp)
	var row_load = HBoxContainer.new()
	_shape_dropdown = OptionButton.new()
	_shape_dropdown.focus_mode = Control.FOCUS_NONE
	_shape_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Picking a shape in the list LOADS it right away (the ghost lands
	# under the mouse), EVERY time - item_selected only fires on a
	# change, so re-picking the same entry did nothing: the internal
	# popup's index_pressed fires on every choice.
	_shape_dropdown.get_popup().connect("index_pressed", self, "_on_shape_picked")
	row_load.add_child(_shape_dropdown)
	var btn_load = Button.new()
	btn_load.text = "Load"
	btn_load.focus_mode = Control.FOCUS_NONE
	btn_load.hint_tooltip = "Place the selected shape under the mouse: click to stamp, wheel to rotate (Z: 5°, Z+Shift: 1°), Alt+wheel to zoom"
	btn_load.icon = _make_small_icon(_load_icon("load"), 18)
	btn_load.connect("pressed", self, "_on_shape_load")
	var load_frame = _white_frame(btn_load)
	row_load.add_child(load_frame)
	_sec.add_child(row_load)
	_shape_refresh_dropdown()
	var btn_whole = Button.new()
	btn_whole.text = "Generate on Whole Map"
	btn_whole.icon = _make_small_icon(_load_icon("generate"), 18)
	btn_whole.focus_mode = Control.FOCUS_NONE
	btn_whole.connect("pressed", self, "_on_plan_whole_map")
	_sec.add_child(_white_frame(btn_whole))
	var btn_reroll = Button.new()
	btn_reroll.text = "Reroll"
	btn_reroll.icon = _make_small_icon(_load_icon("reroll"), 18)
	btn_reroll.focus_mode = Control.FOCUS_NONE
	btn_reroll.connect("pressed", self, "_on_plan_reroll")
	var btn_pclear = Button.new()
	btn_pclear.text = "Clear"
	btn_pclear.icon = _make_small_icon(_load_icon("clear"), 18)
	btn_pclear.focus_mode = Control.FOCUS_NONE
	btn_pclear.connect("pressed", self, "_on_clear_canvas")
	var row_rc = HBoxContainer.new()
	var fr_reroll = _white_frame(btn_reroll)
	fr_reroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_rc.add_child(fr_reroll)
	var fr_pclear = _white_frame(btn_pclear)
	fr_pclear.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_rc.add_child(fr_pclear)
	_sec.add_child(row_rc)
	var btn_conv = Button.new()
	btn_conv.text = "Convert to DD Walls"
	btn_conv.icon = _make_small_icon(_load_icon("convert"), 18)
	btn_conv.focus_mode = Control.FOCUS_NONE
	btn_conv.hint_tooltip = "Converts the sketch into native DD walls and portals (one undo step). The wizard asks whether to convert everything or a selected area."
	btn_conv.connect("pressed", self, "_on_plan_convert")
	_sec.add_child(_white_frame(btn_conv))
	var btn_rand = Button.new()
	btn_rand.toggle_mode = true
	btn_rand.focus_mode = Control.FOCUS_NONE
	btn_rand.hint_tooltip = "Randomize the settings at each generation"
	var dice = _load_icon("dice-icon")
	if dice != null:
		btn_rand.icon = dice
	btn_rand.text = "Randomize Settings"
	btn_rand.connect("toggled", self, "_on_plan_auto_random_toggled")
	_sec.add_child(_white_frame(btn_rand))
	_btn_rand_global = btn_rand
	var row_tf = HBoxContainer.new()
	for tfb in [_icon_button("rotate90ccw", "Rotate 90° counter-clockwise (last roll)", "_on_plan_rotate_ccw", "CCW"),
			_icon_button("rotate90", "Rotate 90° (last roll)", "_on_plan_rotate", "R90"),
			_icon_button("h_sym", "Horizontal symmetry (last roll)", "_on_plan_sym_h", "H"),
			_icon_button("v_sym", "Vertical symmetry (last roll)", "_on_plan_sym_v", "V")]:
		var tf_fr = _white_frame(tfb)
		tf_fr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_tf.add_child(tf_fr)
	_sec.add_child(row_tf)
	# Two independent seeds: the External one drives the silhouette
	# (envelope, towers, bevels, apse), the Internal one the room layout.
	# Lock the External and reroll the Internal to stack building floors.
	randomize()
	var seed_defs = [["Shape Seed", "ext"], ["Rooms Seed", "int"]]
	for sd in seed_defs:
		var srow = HBoxContainer.new()
		var slbl = Label.new()
		slbl.text = sd[0]
		slbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		srow.add_child(slbl)
		var sedit = LineEdit.new()
		sedit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sedit.text = str(randi() % 1000000)
		srow.add_child(sedit)
		var lbtn = Button.new()
		lbtn.focus_mode = Control.FOCUS_NONE
		lbtn.hint_tooltip = "Lock this seed (kept on Generate / Reroll)"
		var ul_ic = _make_small_icon(_load_icon("unlock"), 18)
		if ul_ic != null:
			lbtn.icon = ul_ic
		else:
			lbtn.text = "U"
		lbtn.connect("pressed", self, "_on_plan_seed_lock", [sd[1]])
		srow.add_child(lbtn)
		var rbtn = Button.new()
		rbtn.focus_mode = Control.FOCUS_NONE
		rbtn.hint_tooltip = "Reroll only this seed"
		var rr_ic = _make_small_icon(_load_icon("reroll"), 18)
		if rr_ic != null:
			rbtn.icon = rr_ic
		else:
			rbtn.text = "R"
		rbtn.connect("pressed", self, "_on_plan_seed_reroll", [sd[1]])
		srow.add_child(rbtn)
		_sec.add_child(srow)
		if sd[1] == "ext":
			_seed_edit_ext = sedit
			_lock_btn_ext = lbtn
			_rr_btn_ext = rbtn
		else:
			_seed_edit_int = sedit
			_lock_btn_int = lbtn
			_rr_btn_int = rbtn
	var chk_ext = _tool_panel.CreateCheckButton("Exterior Walls Only", "sk_plan_ext", _plan_ext_only)
	chk_ext.connect("toggled", self, "_on_plan_ext_only_toggled")
	var chk_open = _tool_panel.CreateCheckButton("Doors & Windows", "sk_plan_openings", _plan_openings)
	chk_open.connect("toggled", self, "_on_plan_openings_toggled")
	var chk_lbl = _tool_panel.CreateCheckButton("Room Labels", "sk_plan_labels", _plan_labels)
	chk_lbl.pressed = _plan_labels
	chk_lbl.connect("toggled", self, "_on_plan_labels_toggled")
	_tool_panel.CreateSeparator()
	_plan_sliders_sep = _sec.get_child(_sec.get_child_count() - 1)
	_tool_panel.CreateLabel("Room Min Size")
	_slider_plan_min = _tool_panel.CreateSlider("sk_plan_min", float(_plan_min), 1.0, 8.0, 1.0, false)
	_slider_plan_min.connect("value_changed", self, "_on_plan_min_changed")
	_add_reset_button(_slider_plan_min, 3.0)
	_add_rand_toggle(_slider_plan_min, "min")
	_tool_panel.CreateLabel("Room Max Size")
	_slider_plan_max = _tool_panel.CreateSlider("sk_plan_max", float(_plan_max), 4.0, 24.0, 1.0, false)
	_slider_plan_max.connect("value_changed", self, "_on_plan_max_changed")
	_add_reset_button(_slider_plan_max, 8.0)
	_add_rand_toggle(_slider_plan_max, "max")
	_tool_panel.CreateLabel("Room Density")
	_slider_plan_cpx = _tool_panel.CreateSlider("sk_plan_cpx", _plan_complexity, 0.0, 1.0, 0.05, false)
	_slider_plan_cpx.connect("value_changed", self, "_on_plan_cpx_changed")
	_add_reset_button(_slider_plan_cpx, 0.5)
	_add_rand_toggle(_slider_plan_cpx, "cpx")
	_tool_panel.CreateLabel("Corridor Density")
	_slider_plan_corr = _tool_panel.CreateSlider("sk_plan_corr", _plan_corr, 0.0, 1.0, 0.05, false)
	_slider_plan_corr.connect("value_changed", self, "_on_plan_corr_changed")
	_add_reset_button(_slider_plan_corr, 0.5)
	_add_rand_toggle(_slider_plan_corr, "corr")
	_tool_panel.CreateLabel("Building Shape Oddity")
	_slider_plan_orig = _tool_panel.CreateSlider("sk_plan_orig", _plan_orig, 0.0, 1.0, 0.05, false)
	_slider_plan_orig.connect("value_changed", self, "_on_plan_orig_changed")
	_add_reset_button(_slider_plan_orig, 0.5)
	_add_rand_toggle(_slider_plan_orig, "orig")
	_tool_panel.CreateLabel("Room Shape Oddity")
	_slider_plan_irr = _tool_panel.CreateSlider("sk_plan_irr", _plan_room_irr, 0.0, 1.0, 0.05, false)
	_slider_plan_irr.connect("value_changed", self, "_on_plan_irr_changed")
	_add_reset_button(_slider_plan_irr, 0.3)
	_add_rand_toggle(_slider_plan_irr, "irr")
	_tool_panel.CreateLabel("Towers")
	_slider_plan_towers = _tool_panel.CreateSlider("sk_plan_towers", float(_plan_tower_count), 0.0, 8.0, 1.0, false)
	_slider_plan_towers.connect("value_changed", self, "_on_plan_towers_changed")
	_add_reset_button(_slider_plan_towers, 2.0)
	_add_rand_toggle(_slider_plan_towers, "towers")
	# Slider rows collected for archetype hiding (the row wraps slider,
	# spinbox, reset and dice). CreateLabel's return can't be trusted:
	# the label is recovered as the row's previous sibling instead.
	_plan_slider_ui = []
	for sl_ui in [_slider_plan_min, _slider_plan_max, _slider_plan_cpx, _slider_plan_corr,
			_slider_plan_orig, _slider_plan_irr, _slider_plan_towers]:
		if sl_ui == null or not is_instance_valid(sl_ui):
			continue
		var row_ui = sl_ui.get_parent()
		if row_ui == null:
			continue
		_plan_slider_ui.append(row_ui)
		var par_ui = row_ui.get_parent()
		var ridx = row_ui.get_index()
		if par_ui != null and ridx > 0:
			var sib = par_ui.get_child(ridx - 1)
			if sib is Label:
				_plan_slider_ui.append(sib)
	# DD restores persisted control values without always firing callbacks:
	# read everything back so the vars match what the panel displays.
	if _slider_plan_min != null:
		_plan_min = int(_slider_plan_min.value)
	if _slider_plan_max != null:
		_plan_max = int(_slider_plan_max.value)
	if _slider_plan_cpx != null:
		_plan_complexity = float(_slider_plan_cpx.value)
	if _slider_plan_corr != null:
		_plan_corr = float(_slider_plan_corr.value)
	if _slider_plan_orig != null:
		_plan_orig = float(_slider_plan_orig.value)
	if _slider_plan_irr != null:
		_plan_room_irr = float(_slider_plan_irr.value)
	if _slider_plan_towers != null:
		_plan_tower_count = int(_slider_plan_towers.value)
	_grp_plan = _capture_since(mark)


	# -- Move settings (Move only) -------------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Move")
	var mv_labels = ["Everything", "Contiguous"]
	var mv_boxes = _tool_panel.CreateRadioMenu("sk_move_choice", mv_labels)
	for i in range(mv_boxes.size()):
		mv_boxes[i].connect("pressed", self, "_on_move_choice_pressed", [i])
		mv_boxes[i].text = mv_labels[i]
	var mvi = 0
	if _move_contiguous:
		mvi = 1
	if mvi < mv_boxes.size():
		mv_boxes[mvi].pressed = true
	_radio_row(mv_boxes)
	_grp_move = _capture_since(mark)

	# -- Selection settings (Select only) ------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Rotation")
	_slider_rotation = _tool_panel.CreateSlider("sk_sel_rotation", 0.0, -180.0, 180.0, 1.0, false)
	_slider_rotation.connect("value_changed", self, "_on_sel_rotation_changed")
	_add_reset_button(_slider_rotation, 0.0)
	_vspace()
	var sel_tf_row = HBoxContainer.new()
	for stf in [_icon_button("rotate90ccw", "Rotate 90° counter-clockwise (selection, or whole sketch)", "_on_tf_ccw", "CCW"),
			_icon_button("rotate90", "Rotate 90° clockwise (selection, or whole sketch)", "_on_tf_cw", "R90"),
			_icon_button("h_sym", "Horizontal symmetry (selection, or whole sketch)", "_on_tf_h", "H"),
			_icon_button("v_sym", "Vertical symmetry (selection, or whole sketch)", "_on_tf_v", "V")]:
		var stf_fr = _white_frame(stf)
		stf_fr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sel_tf_row.add_child(stf_fr)
	_sec.add_child(sel_tf_row)
	_grp_select = _capture_since(mark)

	# -- Text settings (Text only) -------------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Text Color")
	_txt_color_btn = _tool_panel.CreateColorPalette("sk_text_color", true, _text_color.to_html(), PALETTE_PRESETS, false, false)
	_txt_color_btn.connect("color_changed", self, "_on_text_color_changed")
	_tool_panel.CreateLabel("Text Size")
	_slider_text_size = _tool_panel.CreateSlider("sk_text_size", _text_size, 8.0, 240.0, 1.0, true)
	_slider_text_size.connect("value_changed", self, "_on_text_size_changed")
	_add_reset_button(_slider_text_size, 60.0)
	_tool_panel.CreateLabel("Text Rotation")
	_slider_text_rot = _tool_panel.CreateSlider("sk_text_rot", _text_rot, -180.0, 180.0, 1.0, true)
	_slider_text_rot.connect("value_changed", self, "_on_text_rot_changed")
	_add_reset_button(_slider_text_rot, 0.0)
	_vspace()
	var rl_use = Button.new()
	rl_use.text = "Use Current Settings for Room Labels"
	rl_use.focus_mode = Control.FOCUS_NONE
	rl_use.hint_tooltip = "Applies the color and size above to every existing room label, and to all future generated ones (kept across maps)."
	rl_use.connect("pressed", self, "_on_rl_use_pressed")
	_sec.add_child(_white_frame(rl_use))
	var rl_rst = Button.new()
	rl_rst.text = "Reset Room Labels Factory Settings"
	rl_rst.focus_mode = Control.FOCUS_NONE
	rl_rst.hint_tooltip = "Room labels go back to the stock look, existing and future."
	rl_rst.connect("pressed", self, "_on_rl_reset_pressed")
	_sec.add_child(_white_frame(rl_rst))
	_grp_text = _capture_since(mark)

	# -- Eraser settings (Eraser only) ---------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateLabel("Eraser Shape")
	var shape_labels = ["Square", "Round"]
	var shape_boxes = _tool_panel.CreateRadioMenu("sk_eraser_shape", shape_labels)
	_eraser_shape_boxes = shape_boxes
	for i in range(shape_boxes.size()):
		shape_boxes[i].connect("pressed", self, "_on_eraser_shape_pressed", [i])
		shape_boxes[i].text = shape_labels[i]
	var shp = 1
	if _eraser_square:
		shp = 0
	if shp < shape_boxes.size():
		shape_boxes[shp].pressed = true
	_radio_row(shape_boxes)
	_tool_panel.CreateLabel("Eraser Width")
	_slider_e_width = _tool_panel.CreateSlider("sk_e_width", _eraser_width, 1.0, 512.0, 1.0, true)
	_slider_e_width.connect("value_changed", self, "_on_e_width_changed")
	_add_reset_button(_slider_e_width, 256.0)
	_grp_eraser = _capture_since(mark)

	# -- Common actions (every non-Plan mode): the Plan tab's Clear /
	# Convert / shape-library controls, mirrored full width ----------------
	mark = _sec.get_child_count()
	_vspace()
	var row_dc = HBoxContainer.new()
	var btn_del2 = Button.new()
	btn_del2.text = "Delete"
	btn_del2.icon = _make_small_icon(_load_icon("delete"), 18)
	btn_del2.focus_mode = Control.FOCUS_NONE
	btn_del2.hint_tooltip = "Delete the floating selection"
	btn_del2.connect("pressed", self, "_on_sel_delete_btn")
	var del_fr = _white_frame(btn_del2)
	del_fr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Deleting a floating selection only makes sense in the Select
	# tool: everywhere else the slot hides and Clear takes the row.
	_sel_del_frame = del_fr
	row_dc.add_child(del_fr)
	var btn_clr2 = Button.new()
	btn_clr2.text = "Clear Sketch"
	btn_clr2.icon = _make_small_icon(_load_icon("clear"), 18)
	btn_clr2.focus_mode = Control.FOCUS_NONE
	btn_clr2.connect("pressed", self, "_on_clear_canvas")
	var clr_fr = _white_frame(btn_clr2)
	clr_fr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row_dc.add_child(clr_fr)
	_sec.add_child(row_dc)
	_grp_actions2 = _capture_since(mark)
	mark = _sec.get_child_count()
	var btn_conv2 = Button.new()
	btn_conv2.text = "Convert to DD Walls"
	btn_conv2.icon = _make_small_icon(_load_icon("convert"), 18)
	btn_conv2.focus_mode = Control.FOCUS_NONE
	btn_conv2.hint_tooltip = "Converts the sketch into native DD walls and portals (one undo step). The wizard asks whether to convert everything or a selected area."
	btn_conv2.connect("pressed", self, "_on_plan_convert")
	_sec.add_child(_white_frame(btn_conv2))
	var row_shp2 = HBoxContainer.new()
	for shb2 in [_icon_button("save", "Snapshot: save a shape (last roll, whole sketch or an area)", "_on_shape_save_menu", "Save"),
			_icon_button("rename", "Rename the selected shape", "_on_shape_rename", "Ren"),
			_icon_button("delete", "Delete the selected shape", "_on_shape_delete", "Del")]:
		var sh_fr2 = _white_frame(shb2)
		sh_fr2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row_shp2.add_child(sh_fr2)
	_sec.add_child(row_shp2)
	var row_load2 = HBoxContainer.new()
	_shape_dropdown2 = OptionButton.new()
	_shape_dropdown2.focus_mode = Control.FOCUS_NONE
	_shape_dropdown2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shape_dropdown2.get_popup().connect("index_pressed", self, "_on_shape_picked2")
	row_load2.add_child(_shape_dropdown2)
	var btn_load2 = Button.new()
	btn_load2.text = "Load"
	btn_load2.focus_mode = Control.FOCUS_NONE
	btn_load2.hint_tooltip = "Place the selected shape under the mouse: click to stamp, wheel to rotate (Z: 5°, Z+Shift: 1°), Alt+wheel to zoom"
	btn_load2.icon = _make_small_icon(_load_icon("load"), 18)
	btn_load2.connect("pressed", self, "_on_shape_load")
	row_load2.add_child(_white_frame(btn_load2))
	_sec.add_child(row_load2)
	_grp_act_shapes = _capture_since(mark)
	_shape_refresh_dropdown()

	_tool_panel.CreateSeparator()
	_tips_sep = _sec.get_child(_sec.get_child_count() - 1)
	_chk_tips = _tool_panel.CreateCheckButton("Show Tips", "sk_show_tips", _show_tips)
	_chk_tips.connect("toggled", self, "_on_show_tips_toggled")
	mark = _sec.get_child_count()
	# One note per mode: the visible one always matches the active tab
	# (short lines, autowrap handles the rest).
	for tdef in [
			["draw", "Shift+Click (Freehand): line from the last point.\nShift held (Freehand): lock to horizontal / vertical.\nShift (Line): snap to 45 degrees.\nShift (Shapes): 1:1 ratio.\nAlt (Shapes): draw from center.\nRight-click drag: erase with the current tool.\nRight-click drag (Shapes, Merge Shapes on): carve a hole.\nMouse wheel: brush size.\nEsc: cancel the stroke."],
			["select", "Drag: select a region (Ctrl at release: copy).\nDrag inside: move the selection.\nAlt+drag inside: duplicate.\nWheel: rotate.\nEnter / click outside: apply.\nDel: delete. Esc: cancel.\nWith nothing selected, the Rotation slider and the\nrotate / mirror buttons act on the whole sketch."],
			["move", "Drag: move everything, or only the blob under the\ncursor (Contiguous).\nAlt+drag: move a copy."],
			["text", "Click empty space: create a text.\nClick a text: rename it.\nDrag the zone around a text: move it.\nWheel: size. Alt+wheel: rotate.\nDel: delete the hovered text.\nRoom labels from the Plan generator are\nedited the same way."],
			["plan", "Drag: pick the generation area (Draw Area).\nSegments: drag chains along a wall line.\nMouse wheel: segment orientation.\nMiddle click: next segment type.\nRight-click drag: erase segments.\nEsc: cancel the pending segment."]]:
		_tool_panel.CreateNote(tdef[1])
		_tips_notes[tdef[0]] = _sec.get_child(_sec.get_child_count() - 1)
	_grp_tips = _capture_since(mark)

	# -- Sketches (Settings tab) ---------------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateSeparator()
	_tool_panel.CreateLabel("Sketches")
	_dropdown = _tool_panel.CreateDropdownMenu("sk_active_sketch", ["Sketch 1"], "Sketch 1")
	_dropdown.connect("item_selected", self, "_on_sketch_selected")
	_vspace()
	var sk_row = HBoxContainer.new()
	var sk_btn_labels = ["New", "Rename", "Delete"]
	var sk_btn_methods = ["_on_new_sketch", "_on_rename_sketch", "_on_delete_sketch"]
	for i in range(sk_btn_labels.size()):
		var skb = Button.new()
		skb.text = sk_btn_labels[i]
		skb.focus_mode = Control.FOCUS_NONE
		skb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		skb.connect("pressed", self, sk_btn_methods[i])
		sk_row.add_child(skb)
	_sec.add_child(sk_row)
	_grp_sketchmgr = _capture_since(mark)

	# -- Display (Settings tab) ----------------------------------------------
	mark = _sec.get_child_count()
	_tool_panel.CreateSeparator()
	_tool_panel.CreateLabel("Layer")
	_slider_layer = _tool_panel.CreateSlider("sk_layer", float(_map_data["layer_z"]), -500.0, 900.0, 1.0, false)
	_slider_layer.connect("value_changed", self, "_on_layer_changed")
	_add_reset_button(_slider_layer, 800.0)
	_tool_panel.CreateLabel("Overlay Opacity")
	_slider_alpha = _tool_panel.CreateSlider("sk_alpha", float(_map_data["overlay_alpha"]), 0.0, 1.0, 0.01, false)
	_slider_alpha.connect("value_changed", self, "_on_alpha_changed")
	_add_reset_button(_slider_alpha, 1.0)
	_chk_visible = _tool_panel.CreateCheckButton("Show Sketch", "sk_show", true)
	_chk_visible.connect("toggled", self, "_on_visible_toggled")
	_chk_button = _tool_panel.CreateCheckButton("Show Floatbar", "sk_show_btn", _show_button)
	_chk_button.connect("toggled", self, "_on_show_button_toggled")
	_chk_fvert = _tool_panel.CreateCheckButton("Vertical Floatbar", "sk_float_vertical", _float_vertical)
	_chk_fvert.connect("toggled", self, "_on_float_vertical_toggled")
	_chk_finv = _tool_panel.CreateCheckButton("Invert Floatbar Sides", "sk_float_invert", _float_invert)
	_chk_finv.connect("toggled", self, "_on_float_invert_toggled")
	_float_bar_opts_sync()
	_grp_display = _capture_since(mark)

	_tool_panel.EndSection()
	_refresh_dropdown()
	_sync_display_controls()
	_update_panel_visibility()


func _load_icon_any(names: Array):
	for n in names:
		var tex = _load_icon(String(n))
		if tex != null:
			return tex
	return null


func _load_icon(name: String):
	var img = Image.new()
	if img.load(Global.Root + "icons/" + name + ".png") != OK:
		return null
	var tex = ImageTexture.new()
	tex.create_from_image(img, Texture.FLAG_FILTER)
	return tex


func _capture_since(mark: int) -> Array:
	var out = []
	if _sec == null or not is_instance_valid(_sec):
		return out
	for i in range(mark, _sec.get_child_count()):
		out.append(_sec.get_child(i))
	return out


func _set_group_visible(grp: Array, vis: bool) -> void:
	for n in grp:
		if n != null and is_instance_valid(n):
			n.visible = vis


# Archetypes own their structure: the sliders hide (they would lie) and
# Randomize greys out (it only shuffles those sliders). Re-applied after
# EVERY group-visibility pass - _set_group_visible(_grp_plan, ...) shows
# the whole group again, so a mere segment sub-tool click used to
# resurrect the hidden sliders.
func _apply_arch_ui_state() -> void:
	var is_custom = _plan_archetype.empty() or String(_plan_archetype.get("id", "")) == "custom"
	var plan = _mode == MODE_PLAN
	for sc in _plan_slider_ui:
		if sc != null and is_instance_valid(sc):
			sc.visible = plan and is_custom
	if _plan_sliders_sep != null and is_instance_valid(_plan_sliders_sep):
		_plan_sliders_sep.visible = plan and is_custom
	if _btn_rand_global != null and is_instance_valid(_btn_rand_global):
		_btn_rand_global.disabled = not is_custom
		if is_custom:
			_btn_rand_global.hint_tooltip = "Randomize the settings at each generation"
		else:
			_btn_rand_global.hint_tooltip = "Disabled under an archetype (it only shuffles the hidden sliders)"
	if _float_rand != null and is_instance_valid(_float_rand):
		# The floatbar mirror greys out with the panel button.
		_float_rand.disabled = not is_custom
		if is_custom:
			_float_rand.hint_tooltip = "Randomize Settings (toggle)"
		else:
			_float_rand.hint_tooltip = "Disabled under an archetype (it only shuffles the hidden sliders)"
		_float_rand.modulate = Color(1, 1, 1, 1) if is_custom else Color(1, 1, 1, 0.45)
	if _tips_sep != null and is_instance_valid(_tips_sep):
		# The separator lives and dies with its Show Tips checkbox:
		# whenever the tips block hides (Plan, Eraser, Settings), two
		# separators would otherwise stack up as a doubled divider.
		_tips_sep.visible = _chk_tips != null and is_instance_valid(_chk_tips) \
			and _chk_tips.visible


# DD persists tool-panel control values (keyed by the property strings given
# to the Create* API) in its own config and restores them at startup, firing
# our callbacks with last session's values. We push our authoritative values
# back onto every control shortly after startup (twice, in case DD's restore
# pass runs late).
func _apply_control_values() -> void:
	_startup_lock = false
	_sync_ui = true
	if _slider_width != null and is_instance_valid(_slider_width):
		_slider_width.value = _wstep_index(_width)
	_width_label_sync()
	if _slider_intensity != null and is_instance_valid(_slider_intensity):
		_slider_intensity.value = _intensity
	if _slider_e_width != null and is_instance_valid(_slider_e_width):
		_slider_e_width.value = _eraser_width
	if _slider_brush_width != null and is_instance_valid(_slider_brush_width):
		_slider_brush_width.value = _brush_width
	if _color_btn != null and is_instance_valid(_color_btn):
		if _color_btn.has_method("SetColor"):
			_color_btn.SetColor(_color, false)
		else:
			_color_btn.set("color", _color)
	if _fill_color_btn != null and is_instance_valid(_fill_color_btn):
		if _fill_color_btn.has_method("SetColor"):
			_fill_color_btn.SetColor(_fill_color, false)
		else:
			_fill_color_btn.set("color", _fill_color)
	if _mode != MODE_SELECT and _mode != MODE_MOVE and _mode != MODE_ERASE:
		_last_draw_mode = _mode
	_update_mode_buttons()
	if _shape_style >= 0 and _shape_style < _style_btns.size():
		var stb = _style_btns[_shape_style]
		if stb != null and is_instance_valid(stb):
			stb.pressed = true
	var shp = 1
	if _eraser_square:
		shp = 0
	if shp < _eraser_shape_boxes.size():
		var eb = _eraser_shape_boxes[shp]
		if eb != null and is_instance_valid(eb):
			eb.pressed = true
	var bshp = 0
	if _brush_square:
		bshp = 1
	if bshp < _brush_shape_boxes.size():
		var bb = _brush_shape_boxes[bshp]
		if bb != null and is_instance_valid(bb):
			bb.pressed = true
	if _chk_button != null and is_instance_valid(_chk_button):
		_chk_button.pressed = _show_button
	if _chk_tips != null and is_instance_valid(_chk_tips):
		_chk_tips.pressed = _show_tips
	if _slider_rotation != null and is_instance_valid(_slider_rotation):
		_slider_rotation.value = 0.0
	if _slider_plan_min != null and is_instance_valid(_slider_plan_min):
		_slider_plan_min.value = float(_plan_min)
	if _slider_plan_max != null and is_instance_valid(_slider_plan_max):
		_slider_plan_max.value = float(_plan_max)
	if _slider_plan_cpx != null and is_instance_valid(_slider_plan_cpx):
		_slider_plan_cpx.value = _plan_complexity
	if _slider_plan_orig != null and is_instance_valid(_slider_plan_orig):
		_slider_plan_orig.value = _plan_orig
	if _slider_plan_irr != null and is_instance_valid(_slider_plan_irr):
		_slider_plan_irr.value = _plan_room_irr
	if _slider_plan_towers != null and is_instance_valid(_slider_plan_towers):
		_slider_plan_towers.value = float(_plan_tower_count)
	_sync_ui = false
	_sync_display_controls()
	_refresh_dropdown()
	_update_panel_visibility()
	_update_button_visibility()


func _update_panel_visibility() -> void:
	var shapes = _mode == MODE_RECT or _mode == MODE_ELLIPSE
	var fill_only = shapes and _shape_style == SHAPE_FILL
	var setting = _mode == MODE_SETTINGS
	var draws = _mode != MODE_ERASE and _mode != MODE_SELECT and _mode != MODE_MOVE and not setting \
		and _mode != MODE_TEXT
	_set_group_visible(_grp_seg, _mode == MODE_PLAN)
	_set_group_visible(_grp_shape_style, shapes)
	_set_group_visible(_grp_fill_color, shapes and _shape_style != SHAPE_OUTLINE)
	# The paint-kind row lives in Freehand and Line only; a fixed kind
	# locks color/width/opacity, so their controls hide with it.
	var kind_row_on = _mode == MODE_FREE or _mode == MODE_LINE
	var fixed_kind = kind_row_on and _paint_kind != 0
	if _quick_row != null and is_instance_valid(_quick_row):
		_quick_row.visible = kind_row_on
	if _quick_sep != null and is_instance_valid(_quick_sep):
		_quick_sep.visible = kind_row_on
	_set_group_visible(_grp_stroke_color, draws and _mode != MODE_PLAN and not fill_only and not fixed_kind)
	_set_group_visible(_grp_stroke_width, (_mode == MODE_FREE or _mode == MODE_LINE) and not fixed_kind)
	_set_group_visible(_grp_opacity, draws and _mode != MODE_PLAN and not fixed_kind)
	_set_group_visible(_grp_brush, _mode == MODE_BRUSH)
	_set_group_visible(_grp_eraser, _mode == MODE_ERASE)
	_set_group_visible(_grp_move, _mode == MODE_MOVE)
	_set_group_visible(_grp_text, _mode == MODE_TEXT)
	_set_group_visible(_grp_plan, _mode == MODE_PLAN)
	_set_group_visible(_grp_select, _mode == MODE_SELECT)
	# Tips: the note matching the current mode, checkbox everywhere the
	# tips exist (Plan included again, Eraser and Settings excluded).
	var tips_mode = ""
	if _mode == MODE_SELECT:
		tips_mode = "select"
	elif _mode == MODE_MOVE:
		tips_mode = "move"
	elif _mode == MODE_PLAN:
		tips_mode = "plan"
	elif _mode == MODE_TEXT:
		tips_mode = "text"
	elif _mode != MODE_ERASE and not setting:
		tips_mode = "draw"
	if _chk_tips != null and is_instance_valid(_chk_tips):
		_chk_tips.visible = tips_mode != ""
	for tk in _tips_notes:
		var tn = _tips_notes[tk]
		if tn != null and is_instance_valid(tn):
			tn.visible = _show_tips and tk == tips_mode
	_set_group_visible(_grp_actions2, _mode != MODE_PLAN and not setting and _mode != MODE_TEXT)
	if _sel_del_frame != null and is_instance_valid(_sel_del_frame):
		# Direct set: the group toggle drives the whole ROW, this frame
		# only follows the mode (reading back its own visibility latched
		# it to false after the first non-Select visit).
		_sel_del_frame.visible = _mode == MODE_SELECT
	# The Sketches manager and Display block live in the Settings tab.
	_set_group_visible(_grp_sketchmgr, setting)
	_set_group_visible(_grp_display, setting)
	# Eraser keeps Delete/Clear but loses the convert/snapshot/load block.
	_set_group_visible(_grp_act_shapes, _mode != MODE_PLAN and not setting and _mode != MODE_ERASE \
		and _mode != MODE_TEXT)
	_apply_arch_ui_state()


func _refresh_dropdown() -> void:
	if _dropdown == null or not is_instance_valid(_dropdown):
		return
	_sync_ui = true
	_dropdown.clear()
	var arr = _map_data["sketches"]
	for i in range(arr.size()):
		_dropdown.add_item(String(arr[i]["name"]), i)
	_dropdown.select(int(_map_data["active"]))
	_sync_ui = false


func _sync_display_controls() -> void:
	_sync_ui = true
	if _chk_visible != null and is_instance_valid(_chk_visible):
		_chk_visible.pressed = bool(_map_data["visible"])
	_update_float_btn_style()
	if _slider_layer != null and is_instance_valid(_slider_layer):
		_slider_layer.value = float(_map_data["layer_z"])
	if _slider_alpha != null and is_instance_valid(_slider_alpha):
		_slider_alpha.value = float(_map_data["overlay_alpha"])
	_sync_ui = false


# ── Panel callbacks ─────────────────────────────────────────────────────────

func _on_cat_pressed(target: int) -> void:
	if _sync_ui:
		return
	if target < 0:
		target = _last_draw_mode
	_change_mode(target)


func _on_draw_mode_pressed(m: int) -> void:
	if _sync_ui:
		return
	_last_draw_mode = m
	_change_mode(m)


func _update_mode_buttons() -> void:
	var is_draw = _mode != MODE_SELECT and _mode != MODE_MOVE \
		and _mode != MODE_ERASE and _mode != MODE_PLAN and _mode != MODE_SETTINGS \
		and _mode != MODE_TEXT
	if _draw_row != null and is_instance_valid(_draw_row):
		_draw_row.visible = is_draw
	if _draw_sep != null and is_instance_valid(_draw_sep):
		_draw_sep.visible = is_draw
	if _cat_btns.size() == 7:
		_cat_btns[0].pressed = is_draw
		_cat_btns[1].pressed = _mode == MODE_MOVE
		_cat_btns[2].pressed = _mode == MODE_SELECT
		_cat_btns[3].pressed = _mode == MODE_ERASE
		_cat_btns[4].pressed = _mode == MODE_TEXT
		_cat_btns[5].pressed = _mode == MODE_PLAN
		_cat_btns[6].pressed = _mode == MODE_SETTINGS
	if is_draw:
		var di = [MODE_FREE, MODE_LINE, MODE_RECT, MODE_ELLIPSE].find(_mode)
		if di >= 0 and di < _draw_btns.size():
			# A segment sub-tool active IS the mode: draw tools unpress.
			_draw_btns[di].pressed = _seg_type < 0


func _change_mode(i: int) -> void:
	if _txt_edit != null and is_instance_valid(_txt_edit) and _txt_edit.visible:
		_on_txt_confirmed()
	if _cv_area_pick:
		_cv_area_pick = false
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	if _shape_ghost != null:
		_shape_cancel()
	# Any mode/tool change deactivates the segment sub-tools.
	_seg_dragging = false
	_seg_batch = []
	_seg_lock = null
	_seg_type = -1
	_seg_sync_btns()
	call_deferred("_float_sync_side_buttons")
	if _seg_item != null and is_instance_valid(_seg_item):
		_seg_item.visible = false
	if _plan_drag != null and i != MODE_PLAN:
		_plan_drag = null
		_sel_show_overlay()
	if _sel != null and i != MODE_SELECT and i != MODE_MOVE:
		# Leaving the selection tools applies a floating selection and
		# drops a pending marquee, so no overlay lingers in drawing modes.
		if _sel_floating():
			_sel_commit()
		else:
			_sel_discard()
	_mode = i
	# The floatbar sub-row follows the mode, exactly like clicking the
	# matching floatbar button would: modes with sub-tools OPEN their
	# row, modes without any (Move / Settings / Text) close everything,
	# and the transient Snapshot / Convert option rows close like any
	# other family. A folded bar keeps hiding the rows regardless.
	var fam2 = ""
	if i == MODE_SELECT:
		fam2 = "sel"
	elif i == MODE_ERASE:
		fam2 = "era"
	elif i == MODE_PLAN:
		fam2 = "seg"
	elif i == MODE_FREE or i == MODE_LINE or i == MODE_RECT \
			or i == MODE_ELLIPSE or i == MODE_BRUSH:
		fam2 = "draw"
	_float_open_family(fam2)
	_save_settings()
	_update_cursor()
	_update_panel_visibility()
	_update_mode_buttons()


func _on_merge_shapes_toggled(v: bool) -> void:
	_merge_shapes = v


func _on_shape_style_pressed(i: int) -> void:
	if _sync_ui:
		return
	_shape_style = i
	_save_settings()
	_update_panel_visibility()


func _on_show_tips_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_show_tips = v
	_save_settings()
	_update_panel_visibility()


func _on_paint_kind(k: int) -> void:
	_paint_kind = k
	_kind_sync()
	_update_panel_visibility()
	_save_settings()


func _kind_sync() -> void:
	for i in range(_quick_btns.size()):
		if is_instance_valid(_quick_btns[i]):
			_quick_btns[i].pressed = i == _paint_kind
			# The active glyph turns blue (the theme's pressed bg alone
			# is too subtle).
			var g = _quick_btns[i].get_meta("glyph") if _quick_btns[i].has_meta("glyph") else null
			if g != null and is_instance_valid(g):
				g.modulate = UI_BLUE if i == _paint_kind else Color(1, 1, 1)


func _update_brush_dot() -> void:
	if _brush_qsb != null:
		_brush_qsb.bg_color = _color
	if _brush_qsb2 != null:
		_brush_qsb2.bg_color = _color
	if _brush_swatch != null and is_instance_valid(_brush_swatch):
		_brush_swatch.color = _color


# Effective paint parameters: the fixed kinds (wall/window/door) lock
# color, width and opacity in the Freehand and Line modes; everything
# else uses the free settings.
func _kind_active() -> bool:
	return _mode == MODE_FREE or _mode == MODE_LINE


func _paint_color() -> Color:
	if _kind_active():
		if _paint_kind == 1:
			return Color(0, 0, 0, 1)
		if _paint_kind == 2:
			return WINDOW_COLOR
		if _paint_kind == 3:
			return DOOR_COLOR
	return _color


func _paint_width() -> float:
	if _kind_active():
		if _paint_kind == 1:
			return 32.0
		if _paint_kind >= 2:
			return 16.0
	return _width


func _paint_intensity() -> float:
	if _kind_active() and _paint_kind != 0:
		return 1.0
	return _intensity


func _on_color_changed(c: Color) -> void:
	if _sync_ui:
		return
	_color = c
	_update_brush_dot()
	_save_settings()


func _on_fill_color_changed(c: Color) -> void:
	if _sync_ui:
		return
	_fill_color = c
	_save_settings()


# Fixed step table: every value is a real stop, so one step up then one
# step down always lands back on the origin (percent scaling never
# guaranteed that). Fine granularity where it matters, coarse above.
func _wsteps_ensure() -> void:
	if not _wsteps.empty():
		return
	for v in range(1, 17):
		_wsteps.append(float(v))
	for sp in [[18, 32, 2], [36, 64, 4], [72, 128, 8], [144, 256, 16],
			[288, 512, 32], [576, 1024, 64], [1152, 2048, 128], [2304, 4096, 256]]:
		var v2 = int(sp[0])
		while v2 <= int(sp[1]):
			_wsteps.append(float(v2))
			v2 += int(sp[2])


func _wstep_value(i: int) -> float:
	_wsteps_ensure()
	return _wsteps[int(clamp(i, 0, _wsteps.size() - 1))]


func _wstep_index(v: float) -> int:
	_wsteps_ensure()
	var best = 0
	var bd = INF
	for i in range(_wsteps.size()):
		var d = abs(_wsteps[i] - v)
		if d < bd:
			bd = d
			best = i
	return best


func _width_label_sync() -> void:
	if _width_lbl != null and is_instance_valid(_width_lbl):
		_width_lbl.text = str(int(round(_width))) + " px"


func _on_width_changed(v: float) -> void:
	if _sync_ui:
		return
	_width = _wstep_value(int(round(v)))
	_width_label_sync()
	_save_settings()
	_update_cursor()


func _on_intensity_changed(v: float) -> void:
	if _sync_ui:
		return
	_intensity = v
	_save_settings()


func _on_e_width_changed(v: float) -> void:
	if _sync_ui:
		return
	_eraser_width = v
	_save_settings()
	_update_cursor()


func _on_brush_shape_pressed(i: int) -> void:
	if _sync_ui:
		return
	_brush_square = i == 1
	_update_cursor()


func _on_brush_width_changed(v: float) -> void:
	if _sync_ui:
		return
	_brush_width = v
	_update_cursor()


# Small vertical breathing space above a button row.
func _vspace(h: int = 6) -> void:
	var sp = Control.new()
	sp.rect_min_size = Vector2(0, h)
	_sec.add_child(sp)


# Re-lays a CreateRadioMenu pair on a single row: the boxes move into
# one HBox, their emptied per-box rows are freed.
func _radio_row(boxes: Array) -> void:
	if boxes.size() < 2:
		return
	var row = HBoxContainer.new()
	var olds = []
	for b in boxes:
		if b == null or not is_instance_valid(b):
			continue
		var p = b.get_parent()
		if p != null:
			p.remove_child(b)
			if not p in olds:
				olds.append(p)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(b)
	_sec.add_child(row)
	for p2 in olds:
		if p2 != null and is_instance_valid(p2) and p2 != _sec \
				and p2.get_child_count() == 0:
			p2.queue_free()


func _on_rl_use_pressed() -> void:
	_rl_col = _text_color.to_html(false)
	_rl_s = _text_size / 60.0
	var sk = _active_sketch()
	if sk != null and sk.has("labels"):
		for lb in sk["labels"]:
			if not bool(lb.get("free", false)):
				lb["col"] = _rl_col
				lb["s"] = _rl_s
	_save_settings()
	_lbl_edited()


func _on_rl_reset_pressed() -> void:
	_rl_col = ""
	_rl_s = 0.0
	var sk = _active_sketch()
	if sk != null and sk.has("labels"):
		for lb in sk["labels"]:
			if not bool(lb.get("free", false)):
				lb.erase("col")
				lb["s"] = 1.0
	_save_settings()
	_lbl_edited()


func _on_text_rot_changed(v: float) -> void:
	if _sync_ui:
		return
	_text_rot = v
	var sk = _active_sketch()
	if sk != null and _txt_sel >= 0 and _txt_sel < sk.get("labels", []).size():
		sk["labels"][_txt_sel]["ang"] = deg2rad(v)
		_lbl_edited()


func _on_text_color_changed(c: Color) -> void:
	if _sync_ui:
		return
	_text_color = c
	var sk = _active_sketch()
	if sk != null and _txt_sel >= 0 and _txt_sel < sk.get("labels", []).size():
		sk["labels"][_txt_sel]["col"] = c.to_html(false)
		_lbl_edited()


func _on_text_size_changed(v: float) -> void:
	if _sync_ui:
		return
	_text_size = v
	var sk = _active_sketch()
	if sk != null and _txt_sel >= 0 and _txt_sel < sk.get("labels", []).size():
		var lb = sk["labels"][_txt_sel]
		if bool(lb.get("free", false)):
			lb["px"] = v
			lb["s"] = 1.0
		else:
			lb["s"] = v / 60.0
		_lbl_edited()


func _on_paint_shape_pressed(i: int) -> void:
	if _sync_ui:
		return
	_paint_square = i == 1
	_update_cursor()


func _on_eraser_shape_pressed(i: int) -> void:
	if _sync_ui:
		return
	_eraser_square = i == 0
	_save_settings()
	_update_cursor()


func _scaled_width(w: float, factor: float, max_v: float) -> float:
	# Mouse wheel steps snap to clean values: multiples of 256 above 256 px,
	# then 16 px and 4 px steps below, single px at small sizes.
	var nw = w * factor
	var step = 1.0
	var ref = max(w, nw)
	if ref > 256.0:
		step = 256.0
	elif ref > 64.0:
		step = 16.0
	elif ref > 16.0:
		step = 4.0
	nw = round(nw / step) * step
	if nw == w:
		if factor > 1.0:
			nw = w + step
		else:
			nw = w - step
	return clamp(nw, 1.0, max_v)


func _make_small_icon(tex, px: int):
	if tex == null:
		return null
	# EnlargeUI: every UI icon in the mod goes through here (panel
	# buttons, segment sub-tools, floatbar), so the scale applies once.
	px = int(round(float(px) * _ui_scale()))
	var img = tex.get_data()
	if img == null:
		return tex
	img = img.duplicate()
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	var out = ImageTexture.new()
	out.create_from_image(img)
	return out


# A tool icon recolored to plain white (alpha kept), sized for the
# colored circle buttons.
func _make_white_icon(name: String, px: int):
	var tex = _load_icon_any([name, "mode_" + name, name + "-icon"])
	if tex == null:
		return null
	var im = tex.get_data()
	if im == null:
		return null
	im = im.duplicate()
	im.convert(Image.FORMAT_RGBA8)
	im.lock()
	for y in range(im.get_height()):
		for x in range(im.get_width()):
			var c = im.get_pixel(x, y)
			im.set_pixel(x, y, Color(1, 1, 1, c.a))
	im.unlock()
	var out = ImageTexture.new()
	out.create_from_image(im, Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS)
	return _make_small_icon(out, px)


func _white_frame(ctrl) -> PanelContainer:
	var fr = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.draw_center = false
	sb.border_color = Color(0.55, 0.55, 0.55)
	sb.set_border_width_all(1)
	sb.corner_radius_top_left = 3
	sb.corner_radius_top_right = 3
	sb.corner_radius_bottom_left = 3
	sb.corner_radius_bottom_right = 3
	sb.anti_aliasing = true
	sb.content_margin_left = 1
	sb.content_margin_right = 1
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	fr.add_stylebox_override("panel", sb)
	fr.add_child(ctrl)
	return fr


func _icon_button(icon_name: String, tooltip: String, handler: String, fallback: String):
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.hint_tooltip = tooltip
	var tex = _make_small_icon(_load_icon(icon_name), 22)
	if tex != null:
		# Overlay TextureRect instead of Button.icon: the engine keeps
		# Button icons glued to the left edge when the button stretches,
		# the overlay stays centered whatever the width.
		var tr = TextureRect.new()
		tr.texture = tex
		tr.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
		tr.anchor_right = 1.0
		tr.anchor_bottom = 1.0
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(tr)
		btn.rect_min_size = Vector2(30, 30)
	else:
		btn.text = fallback
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.connect("pressed", self, handler)
	return btn


func _add_rand_toggle(slider, key: String) -> void:
	# Small per-setting dice toggle: randomize this one setting at each
	# generation.
	if slider == null or not is_instance_valid(slider):
		return
	var parent = slider.get_parent()
	if parent == null:
		return
	var btn = Button.new()
	btn.toggle_mode = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.hint_tooltip = "Randomize this setting at each generation"
	var tex = _make_small_icon(_load_icon("dice-icon"), 22)
	if tex != null:
		btn.icon = tex
	else:
		btn.text = "?"
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.connect("toggled", self, "_on_plan_rand_flag", [key])
	parent.add_child(btn)
	_plan_rand_btns[key] = btn


func _add_reset_button(slider, reset_value: float) -> void:
	# Small reset button appended to the slider's row, right of the SpinBox.
	if slider == null or not is_instance_valid(slider):
		return
	var parent = slider.get_parent()
	if parent == null:
		return
	var btn = Button.new()
	btn.focus_mode = Control.FOCUS_NONE
	btn.hint_tooltip = "Reset"
	# Prefer the mod's own icons/reset.png, then fall back to DD theme icons.
	var tex = _load_icon("reset")
	var theme = Global.get("Theme")
	if tex == null and theme != null:
		for n in ["Reset", "reset", "Refresh"]:
			if theme.has_icon(n, "Icons"):
				tex = theme.get_icon(n, "Icons")
				break
	if tex != null:
		btn.icon = _make_small_icon(tex, 22)
	else:
		btn.text = "R"
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.connect("pressed", self, "_on_reset_slider", [slider, reset_value])
	parent.add_child(btn)


func _on_reset_slider(slider, v: float) -> void:
	if slider != null and is_instance_valid(slider):
		slider.value = v


func _widen_slider_spinbox(slider, px: float) -> void:
	# DD sliders come with a companion SpinBox; widen it so 4-digit values
	# stay readable.
	if slider == null or not is_instance_valid(slider):
		return
	var parent = slider.get_parent()
	if parent == null:
		return
	for c in parent.get_children():
		if c is SpinBox or c is LineEdit:
			c.rect_min_size = Vector2(max(c.rect_min_size.x, px), c.rect_min_size.y)


func _adjust_width(factor: float) -> void:
	if _stroke != null:
		return
	if _mode == MODE_ERASE:
		_eraser_width = _scaled_width(_eraser_width, factor, 512.0)
		if _slider_e_width != null and is_instance_valid(_slider_e_width):
			_slider_e_width.value = _eraser_width
	elif _mode == MODE_BRUSH:
		_brush_width = clamp(_scaled_width(_brush_width, factor, 4096.0), 128.0, 4096.0)
		if _slider_brush_width != null and is_instance_valid(_slider_brush_width):
			_slider_brush_width.value = _brush_width
	else:
		# One table step per wheel notch: reversible by construction.
		_width = _wstep_value(_wstep_index(_width) + (1 if factor > 1.0 else -1))
		if _slider_width != null and is_instance_valid(_slider_width):
			_sync_ui = true
			_slider_width.value = _wstep_index(_width)
			_sync_ui = false
		_width_label_sync()
	_save_settings()
	_update_cursor()


func _on_clear_canvas() -> void:
	if _busy() or not _nodes_ok():
		return
	if _sel_floating():
		# The true pre state is the pre-lift snapshot; the float is dropped.
		_pre_image = _sel["pre"]
		_sel_discard()
	elif _sel != null:
		_sel_discard()
		_pre_image = _readback_a()
	else:
		_pre_image = _readback_a()
	var skc = _active_sketch()
	_clear_labels_before = null
	if skc.has("labels") and not skc["labels"].empty():
		_clear_labels_before = skc["labels"].duplicate(true)
		skc["labels"] = []
		_write_map_data()
		_update_labels_overlay()
	_ops.append({"type": "clear", "callback": "_after_clear"})


func _after_clear() -> void:
	var post = _readback_a()
	if post != null and _pre_image != null:
		var full = Rect2(Vector2(), _tex_size)
		var lp = null
		if _clear_labels_before != null:
			lp = [_clear_labels_before, []]
		_push_history(int(_active_sketch()["uid"]), full,
			_pre_image.get_rect(full), post.get_rect(full), null, lp)
	_clear_labels_before = null
	_pre_image = null
	_mark_dirty()


func _on_visible_toggled(v: bool) -> void:
	if _sync_ui or _startup_lock:
		return
	_map_data["visible"] = v
	_apply_display()
	_sync_display_controls()
	_write_map_data()


func _on_show_button_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_show_button = v
	_float_bar_opts_sync()
	_save_settings()
	_update_button_visibility()


func _on_layer_changed(v: float) -> void:
	if _sync_ui or _startup_lock:
		return
	_map_data["layer_z"] = int(v)
	if _root != null and is_instance_valid(_root):
		_root.z_index = int(clamp(int(v), -4000, 4000))
	_write_map_data()


func _on_alpha_changed(v: float) -> void:
	if _sync_ui or _startup_lock:
		return
	_map_data["overlay_alpha"] = v
	if _display_mat != null:
		_display_mat.set_shader_param("overlay_alpha", v)
	_write_map_data()


func _on_sketch_selected(idx: int) -> void:
	if _txt_edit != null and is_instance_valid(_txt_edit) and _txt_edit.visible:
		# Commit against the sketch the text belongs to, BEFORE the
		# switch.
		_on_txt_confirmed()
	if _sync_ui or _startup_lock:
		return
	_switch_active(idx)


func _on_new_sketch() -> void:
	# The sketch is only created once the name is confirmed in the dialog.
	if _rename_dialog == null or not is_instance_valid(_rename_dialog):
		return
	_rename_mode = "new"
	_rename_dialog.window_title = "New Sketch"
	_rename_edit.text = "Sketch " + str(int(_map_data["next_uid"]))
	_rename_dialog.popup_centered(Vector2(320, 110))
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _create_sketch(name: String) -> void:
	_cancel_stroke()
	_flush_or_bypass()
	var uid = int(_map_data["next_uid"])
	_map_data["next_uid"] = uid + 1
	if name == "":
		name = "Sketch " + str(uid)
	_map_data["sketches"].append({"uid": uid, "name": name, "png": "", "rect": [0, 0, 0, 0]})
	_map_data["active"] = _map_data["sketches"].size() - 1
	_last_free_pt = null
	_queue_clear()
	_refresh_dropdown()
	_write_map_data()


func _on_rename_sketch() -> void:
	if _rename_dialog == null or not is_instance_valid(_rename_dialog):
		return
	_rename_mode = "rename"
	_rename_dialog.window_title = "Rename Sketch"
	_rename_edit.text = String(_active_sketch()["name"])
	_rename_dialog.popup_centered(Vector2(320, 110))
	_rename_edit.grab_focus()
	_rename_edit.select_all()


func _on_rename_confirmed() -> void:
	var txt = _rename_edit.text.strip_edges()
	if _rename_mode == "new":
		_create_sketch(txt)
	elif txt != "":
		_active_sketch()["name"] = txt
		_refresh_dropdown()
		_write_map_data()
	_rename_dialog.hide()


func _on_delete_sketch() -> void:
	if _delete_dialog == null or not is_instance_valid(_delete_dialog):
		return
	_delete_dialog.dialog_text = "Delete sketch \"" + String(_active_sketch()["name"]) + "\"?\nThis cannot be undone."
	_delete_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	_cancel_stroke()
	_sel_discard()
	var idx = int(_map_data["active"])
	_map_data["sketches"].remove(idx)
	if _map_data["sketches"].size() == 0:
		var uid = int(_map_data["next_uid"])
		_map_data["next_uid"] = uid + 1
		_map_data["sketches"].append({"uid": uid, "name": "Sketch " + str(uid), "png": "", "rect": [0, 0, 0, 0]})
	_map_data["active"] = int(clamp(idx, 0, _map_data["sketches"].size() - 1))
	_save_countdown = -1.0
	_last_free_pt = null
	_queue_clear()
	_queue_load_active()
	_refresh_dropdown()
	_write_map_data()


func _switch_active(idx: int) -> void:
	idx = int(clamp(idx, 0, _map_data["sketches"].size() - 1))
	if idx == int(_map_data["active"]):
		return
	_cancel_stroke()
	_flush_or_bypass()
	_map_data["active"] = idx
	_last_free_pt = null
	_queue_clear()
	_queue_load_active()
	_refresh_dropdown()
	_write_map_data()


# ============================================================================
# Floating button & dialogs
# ============================================================================

func _build_float_button() -> void:
	_float_btn = Button.new()
	_float_btn.name = "SketchFloatButton"
	var sk_ic = _make_small_icon(_load_icon("sketch_tool"), 22)
	if sk_ic != null:
		_float_btn.icon = sk_ic
		_float_btn.set("icon_align", 1)
		_float_btn.hint_tooltip = "Open the Sketch tool"
	else:
		_float_btn.text = "Sketch"
	_float_btn.visible = false
	_float_btn.focus_mode = Control.FOCUS_NONE
	_update_float_btn_style()
	_float_btn.connect("gui_input", self, "_on_float_btn_gui")
	Global.Editor.add_child(_float_btn)
	_owned.append(_float_btn)
	# Drag handle (left) and close cross (right), glued to the button.
	_float_handle = Button.new()
	# Narrow grip: it only needs to be grabbable.
	_float_handle.rect_min_size = Vector2(18, 0)
	_float_handle.focus_mode = Control.FOCUS_NONE
	_float_handle.visible = false
	_float_handle.hint_tooltip = "Drag to move the Sketch button"
	_float_handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	_apply_button_style(_float_handle, false)
	_float_narrow(_float_handle)
	_float_update_handle_icon()
	_float_handle.connect("gui_input", self, "_on_float_handle_gui")
	Global.Editor.add_child(_float_handle)
	_owned.append(_float_handle)
	# Fold / unfold: collapses the bar down to handle + fold + Sketch.
	_float_fold_btn = Button.new()
	_float_fold_btn.rect_min_size = Vector2(18, 0)
	_float_fold_btn.focus_mode = Control.FOCUS_NONE
	_float_fold_btn.visible = false
	_apply_button_style(_float_fold_btn, false)
	_float_narrow(_float_fold_btn)
	_float_fold_btn.connect("pressed", self, "_on_float_fold_pressed")
	Global.Editor.add_child(_float_fold_btn)
	_owned.append(_float_fold_btn)
	_float_update_fold_icon()
	_float_sets = Button.new()
	_float_sets.focus_mode = Control.FOCUS_NONE
	_float_sets.visible = false
	var sic = _make_small_icon(_load_icon("settings"), 22)
	if sic != null:
		_float_sets.icon = sic
		_float_sets.set("icon_align", 1)
	else:
		_float_sets.text = "St"
	_float_sets.hint_tooltip = "Open the Settings tab"
	_apply_button_style(_float_sets, false)
	_float_sets.connect("pressed", self, "_on_float_sets_pressed")
	Global.Editor.add_child(_float_sets)
	_owned.append(_float_sets)
	_float_snap = Button.new()
	_float_snap.focus_mode = Control.FOCUS_NONE
	_float_snap.visible = false
	_apply_button_style(_float_snap, false)
	_float_snap.connect("pressed", self, "_on_float_snap_pressed")
	Global.Editor.add_child(_float_snap)
	_owned.append(_float_snap)
	_float_hook_corner(_float_snap)
	var snic = _make_small_icon(_load_icon("save"), 22)
	if snic != null:
		_float_snap.icon = snic
		_float_snap.set("icon_align", 1)
	else:
		_float_snap.text = "S"
	_float_snap.set_meta("ftip", "Snapshot (click: options)")
	_float_convert = Button.new()
	var cv_ic = _make_small_icon(_load_icon("convert"), 22)
	if cv_ic != null:
		_float_convert.icon = cv_ic
		_float_convert.set("icon_align", 1)
	else:
		_float_convert.text = "DD"
	_float_convert.focus_mode = Control.FOCUS_NONE
	_float_convert.visible = false
	_float_convert.hint_tooltip = "Convert to DD Walls"
	_apply_button_style(_float_convert, false)
	_float_convert.connect("pressed", self, "_on_float_convert_pressed")
	Global.Editor.add_child(_float_convert)
	_owned.append(_float_convert)
	_float_rand = Button.new()
	var rd_ic = _make_small_icon(_load_icon("dice-icon"), 22)
	if rd_ic != null:
		_float_rand.icon = rd_ic
		_float_rand.set("icon_align", 1)
	else:
		_float_rand.text = "?"
	_float_rand.focus_mode = Control.FOCUS_NONE
	_float_rand.visible = false
	_float_rand.hint_tooltip = "Randomize Settings (toggle)"
	_apply_button_style(_float_rand, false)
	_float_rand.connect("pressed", self, "_on_float_rand_pressed")
	Global.Editor.add_child(_float_rand)
	_owned.append(_float_rand)
	for fdef in [["gen", "generate", "Generate on whole map", "_on_float_gen_pressed"],
			["draw", "mode_draw", "Open the Sketch tool in Draw mode", "_on_float_draw_pressed"],
			["plan", "mode_plan", "Open the Sketch tool in the Plans tab", "_on_float_plan_pressed"],
			["clear2", "clear", "Clear the sketch", "_on_float_clear_pressed"]]:
		var fb = Button.new()
		var f_ic = _make_small_icon(_load_icon(fdef[1]), 22)
		if f_ic != null:
			fb.icon = f_ic
			fb.set("icon_align", 1)
		else:
			fb.text = fdef[0].capitalize()
		fb.focus_mode = Control.FOCUS_NONE
		fb.visible = false
		fb.hint_tooltip = fdef[2]
		_apply_button_style(fb, false)
		fb.connect("pressed", self, fdef[3])
		Global.Editor.add_child(fb)
		_owned.append(fb)
		if fdef[0] == "gen":
			_float_gen = fb
		elif fdef[0] == "draw":
			_float_draw = fb
		elif fdef[0] == "plan":
			_float_plan = fb
		else:
			_float_clear2 = fb
	_float_show = Button.new()
	var sh_ic = _make_small_icon(_load_icon("show"), 22)
	if sh_ic != null:
		_float_show.icon = sh_ic
		_float_show.set("icon_align", 1)
	else:
		_float_show.text = "S"
	_float_show.focus_mode = Control.FOCUS_NONE
	_float_show.visible = false
	_float_show.hint_tooltip = "Show / hide the sketch"
	_apply_button_style(_float_show, false)
	_float_show.connect("pressed", self, "_on_float_show_pressed")
	Global.Editor.add_child(_float_show)
	_owned.append(_float_show)
	_float_close = Button.new()
	_float_close.rect_min_size = Vector2(18, 0)
	var cl_ic = _make_icon_exact(_load_icon("close"), 12)
	# (the close glyph is symmetric: no rotation needed, only the box)
	_float_strip_icon(_float_close, cl_ic)
	if cl_ic == null:
		_float_close.text = "X"
	_float_close.focus_mode = Control.FOCUS_NONE
	_float_close.visible = false
	_float_close.hint_tooltip = "Hide the Sketch button (re-enable it in the tool panel)"
	_apply_button_style(_float_close, false)
	_float_narrow(_float_close)
	_float_close.connect("pressed", self, "_on_float_close_pressed")
	Global.Editor.add_child(_float_close)
	_owned.append(_float_close)
	_float_close.hint_tooltip = "Hide the Floatbar (re-enable it in the tool panel)"
	# Dedicated mode buttons: Move / Select / Erase next to Draw.
	for mdef in [["move", ["move", "mode_move"], "Move mode", "_on_float_move_pressed"],
			["sel", ["mode_select"], "Select mode", "_on_float_sel_pressed"],
			["era", ["mode_eraser"], "Erase mode", "_on_float_era2_pressed"],
			["text", ["text"], "Text mode", "_on_float_text_pressed"]]:
		var mb2 = Button.new()
		mb2.focus_mode = Control.FOCUS_NONE
		mb2.visible = false
		var mic2 = _make_small_icon(_load_icon_any(mdef[1]), 22)
		if mic2 != null:
			mb2.icon = mic2
			mb2.set("icon_align", 1)
		else:
			mb2.text = String(mdef[2]).split(" ")[0]
		mb2.set_meta("ftip", mdef[2])
		_apply_button_style(mb2, false)
		mb2.connect("pressed", self, mdef[3])
		Global.Editor.add_child(mb2)
		_owned.append(mb2)
		if mdef[0] == "move":
			_float_move = mb2
		elif mdef[0] == "sel":
			_float_sel = mb2
		elif mdef[0] == "text":
			_float_text = mb2
		else:
			_float_era = mb2
	_float_hook_corner(_float_draw)
	_float_hook_corner(_float_sel)
	_float_hook_corner(_float_era)
	_float_hook_corner(_float_plan)
	if _float_convert != null:
		_float_hook_corner(_float_convert)
	_float_build_subrow()
	_float_update_mode_icon()
	var cvic = _make_small_icon(_load_icon("convert"), 22)
	if cvic != null:
		_float_convert.icon = cvic
		_float_convert.set("icon_align", 1)
	_float_convert.set_meta("ftip", "Convert to DD Walls (click: options)")
	# Custom always-on-top tooltips: the native ones pop UNDER the
	# neighbouring buttons (same canvas layer, later siblings win).
	for tb in [_float_btn, _float_handle, _float_fold_btn, _float_gen, _float_draw,
			_float_move, _float_sel, _float_era, _float_text, _float_plan, _float_clear2,
			_float_rand, _float_snap, _float_convert, _float_sets, _float_show, _float_close]:
		_float_hook_tip(tb)
	for tb2 in _float_subrow + _float_segrow + _float_selrow + _float_erarow \
			+ _float_snaprow + _float_convrow + [_float_ind]:
		_float_hook_tip(tb2)


func _float_sync_side_buttons() -> void:
	if _float_btn == null or not is_instance_valid(_float_btn):
		return
	if _float_origin == null:
		_float_origin = _float_btn.rect_global_position
	var along = Vector2(0, 1) if _float_vertical else Vector2(1, 0)
	_float_narrow_axis()
	if _float_handle != null and is_instance_valid(_float_handle):
		var hc = Vector2(0, 0)
		if _float_vertical:
			hc = Vector2(max(0.0, (_float_btn.rect_size.x - _float_handle.rect_size.x) * 0.5), 0)
		else:
			hc = Vector2(0, max(0.0, (_float_btn.rect_size.y - _float_handle.rect_size.y) * 0.5))
		_float_handle.rect_global_position = _float_origin + hc
	var offx = 0.0
	if _float_handle != null and is_instance_valid(_float_handle):
		offx = _float_handle.rect_size.y if _float_vertical else _float_handle.rect_size.x
	# Handle - Move - Draw - Select - Erase - Plan - Generate - Clear -
	# Snapshot - Convert - Settings - Show - Open Sketch - Fold - Close.
	var bar_w = _float_btn.rect_size.x
	var bar_h = _float_btn.rect_size.y
	for fb2 in [_float_move, _float_draw, _float_sel, _float_era, _float_text, _float_plan, _float_gen, _float_clear2, _float_snap, _float_convert, _float_sets, _float_show, _float_btn, _float_fold_btn, _float_close]:
		if fb2 != null and is_instance_valid(fb2):
			if not fb2.visible:
				continue
			# Centered across the bar (the narrow grips are slimmer
			# than the square buttons).
			var center = Vector2(0, 0)
			if _float_vertical:
				center = Vector2(max(0.0, (bar_w - fb2.rect_size.x) * 0.5), 0)
			else:
				center = Vector2(0, max(0.0, (bar_h - fb2.rect_size.y) * 0.5))
			fb2.rect_global_position = _float_origin + along * offx + center
			offx += fb2.rect_size.y if _float_vertical else fb2.rect_size.x
	_float_sync_subrow()
	_float_update_show_tint()


func _on_float_handle_gui(event) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_RIGHT \
			and event.pressed:
		# Right-click: flip the bar between horizontal and vertical
		# (the Settings checkbox follows).
		_float_vertical = not _float_vertical
		if _chk_fvert != null and is_instance_valid(_chk_fvert):
			_sync_ui = true
			_chk_fvert.pressed = _float_vertical
			_sync_ui = false
		_float_update_handle_icon()
		_float_update_fold_icon()
		_float_redraw_corners()
		_float_sync_side_buttons()
		return
	# Pure drag: a plain click on the handle never toggles the sketch.
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT:
		if event.pressed:
			_btn_drag_active = true
			_btn_drag_moved = true
			_btn_press_pos = _float_handle.get_global_mouse_position()
			_btn_start_pos = _float_origin
		else:
			_btn_drag_active = false
			_save_button_frac()
	elif event is InputEventMouseMotion and _btn_drag_active:
		var gm = _float_handle.get_global_mouse_position()
		_float_origin = _btn_start_pos + gm - _btn_press_pos
		_float_sync_side_buttons()


# ---------------------------------------------------------------------------
# Floatbar extras: fold, custom tooltips, right-click alternative menus,
# draw sub-tool row.
# ---------------------------------------------------------------------------
# Modulate only (the style must not change), plus input blocked.
func _float_bar_opts_sync() -> void:
	for c in [_chk_fvert, _chk_finv]:
		if c == null or not is_instance_valid(c):
			continue
		c.modulate = Color(1, 1, 1, 1) if _show_button else Color(1, 1, 1, 0.45)
		c.mouse_filter = Control.MOUSE_FILTER_STOP if _show_button else Control.MOUSE_FILTER_IGNORE


func _on_float_vertical_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_float_vertical = v
	_float_update_handle_icon()
	_float_update_fold_icon()
	_float_redraw_corners()
	_float_sync_side_buttons()


func _on_float_invert_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_float_invert = v
	_float_redraw_corners()
	_float_sync_side_buttons()


func _float_redraw_corners() -> void:
	for b in _float_corner_btns:
		if b != null and is_instance_valid(b):
			b.update()


# 90 degrees clockwise, for the handle / fold icons in vertical mode.
func _make_icon_exact(tex, px: int):
	if tex == null:
		return null
	var img = tex.get_data()
	if img == null:
		return tex
	img = img.duplicate()
	img.resize(px, px, Image.INTERPOLATE_LANCZOS)
	var out = ImageTexture.new()
	out.create_from_image(img)
	out.flags = Texture.FLAG_FILTER | Texture.FLAG_MIPMAPS
	return out


func _rot90_icon(tex):
	if tex == null:
		return null
	var img = tex.get_data()
	if img == null:
		return tex
	img.lock()
	var w = img.get_width()
	var h = img.get_height()
	var out = Image.new()
	out.create(h, w, false, img.get_format())
	out.lock()
	for y in range(h):
		for x in range(w):
			out.set_pixel(h - 1 - y, x, img.get_pixel(x, y))
	out.unlock()
	img.unlock()
	var t2 = ImageTexture.new()
	t2.create_from_image(out)
	return t2


# The three narrow buttons swap their axis with the bar: 18 px wide in
# horizontal mode, 18 px tall (full bar width) in vertical mode.
# The strip glyph lives in a centered TextureRect child: Button.icon
# reserves its own content box (font metrics included) and kept both
# inflating the button and gluing the glyph left.
func _float_strip_icon(btn, tex) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	btn.icon = null
	var cc = btn.get_node_or_null("strip_ic")
	if tex == null:
		if cc != null:
			cc.queue_free()
		return
	btn.text = ""
	if cc == null:
		cc = CenterContainer.new()
		cc.name = "strip_ic"
		cc.anchor_right = 1.0
		cc.anchor_bottom = 1.0
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tr = TextureRect.new()
		tr.name = "tr"
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cc.add_child(tr)
		btn.add_child(cc)
	cc.get_node("tr").texture = tex


func _float_narrow_axis() -> void:
	var barw = 40.0
	if _float_btn != null and is_instance_valid(_float_btn) and _float_btn.rect_size.x > 0.0:
		barw = _float_btn.rect_size.x
	var barh = 0.0
	if _float_btn != null and is_instance_valid(_float_btn):
		barh = _float_btn.rect_size.y
	for nb in [_float_handle, _float_fold_btn, _float_close]:
		if nb == null or not is_instance_valid(nb):
			continue
		nb.expand_icon = false
		nb.set("icon_align", 1)
		if _float_vertical:
			# The horizontal strip turned 90°: full bar width, 14 px
			# thick, glyph centered.
			nb.rect_min_size = Vector2(barw, 14)
			nb.rect_size = Vector2(barw, 14)
		else:
			# Thin vertical strip: 18 px wide, full bar height.
			nb.rect_min_size = Vector2(18, barh)
			nb.rect_size = Vector2(18, barh)


func _float_update_handle_icon() -> void:
	if _float_handle == null or not is_instance_valid(_float_handle):
		return
	var hd_ic = _make_icon_exact(_load_icon("handle"), 12)
	if hd_ic != null and _float_vertical:
		hd_ic = _rot90_icon(hd_ic)
	_float_strip_icon(_float_handle, hd_ic)
	if hd_ic == null:
		_float_handle.text = "::"


func _on_float_fold_pressed() -> void:
	_float_hide_subrow()
	_float_close_menu()
	_float_folded = not _float_folded
	_float_update_fold_icon()
	_update_button_visibility()
	_save_settings()


func _float_update_fold_icon() -> void:
	if _float_fold_btn == null or not is_instance_valid(_float_fold_btn):
		return
	var ic = _make_icon_exact(_load_icon("unfold" if _float_folded else "fold"), 12)
	if ic != null and _float_vertical:
		ic = _rot90_icon(ic)
	_float_strip_icon(_float_fold_btn, ic)
	if ic == null:
		_float_fold_btn.text = ">" if _float_folded else "<"
	_float_fold_btn.set_meta("ftip", "Unfold the Floatbar" if _float_folded else "Fold the Floatbar")


# Custom tooltip: a top-most panel positioned ABOVE the bar. Native
# tooltips render in the same canvas layer and later siblings (the
# neighbouring buttons) draw over them.
func _float_hook_tip(btn) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	if btn.hint_tooltip != "":
		btn.set_meta("ftip", btn.hint_tooltip)
		btn.hint_tooltip = ""
	if not btn.is_connected("mouse_entered", self, "_on_float_tip_enter"):
		btn.connect("mouse_entered", self, "_on_float_tip_enter", [btn])
	if not btn.is_connected("mouse_exited", self, "_on_float_tip_exit"):
		btn.connect("mouse_exited", self, "_on_float_tip_exit")


# Tiny triangle pointing at the bottom-right corner: the visual cue
# that a right-click menu exists on this button.
# Squeezes a bar button: the shared style carries 12 px side margins,
# which floor the width at ~40 px whatever rect_min_size says.
func _float_narrow(btn) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	for k in ["normal", "hover", "pressed"]:
		var sb = btn.get_stylebox(k)
		if sb != null and sb is StyleBoxFlat:
			sb.content_margin_left = 2
			sb.content_margin_right = 2
			sb.content_margin_top = 2
			sb.content_margin_bottom = 2


func _float_hook_corner(btn) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	if not btn.is_connected("draw", self, "_on_float_corner_draw"):
		btn.connect("draw", self, "_on_float_corner_draw", [btn])
		_float_corner_btns.append(btn)
	btn.update()


func _on_float_corner_draw(btn) -> void:
	if btn == null or not is_instance_valid(btn):
		return
	var sz = btn.rect_size
	# The triangle points at the side where the row / menu opens:
	# bottom-right normally, top-right in horizontal+invert,
	# bottom-left in vertical+invert.
	var right = not (_float_vertical and _float_invert)
	var bottom = not (not _float_vertical and _float_invert)
	var cx = sz.x - 3.0 if right else 3.0
	var cy = sz.y - 3.0 if bottom else 3.0
	var dx = -7.0 if right else 7.0
	var dy = -7.0 if bottom else 7.0
	var pts = PoolVector2Array([
		Vector2(cx + dx, cy),
		Vector2(cx, cy + dy),
		Vector2(cx, cy)])
	btn.draw_colored_polygon(pts, Color(1, 1, 1, 0.6))


func _float_tip_ensure() -> void:
	if _float_tip != null and is_instance_valid(_float_tip):
		return
	_float_tip = PanelContainer.new()
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.10, 0.12, 0.97)
	sb.border_color = Color(1, 1, 1, 0.35)
	sb.set_border_width_all(1)
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	_float_tip.add_stylebox_override("panel", sb)
	_float_tip_lbl = Label.new()
	_float_tip_lbl.add_color_override("font_color", Color(1, 1, 1, 1))
	_float_tip.add_child(_float_tip_lbl)
	_float_tip.visible = false
	_float_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	Global.Editor.add_child(_float_tip)
	_owned.append(_float_tip)


# Hovering only ARMS the tip; it shows after 2 s without motion (the
# countdown lives in tick).
func _on_float_tip_enter(btn) -> void:
	if btn == null or not is_instance_valid(btn) or not btn.visible:
		return
	if not btn.has_meta("ftip"):
		return
	_float_tip_btn = btn
	_float_tip_wait = 0.0
	if btn.get_viewport() != null:
		_float_tip_mouse = btn.get_global_mouse_position()


func _float_tip_show(btn) -> void:
	if btn == null or not is_instance_valid(btn) or not btn.visible:
		return
	_float_tip_ensure()
	_float_tip_lbl.text = String(btn.get_meta("ftip"))
	var ms = _float_tip.get_combined_minimum_size()
	_float_tip.rect_size = ms
	_float_tip.visible = true
	_float_tip.raise()
	# Bottom-right of the cursor, flipped up when the screen edge bites.
	var pos = btn.get_global_mouse_position() + Vector2(14.0, 18.0)
	var vp = _float_tip.get_viewport_rect().size
	if pos.x + ms.x > vp.x - 4.0:
		pos.x = vp.x - ms.x - 4.0
	if pos.y + ms.y > vp.y - 4.0:
		pos.y = btn.get_global_mouse_position().y - ms.y - 8.0
	_float_tip.rect_global_position = pos


func _on_float_tip_exit() -> void:
	_float_tip_btn = null
	_float_tip_hide()


# Short-lived on-screen notice (bottom center), reusing the tooltip
# look. Lives on its own panel so tooltip housekeeping never kills it.
func _float_toast(msg: String) -> void:
	if _float_toast_panel == null or not is_instance_valid(_float_toast_panel):
		_float_toast_panel = PanelContainer.new()
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color(0.10, 0.10, 0.12, 0.97)
		sb.border_color = Color(1, 1, 1, 0.35)
		sb.set_border_width_all(1)
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 6
		sb.content_margin_bottom = 6
		_float_toast_panel.add_stylebox_override("panel", sb)
		_float_toast_lbl = Label.new()
		_float_toast_lbl.add_color_override("font_color", Color(1, 1, 1, 1))
		_float_toast_panel.add_child(_float_toast_lbl)
		_float_toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		Global.Editor.add_child(_float_toast_panel)
		_owned.append(_float_toast_panel)
	_float_toast_lbl.text = msg
	var ms = _float_toast_panel.get_combined_minimum_size()
	_float_toast_panel.rect_size = ms
	var vp = _float_toast_panel.get_viewport_rect().size
	_float_toast_panel.rect_global_position = Vector2((vp.x - ms.x) * 0.5, (vp.y - ms.y) * 0.5)
	_float_toast_panel.visible = true
	_float_toast_panel.raise()
	_float_toast_t = 2.5


func _float_tip_hide() -> void:
	if _float_tip != null and is_instance_valid(_float_tip):
		_float_tip.visible = false


# Vertical alternative menu under a bar button (right-click).
func _float_open_menu(anchor, entries: Array, cb: String, selected = null) -> void:
	# Re-clicking the SAME anchor while its menu is open closes it.
	if _float_menu != null and is_instance_valid(_float_menu) \
			and _float_menu.has_meta("anchor") and _float_menu.get_meta("anchor") == anchor:
		_float_close_menu()
		return
	_float_close_menu()
	_float_tip_hide()
	var box = VBoxContainer.new()
	box.set("custom_constants/separation", 2)
	for e in entries:
		var b = Button.new()
		var ic = _make_small_icon(_load_icon_any(e[0]), 22)
		if ic != null:
			b.icon = ic
			b.set("icon_align", 0)
		b.text = " " + String(e[1])
		b.align = Button.ALIGN_LEFT
		b.focus_mode = Control.FOCUS_NONE
		# Blue background on the entry currently in effect; icon and
		# text stay white.
		_apply_button_style(b, selected != null and typeof(e[2]) == typeof(selected) and e[2] == selected)
		b.connect("pressed", self, cb, [e[2]])
		box.add_child(b)
	# The menu opens on the same side as the sub-rows: below the bar
	# (or above with Invert) when horizontal, to the right (or left)
	# when vertical.
	var ms = box.get_combined_minimum_size()
	var mpos = anchor.rect_global_position
	if _float_vertical:
		if _float_invert:
			mpos += Vector2(-ms.x - 4.0, 0)
		else:
			mpos += Vector2(anchor.rect_size.x + 4.0, 0)
	else:
		if _float_invert:
			mpos += Vector2(0, -ms.y - 4.0)
		else:
			mpos += Vector2(0, anchor.rect_size.y + 4.0)
	box.rect_global_position = mpos
	box.set_meta("armed", false)
	box.set_meta("anchor", anchor)
	Global.Editor.add_child(box)
	box.raise()
	_float_menu = box


func _float_close_menu() -> void:
	if _float_menu != null and is_instance_valid(_float_menu):
		_float_menu.queue_free()
	_float_menu = null


# Draw sub-tool row shown under the bar while the draw slot is active.
func _float_build_subrow() -> void:
	_float_subrow = []
	for sdef in [["mode_freehand", "Freehand", MODE_FREE],
			["mode_line", "Line", MODE_LINE],
			["mode_rect", "Rectangle", MODE_RECT],
			["mode_ellipse", "Ellipse", MODE_ELLIPSE]]:
		var b = Button.new()
		var ic = _make_small_icon(_load_icon(sdef[0]), 22)
		if ic != null:
			b.icon = ic
			b.set("icon_align", 1)
		else:
			b.text = String(sdef[1])
		b.focus_mode = Control.FOCUS_NONE
		b.visible = false
		b.set_meta("sub_mode", sdef[2])
		b.set_meta("ftip", String(sdef[1]) \
			+ (" (right-click: shape style)" if int(sdef[2]) == MODE_RECT or int(sdef[2]) == MODE_ELLIPSE else ""))
		_apply_button_style(b, false)
		b.connect("gui_input", self, "_on_float_sub_gui", [b])
		if int(sdef[2]) != MODE_BRUSH:
			# These four carry the kind / style indicator below.
			_float_hook_corner(b)
		Global.Editor.add_child(b)
		_owned.append(b)
		_float_subrow.append(b)
	# Kind / style indicator: shows the CURRENT brush kind (Freehand /
	# Line) or shape style (Rect / Ellipse); clicking it opens the
	# matching picker.
	_float_ind = Button.new()
	_float_ind.focus_mode = Control.FOCUS_NONE
	_float_ind.visible = false
	_apply_button_style(_float_ind, false)
	_float_ind.connect("pressed", self, "_on_float_ind_pressed")
	_float_hook_corner(_float_ind)
	Global.Editor.add_child(_float_ind)
	_owned.append(_float_ind)
	# Snapshot options row.
	_float_snaprow = []
	for ndef in [["save", "Whole Sketch", 0], ["save_select", "Select Area", 1]]:
		var nb = Button.new()
		var nic = _make_small_icon(_load_icon_any([ndef[0], "save"]), 22)
		if nic != null:
			nb.icon = nic
			nb.set("icon_align", 1)
		else:
			nb.text = String(ndef[1])
		nb.focus_mode = Control.FOCUS_NONE
		nb.visible = false
		nb.set_meta("ftip", "Snapshot: " + String(ndef[1]))
		_apply_button_style(nb, false)
		nb.connect("pressed", self, "_on_float_snaprow_pressed", [int(ndef[2])])
		Global.Editor.add_child(nb)
		_owned.append(nb)
		_float_snaprow.append(nb)
	# Convert options row.
	_float_convrow = []
	for cdef in [["convert", "Convert", 0], ["convert_previous", "Convert with previous settings", 1]]:
		var cb2 = Button.new()
		var cic = _make_small_icon(_load_icon_any([cdef[0], "convert"]), 22)
		if cic != null:
			cb2.icon = cic
			cb2.set("icon_align", 1)
		else:
			cb2.text = String(cdef[1])
		cb2.focus_mode = Control.FOCUS_NONE
		cb2.visible = false
		cb2.set_meta("ftip", cdef[1])
		_apply_button_style(cb2, false)
		cb2.connect("pressed", self, "_on_float_convrow_pressed", [int(cdef[2])])
		Global.Editor.add_child(cb2)
		_owned.append(cb2)
		_float_convrow.append(cb2)
	# Plan segment sub-tools (under the Plan button). Draw Area is the
	# "no segment" state: the plan drag draws a generation area.
	_float_segrow = []
	for gdef in [["draw_area", "Draw Area (generate in a dragged rectangle)", -2],
			["wall", "Wall segments", 0],
			["window", "Window segments", 1],
			["door", "Door segments", 2],
			["tower", "Tower (3/4 circle)", 4],
			["erase", "Erase segments", 3]]:
		var g = Button.new()
		var gic = _make_small_icon(_load_icon(gdef[0]), 22)
		if gic != null:
			g.icon = gic
			g.set("icon_align", 1)
		else:
			g.text = String(gdef[1]).split(" ")[0]
		g.focus_mode = Control.FOCUS_NONE
		g.visible = false
		g.set_meta("seg_id", gdef[2])
		g.set_meta("ftip", gdef[1])
		_apply_button_style(g, false)
		g.connect("pressed", self, "_on_float_seg_pressed", [int(gdef[2])])
		Global.Editor.add_child(g)
		_owned.append(g)
		_float_segrow.append(g)
	# Eraser shape sub-tools (under the mode slot in Eraser).
	_float_erarow = []
	for edef in [["square", "Square eraser", 0], ["round", "Round eraser", 1]]:
		var eb = Button.new()
		var eic = _make_small_icon(_load_icon(edef[0]), 22)
		if eic != null:
			eb.icon = eic
			eb.set("icon_align", 1)
		else:
			eb.text = String(edef[1]).split(" ")[0]
		eb.focus_mode = Control.FOCUS_NONE
		eb.visible = false
		eb.set_meta("era_id", edef[2])
		eb.set_meta("ftip", edef[1])
		_apply_button_style(eb, false)
		eb.connect("pressed", self, "_on_float_era_pressed", [int(edef[2])])
		Global.Editor.add_child(eb)
		_owned.append(eb)
		_float_erarow.append(eb)
	# Reroll + Randomize join the plan segment row.
	var rr = Button.new()
	var rric = _make_small_icon(_load_icon("reroll"), 22)
	if rric == null:
		rric = _make_small_icon(_load_icon("generate"), 22)
	if rric != null:
		rr.icon = rric
		rr.set("icon_align", 1)
	else:
		rr.text = "Reroll"
	rr.focus_mode = Control.FOCUS_NONE
	rr.visible = false
	rr.set_meta("seg_id", -1)
	rr.set_meta("ftip", "Reroll the last generation")
	_apply_button_style(rr, false)
	rr.connect("pressed", self, "_on_plan_reroll")
	Global.Editor.add_child(rr)
	_owned.append(rr)
	_float_segrow.append(rr)
	# Display order: Draw Area, Reroll, (Randomize slots in during the
	# sync), then the segments.
	_float_segrow = [_float_segrow[0], _float_segrow[6], _float_segrow[1],
		_float_segrow[2], _float_segrow[3], _float_segrow[4], _float_segrow[5]]
	# Select transform sub-tools (under the mode slot in Select).
	_float_selrow = []
	for xdef in [["rotate90ccw", "Rotate 90° counter-clockwise (selection, or whole sketch)", "ccw", "CCW"],
			["rotate90", "Rotate 90° clockwise (selection, or whole sketch)", "cw", "R90"],
			["h_sym", "Horizontal symmetry (selection, or whole sketch)", "h", "H"],
			["v_sym", "Vertical symmetry (selection, or whole sketch)", "v", "V"]]:
		var x = Button.new()
		var xic = _make_small_icon(_load_icon(xdef[0]), 22)
		if xic != null:
			x.icon = xic
			x.set("icon_align", 1)
		else:
			x.text = String(xdef[3])
		x.focus_mode = Control.FOCUS_NONE
		x.visible = false
		x.set_meta("ftip", xdef[1])
		_apply_button_style(x, false)
		x.connect("pressed", self, "_on_float_tf_pressed", [String(xdef[2])])
		Global.Editor.add_child(x)
		_owned.append(x)
		_float_selrow.append(x)


func _float_sync_subrow() -> void:
	if _float_draw == null or not is_instance_valid(_float_draw):
		return
	# Draw tools under the slot (draw), transforms under it (select).
	var offx = 0.0
	var active_sub_x = 0.0
	for b in _float_subrow:
		if b == null or not is_instance_valid(b):
			continue
		b.visible = _float_subrow_open and _float_draw.visible
		b.rect_global_position = _float_row_pos(_float_draw, offx)
		var b_on = _tool_active and int(b.get_meta("sub_mode")) == _mode
		if b_on:
			active_sub_x = offx
		offx += _float_row_run(b)
		_apply_button_style(b, b_on)
	_float_ind_sync()
	if _float_ind != null and is_instance_valid(_float_ind) and _float_ind.visible:
		# Right below (or beside) the ACTIVE sub-tool, one layer out.
		_float_ind.rect_global_position = _float_row_pos(_float_draw, active_sub_x, 2)
	if _float_snap != null and is_instance_valid(_float_snap):
		var offn = 0.0
		for nb in _float_snaprow:
			if nb == null or not is_instance_valid(nb):
				continue
			nb.visible = _float_snap_open and _float_snap.visible
			nb.rect_global_position = _float_row_pos(_float_snap, offn)
			offn += _float_row_run(nb)
	if _float_convert != null and is_instance_valid(_float_convert):
		var offc = 0.0
		for cb2 in _float_convrow:
			if cb2 == null or not is_instance_valid(cb2):
				continue
			cb2.visible = _float_conv_open and _float_convert.visible
			cb2.rect_global_position = _float_row_pos(_float_convert, offc)
			offc += _float_row_run(cb2)
	if _float_sel != null and is_instance_valid(_float_sel):
		var offx2 = 0.0
		for x in _float_selrow:
			if x == null or not is_instance_valid(x):
				continue
			x.visible = _float_sel_open and _float_sel.visible
			x.rect_global_position = _float_row_pos(_float_sel, offx2)
			offx2 += _float_row_run(x)
	if _float_era != null and is_instance_valid(_float_era):
		var offx4 = 0.0
		for eb in _float_erarow:
			if eb == null or not is_instance_valid(eb):
				continue
			eb.visible = _float_era_open and _float_era.visible
			eb.rect_global_position = _float_row_pos(_float_era, offx4)
			offx4 += _float_row_run(eb)
			_apply_button_style(eb, (_eraser_square and int(eb.get_meta("era_id")) == 0) \
				or (not _eraser_square and int(eb.get_meta("era_id")) == 1))
	# Plan segments under the Plan button.
	if _float_plan != null and is_instance_valid(_float_plan):
		var offx3 = 0.0
		for g in _float_segrow:
			if g == null or not is_instance_valid(g):
				continue
			g.visible = _float_segrow_open() and _float_plan.visible
			g.rect_global_position = _float_row_pos(_float_plan, offx3)
			offx3 += _float_row_run(g)
			var gid = int(g.get_meta("seg_id"))
			if gid >= 0:
				_apply_button_style(g, _tool_active and _mode == MODE_PLAN \
					and _seg_type == gid)
			elif gid == -2:
				_apply_button_style(g, _tool_active and _mode == MODE_PLAN \
					and _seg_type < 0)
			if gid == -1 and _float_rand != null and is_instance_valid(_float_rand):
				# Randomize right after Reroll.
				_float_rand.visible = _float_segrow_open() and _float_plan.visible
				_float_rand.rect_global_position = _float_row_pos(_float_plan, offx3)
				offx3 += _float_row_run(_float_rand)


func _float_hide_subrow() -> void:
	_float_subrow_open = false
	_float_seg_open = false
	_float_snap_open = false
	_float_conv_open = false
	_float_sel_open = false
	_float_era_open = false
	for b in _float_subrow + _float_selrow + _float_segrow + _float_erarow \
			+ _float_snaprow + _float_convrow + [_float_ind]:
		if b != null and is_instance_valid(b):
			b.visible = false
	if _float_rand != null and is_instance_valid(_float_rand):
		_float_rand.visible = false


func _on_float_era_pressed(i: int) -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	if _mode != MODE_ERASE:
		_change_mode(MODE_ERASE)
	_eraser_square = i == 0
	# The panel radio follows, without echoing back.
	_sync_ui = true
	for bi in range(_eraser_shape_boxes.size()):
		if is_instance_valid(_eraser_shape_boxes[bi]):
			_eraser_shape_boxes[bi].pressed = bi == i
	_sync_ui = false
	_save_settings()
	_update_cursor()
	_float_sync_subrow()


# Position along a sub-row: `run` walks the BAR axis from the parent
# button, `layer` counts how many rows away from the bar the child
# sits, on the across side (flipped by Invert).
func _float_row_pos(parent, run: float, layer: int = 1) -> Vector2:
	var along = Vector2(0, 1) if _float_vertical else Vector2(1, 0)
	var across = Vector2(1, 0) if _float_vertical else Vector2(0, 1)
	if _float_invert:
		across = -across
	var step = (parent.rect_size.x if _float_vertical else parent.rect_size.y) + 4.0
	return parent.rect_global_position + along * run + across * (step * float(layer))


func _float_row_run(b) -> float:
	return b.rect_size.y if _float_vertical else b.rect_size.x


func _float_segrow_open() -> bool:
	return _float_seg_open


func _on_float_seg_pressed(i: int) -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	if _mode != MODE_PLAN:
		_change_mode(MODE_PLAN)
	if i == -2:
		# Draw Area: plain plan drag, every segment sub-tool off.
		if _seg_type >= 0:
			_on_seg_type(_seg_type)
	else:
		_on_seg_type(i)
	_float_sync_subrow()


func _on_float_tf_pressed(op: String) -> void:
	_transform_selection_or_all(op)


func _on_tf_ccw() -> void:
	_transform_selection_or_all("ccw")


func _on_tf_cw() -> void:
	_transform_selection_or_all("cw")


func _on_tf_h() -> void:
	_transform_selection_or_all("h")


func _on_tf_v() -> void:
	_transform_selection_or_all("v")


func _on_float_sub_gui(event, b) -> void:
	if not (event is InputEventMouseButton and event.pressed):
		return
	var m = int(b.get_meta("sub_mode"))
	if event.button_index == BUTTON_LEFT:
		if not _tool_active:
			Global.Editor.Toolset.Quickswitch(TOOL_ID)
		_float_draw_sub = m
		_change_mode(m)
		_float_sync_subrow()


# The indicator button: current kind (Freehand / Line) or shape style
# (Rect / Ellipse); clicking it opens the matching picker.
func _on_float_ind_pressed() -> void:
	if _mode == MODE_RECT or _mode == MODE_ELLIPSE:
		_float_open_menu(_float_ind, [
			[["style_outline"], "Outline", 0],
			[["style_fill"], "Fill", 1],
			[["style_both"], "Both", 2]], "_on_float_style_picked", int(_shape_style))
	else:
		_float_open_menu(_float_ind, [
			[["brush"], "Brush", 0],
			[["wall"], "Wall", 1],
			[["window"], "Window", 2],
			[["door"], "Door", 3]], "_on_float_kind_picked", int(_paint_kind))


func _float_ind_sync() -> void:
	if _float_ind == null or not is_instance_valid(_float_ind):
		return
	var shapes = _mode == MODE_RECT or _mode == MODE_ELLIPSE
	var kinds = _mode == MODE_FREE or _mode == MODE_LINE
	_float_ind.visible = _float_subrow_open \
			and _float_draw != null and is_instance_valid(_float_draw) \
			and _float_draw.visible and (shapes or kinds)
	if not _float_ind.visible:
		return
	var name = ""
	var tip = ""
	if shapes:
		name = ["style_outline", "style_fill", "style_both"][int(clamp(_shape_style, 0, 2))]
		tip = "Shape style: " + ["Outline", "Fill", "Both"][int(clamp(_shape_style, 0, 2))] + " (click to change)"
	else:
		name = ["brush", "wall", "window", "door"][int(clamp(_paint_kind, 0, 3))]
		tip = "Brush kind: " + ["Brush", "Wall", "Window", "Door"][int(clamp(_paint_kind, 0, 3))] + " (click to change)"
	var ic = _make_small_icon(_load_icon(name), 22)
	if ic != null:
		_float_ind.icon = ic
		_float_ind.set("icon_align", 1)
		_float_ind.text = ""
	else:
		_float_ind.text = "?"
	_float_ind.set_meta("ftip", tip)
	# Blue background: this button DISPLAYS the current selection.
	_apply_button_style(_float_ind, true)


func _on_float_kind_picked(k: int) -> void:
	_float_close_menu()
	_on_paint_kind(int(k))
	_kind_sync()
	_float_sync_subrow()


func _on_float_style_picked(i: int) -> void:
	_float_close_menu()
	_float_set_style(int(i))
	_float_sync_subrow()


# Routes through the PANEL style toggles when they exist, so the two
# UIs never disagree; direct setter as fallback.
func _float_set_style(i: int) -> void:
	# Programmatic .pressed emits "toggled" but NOT "pressed", and the
	# panel buttons are wired on "pressed": the visual flipped while
	# _shape_style never changed. The state setter is called directly,
	# the panel toggle is only synced visually (guarded).
	var labels = ["Outline", "Fill", "Both"]
	for grp in _grp_shape_style:
		if grp == null or not is_instance_valid(grp):
			continue
		var stack = [grp]
		while not stack.empty():
			var n = stack.pop_back()
			for c in n.get_children():
				stack.append(c)
			if n is Button and n.toggle_mode and String(n.hint_tooltip) == labels[i]:
				_sync_ui = true
				n.pressed = true
				_sync_ui = false
	_on_shape_style_pressed(i)


func _float_update_mode_icon() -> void:
	if _float_draw == null or not is_instance_valid(_float_draw):
		return
	var ic = _make_small_icon(_load_icon("mode_draw"), 22)
	if ic != null:
		_float_draw.icon = ic
		_float_draw.set("icon_align", 1)
		_float_draw.text = ""
	_float_draw.set_meta("ftip", "Draw mode")


func _on_float_sets_pressed() -> void:
	_float_collapse_rows()
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_change_mode(MODE_SETTINGS)


# Blue background on the bar buttons whose feature is LIVE: the tool
# itself, the Plan and Settings tabs, a pending Snapshot area pick, an
# open Convert wizard. Styles are only rebuilt on actual change.
func _float_refresh_states() -> void:
	var draws5 = _mode == MODE_FREE or _mode == MODE_LINE or _mode == MODE_BRUSH \
			or _mode == MODE_RECT or _mode == MODE_ELLIPSE
	var states = [
		[_float_btn, _tool_active],
		[_float_draw, _tool_active and draws5],
		[_float_move, _tool_active and _mode == MODE_MOVE],
		[_float_sel, _tool_active and _mode == MODE_SELECT],
		[_float_era, _tool_active and _mode == MODE_ERASE],
		[_float_text, _tool_active and _mode == MODE_TEXT],
		[_float_plan, _tool_active and _mode == MODE_PLAN],
		[_float_sets, _tool_active and _mode == MODE_SETTINGS],
		[_float_snap, _float_snap_open or _shape_area_pick],
		[_float_convert, _float_conv_open or _cv_area_pick or (_cvw_dlg != null \
			and is_instance_valid(_cvw_dlg) and _cvw_dlg.visible)]]
	for st in states:
		var b = st[0]
		if b == null or not is_instance_valid(b):
			continue
		var on = bool(st[1])
		if b.has_meta("bstate") and bool(b.get_meta("bstate")) == on:
			continue
		b.set_meta("bstate", on)
		if b == _float_btn:
			# Display-level state: dark background, blue ICON.
			_apply_button_style(b, false)
			b.modulate = UI_BLUE if on else Color(1, 1, 1)
		else:
			_apply_button_style(b, on)


# Clicking a DIFFERENT bar button folds the open sub-rows away.
func _float_collapse_rows() -> void:
	_float_hide_subrow()
	_float_close_menu()
	_float_sync_subrow()


# Snapshot: the button only OPENS its options row; the row buttons act.
func _on_float_snap_pressed() -> void:
	_float_close_menu()
	if _float_snap_open:
		_float_snap_open = false
		_float_sync_subrow()
	else:
		_float_open_family("snap")


func _on_float_snaprow_pressed(which: int) -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_float_snap_open = false
	_float_sync_subrow()
	if which == 1:
		_shape_area_pick = true
		Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		_update_cursor()
	else:
		_shape_save_raster_rect(null)


# Convert: the button only OPENS its options row; the row buttons act.
func _on_float_convert_pressed() -> void:
	_float_close_menu()
	if _float_conv_open:
		_float_conv_open = false
		_float_sync_subrow()
	else:
		_float_open_family("conv")


func _on_float_convrow_pressed(which: int) -> void:
	_float_conv_open = false
	_float_sync_subrow()
	if which == 1:
		_cvw_apply_previous()
	else:
		_plan_convert_to_dd()


func _on_float_gen_pressed() -> void:
	_float_close_menu()
	_on_plan_whole_map()


# One helper per family: opens its row (never closes it), closes the
# other families.
func _float_open_family(fam: String) -> void:
	_float_subrow_open = fam == "draw"
	_float_sel_open = fam == "sel"
	_float_era_open = fam == "era"
	_float_seg_open = fam == "seg"
	_float_snap_open = fam == "snap"
	_float_conv_open = fam == "conv"
	_float_sync_subrow()


func _on_float_draw_pressed() -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_change_mode(int(_float_draw_sub))
	_float_open_family("draw")


func _on_float_move_pressed() -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_change_mode(MODE_MOVE)
	_float_open_family("")


func _on_float_sel_pressed() -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_change_mode(MODE_SELECT)
	_float_open_family("sel")


func _on_float_text_pressed() -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	if _mode != MODE_TEXT:
		_change_mode(MODE_TEXT)
	_float_sync_subrow()


func _on_float_era2_pressed() -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_change_mode(MODE_ERASE)
	_float_open_family("era")


func _on_float_clear_pressed() -> void:
	_float_close_menu()
	_on_clear_canvas()


func _on_float_plan_pressed() -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	if _mode != MODE_PLAN:
		_change_mode(MODE_PLAN)
	# Plan's row never closes from its own button.
	_float_open_family("seg")


func _on_float_rand_pressed() -> void:
	# Toggles the SAME state as the panel's Randomize Settings button:
	# flipping the panel button fires its toggled signal, which drives
	# every per-setting dice and the tint sync.
	var on = _float_rand_state()
	if _btn_rand_global != null and is_instance_valid(_btn_rand_global):
		_btn_rand_global.pressed = not on
	else:
		_on_plan_auto_random_toggled(not on)
	_float_update_rand_tint()


func _float_rand_state() -> bool:
	for k in _plan_rand_flags:
		if bool(_plan_rand_flags[k]):
			return true
	return false


func _float_update_rand_tint() -> void:
	if _float_rand != null and is_instance_valid(_float_rand):
		_apply_button_style(_float_rand, _float_rand_state())


func _on_float_show_pressed() -> void:
	_float_close_menu()
	set_sketch_shown(not bool(_map_data.get("visible", true)))
	_float_update_show_tint()


func _float_update_show_tint() -> void:
	# Background-blue style: the white icon stays white (a modulate
	# overlay tinted it too).
	if _float_show != null and is_instance_valid(_float_show):
		_apply_button_style(_float_show, false)
		_float_show.modulate = UI_BLUE if bool(_map_data.get("visible", true)) else Color(1, 1, 1)
	_float_update_rand_tint()


func _on_float_close_pressed() -> void:
	_show_button = false
	# The panel checkbox follows: closing from the bar IS turning the
	# "Show Floatbar" option off.
	if _chk_button != null and is_instance_valid(_chk_button):
		_sync_ui = true
		_chk_button.pressed = false
		_sync_ui = false
	_float_bar_opts_sync()
	_float_close_menu()
	_float_tip_hide()
	_float_hide_subrow()
	_update_button_visibility()
	_save_settings()


func _update_float_btn_style() -> void:
	if _float_btn == null or not is_instance_valid(_float_btn):
		return
	# State-aware: the per-frame refresh owns the blue ON background.
	if _float_btn.has_meta("bstate"):
		_float_btn.set_meta("bstate", null)
	_float_refresh_states()


func _apply_button_style(btn, on: bool, neutral: bool = false) -> void:
	# Not a toggle button: the ON/OFF state is shown by the background color
	# (blue = active tool state, neutral grey = display toggles), so
	# clicking/dragging never flips the visual state by itself. Text
	# forced to white for readability.
	var base_col = Color(0.13, 0.13, 0.15, 0.95)
	var hover_col = Color(0.22, 0.22, 0.25, 0.95)
	if on and not neutral:
		base_col = Color(UI_BLUE_BG.r, UI_BLUE_BG.g, UI_BLUE_BG.b, 0.95)
		hover_col = Color(UI_BLUE_BG.lightened(0.15).r, UI_BLUE_BG.lightened(0.15).g, UI_BLUE_BG.lightened(0.15).b, 0.95)
	# neutral + on: the background stays dark, the ICON carries the
	# accent (handled by the caller through modulate).
	var states = {
		"normal": base_col,
		"hover": hover_col,
		"pressed": hover_col,
		"focus": base_col
	}
	for k in ["font_color", "font_color_hover", "font_color_pressed", "font_color_focus"]:
		btn.add_color_override(k, Color(1, 1, 1, 1))
	for k in states:
		var sb = StyleBoxFlat.new()
		sb.bg_color = states[k]
		sb.border_color = Color(1, 1, 1, 0.35)
		sb.set_border_width_all(1)
		sb.corner_radius_top_left = 4
		sb.corner_radius_top_right = 4
		sb.corner_radius_bottom_left = 4
		sb.corner_radius_bottom_right = 4
		sb.content_margin_left = 12
		sb.content_margin_right = 12
		sb.content_margin_top = 5
		sb.content_margin_bottom = 5
		btn.add_stylebox_override(k, sb)


func _toggle_visible_from_button() -> void:
	_map_data["visible"] = not bool(_map_data["visible"])
	_apply_display()
	_sync_display_controls()
	_write_map_data()


func _on_float_btn_gui(event) -> void:
	if _float_btn == null or not is_instance_valid(_float_btn):
		return
	# Moving the bar is the HANDLE's job: this button only toggles
	# between the Sketch tool and the previously active tool.
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT \
			and not event.pressed:
		if not _tool_active:
			Global.Editor.Toolset.Quickswitch(TOOL_ID)
		else:
			Global.Editor.Toolset.Quickswitch(_prev_tool_name)


func _save_button_frac() -> void:
	var vc = _viewport_container()
	if vc == null:
		return
	var r = vc.get_global_rect()
	if r.size.x <= 0.0 or r.size.y <= 0.0:
		return
	var rel = _float_origin - r.position
	_btn_frac = [rel.x / r.size.x, rel.y / r.size.y]
	_save_settings()


func _update_button_visibility() -> void:
	if _float_btn == null or not is_instance_valid(_float_btn):
		return
	_float_btn.visible = _show_button and _button_unlocked
	if _float_handle != null and is_instance_valid(_float_handle):
		_float_handle.visible = _float_btn.visible
	if _float_fold_btn != null and is_instance_valid(_float_fold_btn):
		_float_fold_btn.visible = _float_btn.visible and _tool_active
	var arch_on = not _plan_archetype.empty() and String(_plan_archetype.get("id", "")) != "custom"
	for fb3 in [_float_gen, _float_move, _float_draw, _float_sel, _float_era, _float_text, _float_plan, _float_clear2, _float_snap, _float_convert, _float_sets, _float_show, _float_close]:
		if fb3 != null and is_instance_valid(fb3):
			# Tool inactive: only Show and Close remain alongside the
			# handle and the Open Sketch button.
			var always = fb3 == _float_show or fb3 == _float_close
			fb3.visible = _float_btn.visible and not _float_folded \
				and (_tool_active or always)
			if fb3 == _float_rand:
				# Randomize only shuffles the (hidden) sliders: useless
				# under an archetype - greyed, not hidden.
				fb3.disabled = arch_on
	if _float_folded or not _float_btn.visible:
		_float_hide_subrow()
		_float_close_menu()
	_float_sync_side_buttons()


func _viewport_container():
	if Global.get("Exporter") == null:
		return null
	var vc = Global.Exporter.get("ViewportContainer")
	if vc == null or not is_instance_valid(vc):
		return null
	return vc


func _position_button() -> void:
	if _float_btn == null or not is_instance_valid(_float_btn) or not _float_btn.visible:
		return
	if _btn_drag_active:
		return
	var vc = _viewport_container()
	if vc == null:
		return
	var r = vc.get_global_rect()
	var pos = Vector2()
	if _btn_frac != null:
		pos = r.position + Vector2(float(_btn_frac[0]) * r.size.x, float(_btn_frac[1]) * r.size.y)
	else:
		pos = Vector2(r.position.x + r.size.x * 0.5 - _float_btn.rect_size.x * 0.5,
			r.position.y + r.size.y * 0.10)
	pos.x = clamp(pos.x, r.position.x, r.position.x + r.size.x - _float_btn.rect_size.x)
	pos.y = clamp(pos.y, r.position.y, r.position.y + r.size.y - _float_btn.rect_size.y)
	_float_origin = pos
	_float_sync_side_buttons()


func _build_dialogs() -> void:
	_rename_dialog = WindowDialog.new()
	_rename_dialog.window_title = "Rename Sketch"
	var vb = VBoxContainer.new()
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.margin_left = 10
	vb.margin_right = -10
	vb.margin_top = 10
	vb.margin_bottom = -10
	_rename_dialog.add_child(vb)
	_rename_edit = LineEdit.new()
	_rename_edit.placeholder_text = "Sketch name"
	vb.add_child(_rename_edit)
	var ok = Button.new()
	ok.text = "OK"
	vb.add_child(ok)
	ok.connect("pressed", self, "_on_rename_confirmed")
	_rename_edit.connect("text_entered", self, "_on_rename_text_entered")
	Global.Editor.add_child(_rename_dialog)
	_owned.append(_rename_dialog)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.window_title = "Delete Sketch"
	_delete_dialog.connect("confirmed", self, "_on_delete_confirmed")
	Global.Editor.add_child(_delete_dialog)
	_owned.append(_delete_dialog)


func _on_rename_text_entered(_txt: String) -> void:
	_on_rename_confirmed()


# ============================================================================
# Tool lifecycle & canvas input
# ============================================================================

func on_tool_enable(_tool_id) -> void:
	_dbg("on_tool_enable")
	_tool_active = true
	_button_unlocked = true
	if _mode == MODE_BRUSH:
		# The Brush sub-tool retired from the UI: stale saved states
		# land on Freehand.
		_mode = MODE_FREE
	if int(_float_draw_sub) == MODE_BRUSH:
		_float_draw_sub = MODE_FREE
	# The bar reflects the live mode right away: its row opens without
	# an extra click.
	if _mode == MODE_MOVE:
		_float_open_family("")
	elif _mode == MODE_SELECT:
		_float_open_family("sel")
	elif _mode == MODE_ERASE:
		_float_open_family("era")
	elif _mode == MODE_PLAN:
		_float_open_family("seg")
	elif _mode == MODE_SETTINGS:
		_float_open_family("")
	else:
		_float_open_family("draw")
	_update_button_visibility()
	_update_cursor()
	_suppress_dd_cursor()


func on_tool_disable(_tool_id) -> void:
	_shape_cancel()
	_seg_dragging = false
	_seg_batch = []
	if _seg_item != null and is_instance_valid(_seg_item):
		_seg_item.visible = false
	_dbg("on_tool_disable")
	if _txt_edit != null and is_instance_valid(_txt_edit) and _txt_edit.visible:
		# A live inline edit commits rather than evaporating.
		_on_txt_confirmed()
	_tool_active = false
	# A pending area pick dies with the tool: coming back must not
	# silently resume a snapshot armed in another life.
	if _shape_area_pick or _cv_area_pick:
		_shape_area_pick = false
		_cv_area_pick = false
		_plan_drag = null
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	_float_hide_subrow()
	_float_close_menu()
	_update_button_visibility()
	_cancel_stroke()
	if _sel_floating() and not bool(_sel["copy"]):
		# Restore the lifted region visually and serialize the true state
		# right away (the on-screen texture still shows the hole).
		_ops.append({"type": "stamp", "image": _sel.get("restore_img", _sel["img"]), "tex_rect": _sel["rect_tex"]})
		_serialize_active_from_image(_sel["pre"])
		_save_countdown = -1.0
		_sel_discard()
	else:
		_sel_discard()
		_flush_serialize()
	_update_cursor()
	_restore_dd_cursor()


# Kill the leftover pointers from other tools: the yellow brush circle
# (WorldUI.CursorMode, cf. terrain_paint_bucket in the Unofficial Patch) and
# the crosshair mouse cursor (Content.mouse_default_cursor_shape, cf.
# select_cursor_fix). Our own brush ring is the only cursor we want.
func _suppress_dd_cursor() -> void:
	var wui = Global.get("WorldUI")
	if wui != null:
		var cur = wui.get("CursorMode")
		if cur != null and int(cur) != 0:
			_saved_cursor_mode = int(cur)
		wui.set("CursorMode", 0)
	if _content_ctrl == null or not is_instance_valid(_content_ctrl):
		var node = Global.World.get_tree().root.get_node_or_null(
			"Master/Editor/VPartition/Panels/HSplit/Content")
		if node != null and node is Control:
			_content_ctrl = node
	if _content_ctrl != null and is_instance_valid(_content_ctrl):
		_content_ctrl.mouse_default_cursor_shape = Control.CURSOR_ARROW
	Input.set_custom_mouse_cursor(null, Input.CURSOR_ARROW)
	# The cursor shape is only re-read on the next mouse motion; warp the
	# mouse onto itself to force an immediate refresh.
	var vp = Global.World.get_viewport()
	if vp != null:
		Input.warp_mouse_position(vp.get_mouse_position())


func _restore_dd_cursor() -> void:
	# DD tools set their own CursorMode on enable; restore only as a courtesy
	# for tools that don't touch it.
	if _saved_cursor_mode >= 0:
		var wui = Global.get("WorldUI")
		if wui != null:
			wui.set("CursorMode", _saved_cursor_mode)
		_saved_cursor_mode = -1


# Per-frame re-assert while our tool is active: DD (or the ModBaseTool C#
# side) may rewrite the cursor after on_tool_enable, possibly every frame.
# Marshal cost is one property read per frame, only while our tool is active.
func _reassert_dd_cursor() -> void:
	if not _tool_active:
		return
	# Never touch the OS cursor while DD is in the background: fighting the
	# focused application's cursor every frame causes visible stutter there
	# (e.g. while using an external color picker).
	if not OS.is_window_focused():
		return
	var wui = Global.get("WorldUI")
	if wui != null:
		var cur = wui.get("CursorMode")
		if cur != null and int(cur) != 0:
			wui.set("CursorMode", 0)
	if _content_ctrl == null or not is_instance_valid(_content_ctrl):
		var node = Global.World.get_tree().root.get_node_or_null(
			"Master/Editor/VPartition/Panels/HSplit/Content")
		if node != null and node is Control:
			_content_ctrl = node
	if _content_ctrl != null and is_instance_valid(_content_ctrl) \
			and _content_ctrl.mouse_default_cursor_shape != Control.CURSOR_ARROW:
		_content_ctrl.mouse_default_cursor_shape = Control.CURSOR_ARROW
	if Input.get_current_cursor_shape() != Input.CURSOR_ARROW:
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)


func on_content_input(event) -> void:
	if _dbg_input_logged < 5:
		_dbg_input_logged += 1
		_dbg("on_content_input: " + str(event.get_class()))
	if not _nodes_ok():
		_dbg("on_content_input: nodes NOT ok, ignoring")
		return
	# Shape placement ghost eats every event first, whatever the mode.
	if _shape_ghost != null:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index == BUTTON_LEFT:
				_shape_stamp()
			elif event.button_index == BUTTON_RIGHT:
				_shape_cancel()
			elif event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN:
				var dirn = 1.0
				if event.button_index == BUTTON_WHEEL_DOWN:
					dirn = -1.0
				if event.alt:
					var f = 1.05
					if dirn < 0.0:
						f = 1.0 / 1.05
					_shape_ghost["scale"] = clamp(float(_shape_ghost.get("scale", 1.0)) * f, 0.25, 4.0)
				else:
					var step = 10.0
					if Input.is_key_pressed(KEY_Z):
						step = 5.0
						if event.shift:
							step = 1.0
					_shape_ghost["ang"] = fmod(float(_shape_ghost.get("ang", 0.0)) + deg2rad(step) * dirn, TAU)
		elif event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE:
			_shape_cancel()
		if _ghost_item != null and is_instance_valid(_ghost_item):
			_ghost_item.update()
		return
	if _mode == MODE_MOVE and _lbl_input(event):
		return
	if _mode == MODE_PLAN and not _shape_area_pick and not _cv_area_pick \
			and not ((_seg_type >= 0 or _seg_dragging) \
			and event is InputEventMouseButton and (event.button_index == BUTTON_WHEEL_UP \
			or event.button_index == BUTTON_WHEEL_DOWN)) \
			and _lbl_input(event):
		# Labels are editable from Plan too - and this must run BEFORE
		# the segment block, which otherwise swallows every event while
		# a segment sub-tool is active. Presses miss labels? They fall
		# through to the segments. The wheel only routes to labels when
		# NO segment sub-tool is active: with one armed it stays the
		# segment-orientation control.
		return
	if _mode == MODE_PLAN and (_seg_type >= 0 or _seg_dragging) and not _shape_area_pick \
			and not _cv_area_pick:
		_seg_ensure_item()
		if event is InputEventMouseButton:
			if event.button_index == BUTTON_LEFT or event.button_index == BUTTON_RIGHT:
				if event.pressed:
					_seg_dragging = true
					_seg_erase_rmb = event.button_index == BUTTON_RIGHT
					_seg_last_key = ""
					_seg_batch = []
					_seg_lock = null
					_seg_push_hovered()
				elif _seg_dragging:
					_seg_dragging = false
					_seg_commit()
					_seg_erase_rmb = false
			elif event.button_index == BUTTON_MIDDLE:
				# Middle CLICK cycles the drawing sub-tool; a middle
				# DRAG is the map pan and must not cycle anything.
				if event.pressed:
					_seg_mid_press = event.position
				else:
					if _seg_mid_press != null \
							and event.position.distance_to(_seg_mid_press) < 6.0:
						var cyc = [0, 1, 2, 4]
						var ci = cyc.find(_seg_type)
						_seg_type = cyc[(ci + 1) % cyc.size()] if ci >= 0 else 0
						_seg_sync_btns()
					_seg_mid_press = null
			elif event.pressed and (event.button_index == BUTTON_WHEEL_UP \
					or event.button_index == BUTTON_WHEEL_DOWN):
				if _seg_type == 4 and event.alt:
					# Tower radius, half-cell steps.
					var dr = 0.5 if event.button_index == BUTTON_WHEEL_UP else -0.5
					_seg_tower_r = clamp(_seg_tower_r + dr, 0.5, 4.0)
				elif _seg_type == 4:
					# Opening rotates in 1/8-turn notches (8 positions).
					var stw = 1 if event.button_index == BUTTON_WHEEL_UP else 7
					_seg_tower_orient = (_seg_tower_orient + stw) % 8
				else:
					# The wheel cycles the ORIENTATION (h / v / d1 / d2;
					# for the tower: which quadrant stays open):
					# placement is explicit, the mouse only picks where.
					var stp = 1
					if event.button_index == BUTTON_WHEEL_DOWN:
						stp = 3
					_seg_orient_mode = (_seg_orient_mode + stp) % 4
		elif event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE:
			_seg_dragging = false
			_seg_batch = []
			_seg_lock = null
		elif event is InputEventMouseMotion:
			if _seg_dragging:
				_seg_push_hovered()
		return
	if (_shape_area_pick or _cv_area_pick) and event is InputEventKey \
			and event.pressed and event.scancode == KEY_ESCAPE:
		# ESC drops a pending area pick whatever the mode.
		_shape_area_pick = false
		_cv_area_pick = false
		_plan_drag = null
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		_sel_show_overlay()
		_update_cursor()
		return
	if _mode == MODE_SETTINGS and not _shape_area_pick and not _cv_area_pick:
		# The Settings tab paints nothing.
		return
	if _mode == MODE_TEXT and not _shape_area_pick and not _cv_area_pick:
		_txt_input(event)
		return
	if _mode == MODE_PLAN or _shape_area_pick or _cv_area_pick:
		# Area picking (save a shape / convert an area) works from any
		# mode: the pick routes to the plan drag machinery instead of
		# the mode's own handler - starting a pick in Draw used to
		# PAINT over the very area being selected. Right-click cancels
		# the pick outside Plan.
		if event is InputEventMouseButton:
			if event.button_index == BUTTON_LEFT:
				if event.pressed:
					_plan_press()
				else:
					_plan_release()
			elif event.button_index == BUTTON_RIGHT and event.pressed:
				if _mode != MODE_PLAN:
					_shape_area_pick = false
					_cv_area_pick = false
					Input.set_default_cursor_shape(Input.CURSOR_ARROW)
				_plan_drag = null
				_sel_show_overlay()
		elif event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE \
				and (_shape_area_pick or _cv_area_pick):
			# ESC drops the pick (the bar's blue state follows).
			_shape_area_pick = false
			_cv_area_pick = false
			_plan_drag = null
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
			_sel_show_overlay()
			_update_cursor()
		elif event is InputEventMouseMotion:
			_plan_motion()
		return
	if _mode == MODE_SELECT or _mode == MODE_MOVE or _sel != null:
		if event is InputEventMouseButton:
			if event.button_index == BUTTON_LEFT:
				if event.pressed:
					if _mode == MODE_SELECT:
						_sel_press()
					else:
						_move_press()
				else:
					_sel_release()
			elif event.button_index == BUTTON_RIGHT and event.pressed:
				_sel_cancel()
			elif event.pressed and event.button_index == BUTTON_WHEEL_UP:
				_sel_rotate_step(5.0)
			elif event.pressed and event.button_index == BUTTON_WHEEL_DOWN:
				_sel_rotate_step(-5.0)
		elif event is InputEventMouseMotion:
			_sel_motion()
		return
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				_on_pressed(BUTTON_LEFT)
			elif _stroke != null and _stroke_button == BUTTON_LEFT:
				_end_stroke()
		elif event.button_index == BUTTON_RIGHT:
			if event.pressed:
				if _stroke != null and _stroke_button == BUTTON_LEFT:
					_cancel_stroke()
				else:
					_on_pressed(BUTTON_RIGHT)
			elif _stroke != null and _stroke_button == BUTTON_RIGHT:
				_end_stroke()
		elif event.pressed and event.button_index == BUTTON_WHEEL_UP:
			# Fixed kinds AND shapes lock the width: no wheel resize
			# outside the free brush.
			if not (_kind_active() and _paint_kind != 0) \
					and _mode != MODE_RECT and _mode != MODE_ELLIPSE:
				_adjust_width(1.1)
		elif event.pressed and event.button_index == BUTTON_WHEEL_DOWN:
			if not (_kind_active() and _paint_kind != 0) \
					and _mode != MODE_RECT and _mode != MODE_ELLIPSE:
				_adjust_width(1.0 / 1.1)
	elif event is InputEventMouseMotion:
		if _stroke != null and _stroke_dragging:
			_update_stroke_point()
		_update_cursor()


func _busy() -> bool:
	return _stroke != null or _op_busy > 0 or not _ops.empty() \
		or _plan_pending != null or _plan_render != null


func _mouse_world() -> Vector2:
	return Global.WorldUI.MousePosition


# ── Snap (DD native + Custom Snap mod) ──────────────────────────────────────

func _get_custom_snap_api():
	var editor = Global.Editor
	if editor == null or not ("Tools" in editor):
		return null
	var tools = editor.Tools
	if tools == null or not tools.has("snappy_mod"):
		return null
	var snappy = tools["snappy_mod"]
	if snappy == null or not snappy.has_method("get_ScriptInstance"):
		return null
	var inst = snappy.get_ScriptInstance()
	if inst == null or not inst.has_method("get_snapped_position"):
		return null
	return inst


func _snap_point(p: Vector2) -> Vector2:
	# Vanilla Snap to Grid is the MASTER switch: Custom Snap only
	# refines WHERE to snap, never whether to snap at all.
	if Global.Editor.get("IsSnapping") != true:
		return p
	var cs = _get_custom_snap_api()
	if cs != null and cs.get("custom_snap_enabled") == true:
		return cs.get_snapped_position(p)
	if Global.WorldUI.has_method("GetSnappedPosition"):
		return Global.WorldUI.GetSnappedPosition(p)
	return p


# ── Stroke state machine ────────────────────────────────────────────────────

func _on_pressed(button: int) -> void:
	_dbg("pressed btn=" + str(button) + " busy=" + str(_busy())
		+ " op_busy=" + str(_op_busy) + " ops=" + str(_ops.size())
		+ " commit_cd=" + str(_commit_countdown))
	if _busy():
		return
	var p = _snap_point(_mouse_world())
	# Drawing on a hidden sketch would be confusing: force it visible.
	if not bool(_map_data["visible"]):
		_map_data["visible"] = true
		_apply_display()
		_sync_display_controls()
		_write_map_data()

	# Right button = "negative" of the current tool: same geometry and
	# settings, but erasing instead of painting.
	var erase = button == BUTTON_RIGHT
	var shift = Input.is_key_pressed(KEY_SHIFT)
	if (_mode == MODE_FREE or _mode == MODE_BRUSH) and shift and _last_free_pt != null:
		# Photoshop-style Shift+Click: straight line from the last endpoint.
		_begin_stroke(_mode, p, erase, button)
		_stroke["pts"] = [_last_free_pt, p]
		_stroke_item.update()
		_end_stroke()
		return

	_begin_stroke(_mode, p, erase, button)


func _begin_stroke(mode: int, p: Vector2, erase: bool = false, button: int = BUTTON_LEFT) -> void:
	_pre_image = _readback_a()
	if _pre_image == null:
		# Undo record will be skipped for this stroke, but drawing must work.
		_dbg("begin_stroke: readback_a returned null (undo disabled for this stroke)")
	else:
		_dbg("begin_stroke: mode=" + str(mode) + " pre=" + str(_pre_image.get_size()))
	var w = _paint_width()
	if mode == MODE_ERASE:
		w = _eraser_width
	elif mode == MODE_BRUSH:
		w = _brush_width
	elif mode == MODE_RECT or mode == MODE_ELLIPSE:
		# Shape outlines are FIXED at wall width: uniform silhouettes,
		# and merged rings always erase/redraw the same band.
		w = 32.0
	elif erase and _kind_active() and _paint_kind != 0:
		# Right-click erase in a fixed kind wipes the FULL wall width:
		# in window/door kind that covers both the portal stroke and
		# its black underlay.
		w = 32.0
	# Right-click shape while Merge Shapes is ON: boolean SUBTRACT (the
	# shape carves a hole out of the merged silhouettes).
	var sub = erase and _merge_shapes and mode != MODE_ERASE \
			and (mode == MODE_RECT or mode == MODE_ELLIPSE)
	_stroke = {
		"mode": mode,
		"erase": erase or mode == MODE_ERASE,
		"sub": sub,
		"anchor": p,
		"pts": [p],
		"rect": Rect2(p, Vector2()),
		"width": w,
		"color": _paint_color(),
		"fill_color": _fill_color,
		"intensity": _paint_intensity(),
		"style": _shape_style,
		"lock_axis": -1
	}
	_stroke_button = button
	_stroke_dragging = true
	if sub:
		_sub_ensure_item()
	_commit_countdown = -1
	_view_b.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
	_view_b.render_target_update_mode = Viewport.UPDATE_ALWAYS
	if _stroke_item != null and is_instance_valid(_stroke_item):
		_stroke_item.update()
	if bool(_stroke["erase"]):
		_display_mat.set_shader_param("stroke_mode", 2.0)
		_display_mat.set_shader_param("stroke_intensity", 1.0)
	else:
		_display_mat.set_shader_param("stroke_mode", 1.0)
		_display_mat.set_shader_param("stroke_intensity", _paint_intensity())


func _update_stroke_point() -> void:
	if _stroke == null:
		return
	var raw = _mouse_world()
	var p = _snap_point(raw)
	var mode = int(_stroke["mode"])
	if mode == MODE_FREE or mode == MODE_ERASE or mode == MODE_BRUSH:
		if Input.is_key_pressed(KEY_SHIFT):
			# Lock to a perfectly horizontal or vertical line from the anchor.
			# The axis is decided once per stroke and never changes until
			# the button is released.
			var la = _stroke["anchor"]
			if int(_stroke["lock_axis"]) == -1:
				var ld = p - la
				if ld.length() > 0.5:
					if abs(ld.x) >= abs(ld.y):
						_stroke["lock_axis"] = 0
					else:
						_stroke["lock_axis"] = 1
			if int(_stroke["lock_axis"]) == 0:
				p.y = la.y
			elif int(_stroke["lock_axis"]) == 1:
				p.x = la.x
		else:
			# Releasing Shift unlocks; pressing it again re-decides the axis.
			_stroke["lock_axis"] = -1
		var pts = _stroke["pts"]
		if pts.size() == 0 or pts[pts.size() - 1].distance_to(p) > 0.5:
			pts.append(p)
	elif mode == MODE_LINE:
		if Input.is_key_pressed(KEY_SHIFT):
			var a = _stroke["anchor"]
			var d = p - a
			if d.length() > 0.001:
				var ang = stepify(d.angle(), PI / 4.0)
				var u = Vector2(cos(ang), sin(ang))
				p = a + u * max(d.dot(u), 0.0)
		_stroke["pts"] = [_stroke["anchor"], p]
	else:
		var a = _stroke["anchor"]
		var d = p - a
		if Input.is_key_pressed(KEY_SHIFT):
			var m = max(abs(d.x), abs(d.y))
			d = Vector2(m * sign(d.x if d.x != 0.0 else 1.0), m * sign(d.y if d.y != 0.0 else 1.0))
		if Input.is_key_pressed(KEY_ALT):
			_stroke["rect"] = Rect2(a - d, d * 2.0).abs()
		else:
			_stroke["rect"] = Rect2(a, d).abs()
	if _stroke_item != null and is_instance_valid(_stroke_item):
		_stroke_item.update()


func _end_stroke() -> void:
	if _stroke == null or not _stroke_dragging:
		return
	_stroke_dragging = false
	# Let B render the final geometry for a couple of frames before flattening.
	_commit_countdown = 2


func _cancel_stroke() -> void:
	_stroke = null
	_stroke_dragging = false
	_commit_countdown = -1
	_pre_image = null
	if _view_b != null and is_instance_valid(_view_b):
		_view_b.render_target_update_mode = Viewport.UPDATE_DISABLED
	if _display_mat != null:
		_display_mat.set_shader_param("stroke_mode", 0.0)


func _commit_stroke() -> void:
	if _stroke == null or not _nodes_ok():
		_cancel_stroke()
		return
	_view_b.render_target_update_mode = Viewport.UPDATE_DISABLED
	var rect = _stroke_tex_rect()
	if bool(_stroke["erase"]):
		_ops.append({
			"type": "erase",
			"strength": 1.0,
			"callback": "_after_commit",
			"args": [rect]
		})
	else:
		_ops.append({
			"type": "paint",
			"color": _stroke["color"],
			"intensity": float(_stroke["intensity"]),
			"callback": "_after_commit",
			"args": [rect]
		})


func _after_commit(rect: Rect2) -> void:
	_dbg("after_commit rect=" + str(rect))
	_display_mat.set_shader_param("stroke_mode", 0.0)
	var stroke = _stroke
	_stroke = null
	if stroke == null:
		_pre_image = null
		return
	var post_full = _readback_a()
	if post_full == null:
		_dbg("after_commit: post readback null")
	# Shape commits mutate the merged-shape store: snapshot it around
	# the cleanups so undo/redo restores the STORE with the pixels (an
	# undone shape used to linger invisibly and come back to life when
	# a later neighbour merged over its footprint).
	var shp_pair = null
	var shp_touches = post_full != null and (bool(stroke.get("sub", false)) \
		or (not bool(stroke["erase"]) \
		and int(stroke.get("style", SHAPE_OUTLINE)) != SHAPE_FILL \
		and (int(stroke["mode"]) == MODE_RECT or int(stroke["mode"]) == MODE_ELLIPSE)))
	if shp_touches and _active_sketch() != null:
		shp_pair = [_merge_store_entries(_active_sketch()).duplicate(true), null]
	if post_full != null and bool(stroke.get("sub", false)):
		var sreg = _merge_subtract_cleanup(post_full, stroke)
		if sreg != null:
			rect = rect.merge(sreg)
			rect = rect.clip(Rect2(Vector2(), Vector2(post_full.get_width(), post_full.get_height())))
			_ops.append({"type": "stamp", "image": post_full.get_rect(sreg), "tex_rect": sreg})
	if post_full != null and not bool(stroke["erase"]) \
			and int(stroke.get("style", SHAPE_OUTLINE)) != SHAPE_FILL \
			and (int(stroke["mode"]) == MODE_RECT or int(stroke["mode"]) == MODE_ELLIPSE):
		var mreg = _merge_union_cleanup(post_full, stroke)
		if mreg != null:
			# History must cover the WHOLE cleaned region, then the
			# cleaned pixels go back to the live texture.
			rect = rect.merge(mreg)
			rect = rect.clip(Rect2(Vector2(), Vector2(post_full.get_width(), post_full.get_height())))
			_ops.append({"type": "stamp", "image": post_full.get_rect(mreg), "tex_rect": mreg})
	if shp_pair != null and _active_sketch() != null:
		shp_pair[1] = _merge_store_entries(_active_sketch()).duplicate(true)
	if post_full != null and _pre_image != null and rect.size.x >= 1 and rect.size.y >= 1:
		var pre_crop = _pre_image.get_rect(rect)
		var post_crop = post_full.get_rect(rect)
		_push_history(int(_active_sketch()["uid"]), rect, pre_crop, post_crop,
			null, null, shp_pair)
	_pre_image = null
	if int(stroke["mode"]) == MODE_FREE or int(stroke["mode"]) == MODE_BRUSH:
		var pts = stroke["pts"]
		if pts.size() > 0:
			_last_free_pt = pts[pts.size() - 1]
	_mark_dirty()


# Merged-shape store: each entry is {"outer": [...], "holes": [[...]]}
# describing a silhouette RING and its persistent holes. Legacy entries
# (plain point arrays from before holes existed) are normalized on read.
func _merge_store_entries(sk) -> Array:
	if not sk.has("merge_polys"):
		sk["merge_polys"] = []
	var out = []
	for e in sk["merge_polys"]:
		if e is Dictionary:
			var hs = []
			for h in e.get("holes", []):
				hs.append(PoolVector2Array(h))
			out.append({"outer": PoolVector2Array(e["outer"]), "holes": hs})
		else:
			out.append({"outer": PoolVector2Array(e), "holes": []})
	return out


func _merge_store_write(sk, entries: Array) -> void:
	var raw = []
	for e in entries:
		var hs = []
		for h in e["holes"]:
			hs.append(Array(h))
		raw.append({"outer": Array(e["outer"]), "holes": hs})
	sk["merge_polys"] = raw
	_mark_dirty()


# Overlap test that also catches EDGE-TOUCHING polygons: two shapes
# ending on the same snapped line have zero intersection area, but they
# must merge all the same. A hair of growth (2 px world) turns the
# shared edge into a real overlap; merge_polygons_2d itself welds
# touching polygons fine, only the detection needed the epsilon.
func _merge_polys_touch(a: PoolVector2Array, b: PoolVector2Array) -> bool:
	if Geometry.intersect_polygons_2d(a, b).size() > 0:
		return true
	for g in Geometry.offset_polygon_2d(a, 2.0):
		if Geometry.intersect_polygons_2d(g, b).size() > 0:
			return true
	return false


# Geometry.intersect_polygons_2d hands its pieces back CLOCKWISE (the
# opposite of merge/clip outers): filtering them on "not clockwise"
# silently dropped every hole ring, so carves lost their outline AND
# their store entry. Orientation is normalized instead of filtered.
func _merge_ccw(p: PoolVector2Array) -> PoolVector2Array:
	if not Geometry.is_polygon_clockwise(p):
		return p
	var out = PoolVector2Array()
	for i in range(p.size()):
		out.append(p[p.size() - 1 - i])
	return out


# Transparent band erased along a ring: wipes an old outline without
# touching whatever lives beside it (hole interiors keep their detail).
func _merge_erase_ring(img, ring, ts: float, w: float, clip_r = null) -> void:
	var n = ring.size()
	for i in range(n):
		var a = ring[i] * ts
		var b = ring[(i + 1) % n] * ts
		if clip_r != null:
			var eb = Rect2(a, Vector2()).expand(b).grow(w + 4.0)
			if not eb.intersects(clip_r):
				continue
		_img_draw_line(img, a, b, Color(0, 0, 0, 0), w + 4.0, false)


func _merge_draw_ring(img, ring, ts: float, col: Color, w: float, clip_r = null) -> void:
	var n = ring.size()
	for i in range(n):
		var a = ring[i] * ts
		var b = ring[(i + 1) % n] * ts
		if clip_r != null:
			var eb = Rect2(a, Vector2()).expand(b).grow(w)
			if not eb.intersects(clip_r):
				continue
		_img_draw_line(img, a, b, col, w, false)


func _merge_ring_bbox_tex(ring, ts: float, w: float) -> Rect2:
	var r = Rect2(ring[0] * ts, Vector2())
	for p in ring:
		r = r.expand(p * ts)
	return r.grow(w + 4.0)


# Union merge for shape strokes, VECTOR edition with PERSISTENT HOLES:
# the union is computed against the stored silhouettes, carved holes
# survive (minus whatever the new shape actually covers), and a shape
# dropped entirely inside a hole becomes its own island. The involved
# outline bands are erased and the result rings redrawn; hole interiors
# keep their pixels. Returns the cleaned region (tex px) or null.
func _merge_union_cleanup(img, stroke):
	var sk = _active_sketch()
	if sk == null:
		return null
	var w = max(1.0, float(stroke["width"]) * _tex_scale)
	var poly = _merge_stroke_poly(stroke)
	var entries = _merge_store_entries(sk)
	if not _merge_shapes:
		# Toggle OFF: the shape is still RECORDED, so flipping the
		# toggle on later merges it properly instead of erasing it
		# blindly during a neighbour's union.
		entries.append({"outer": poly, "holes": [], "w": float(stroke["width"])})
		_merge_store_write(sk, entries)
		return null
	var hits = []
	var keep = []
	for e in entries:
		if not _merge_polys_touch(poly, e["outer"]):
			keep.append(e)
			continue
		var island = false
		for h in e["holes"]:
			if Geometry.clip_polygons_2d(poly, h).size() == 0:
				island = true
				break
		if island:
			# Entirely inside a courtyard: an island, not a merge.
			keep.append(e)
		else:
			hits.append(e)
	if hits.empty():
		entries.append({"outer": poly, "holes": [], "w": float(stroke["width"])})
		_merge_store_write(sk, entries)
		return null
	# Sequential union of the outers; rings closed by the merge itself
	# (two shapes hugging a void) join the hole pool.
	var outers = [poly]
	var hole_pool = []
	for e in hits:
		for h in e["holes"]:
			hole_pool.append(h)
	for e in hits:
		var hp = e["outer"]
		var merged_in = false
		for oi in range(outers.size()):
			if not _merge_polys_touch(outers[oi], hp):
				continue
			var res = Geometry.merge_polygons_2d(outers[oi], hp)
			var new_outers = []
			for rp in res:
				if Geometry.is_polygon_clockwise(rp):
					hole_pool.append(rp)
				else:
					new_outers.append(rp)
			if new_outers.size() > 0:
				outers.remove(oi)
				for np in new_outers:
					outers.append(np)
				merged_in = true
			break
		if not merged_in:
			outers.append(hp)
	# Holes survive, minus what the new shape covers.
	var final_holes = []
	for h in hole_pool:
		for piece in Geometry.clip_polygons_2d(h, poly):
			if not Geometry.is_polygon_clockwise(piece) and piece.size() >= 3:
				final_holes.append(piece)
	var ts = _tex_scale
	var col = stroke["color"]
	col.a = 1.0
	var reg = null
	img.lock()
	# Erase: the new shape's own area, plus a band along every OLD ring.
	var tex_poly = PoolVector2Array()
	for p in poly:
		tex_poly.append(p * ts)
	for gp in Geometry.offset_polygon_2d(tex_poly, w * 0.55 + 2.0):
		var br = _poly_bbox(gp)
		if reg == null:
			reg = br
		else:
			reg = reg.merge(br)
		_img_fill_polygon(img, gp, Color(0, 0, 0, 0))
	for e in hits:
		# Erase with the FATTEST band involved: an old ring drawn wider
		# than the new stroke used to leave a ghost outline behind.
		var we = max(w, float(e.get("w", 32.0)) * ts)
		_merge_erase_ring(img, e["outer"], ts, we)
		reg = reg.merge(_merge_ring_bbox_tex(e["outer"], ts, we))
		for h in e["holes"]:
			_merge_erase_ring(img, h, ts, we)
			reg = reg.merge(_merge_ring_bbox_tex(h, ts, we))
	# Redraw: fill first for Both, rings on top.
	if int(stroke.get("style", SHAPE_OUTLINE)) != SHAPE_OUTLINE:
		var fillc = stroke["fill_color"]
		for op in outers:
			var tf = PoolVector2Array()
			for p in op:
				tf.append(p * ts)
			_img_fill_polygon(img, tf, fillc)
		for h in final_holes:
			var th = PoolVector2Array()
			for p in h:
				th.append(p * ts)
			_img_fill_polygon(img, th, Color(0, 0, 0, 0))
	for op in outers:
		_merge_draw_ring(img, op, ts, col, w)
		reg = reg.merge(_merge_ring_bbox_tex(op, ts, w))
	for h in final_holes:
		_merge_draw_ring(img, h, ts, col, w)
		reg = reg.merge(_merge_ring_bbox_tex(h, ts, w))
	img.unlock()
	# Store: keep + the new entries, holes assigned by containment.
	var new_entries = keep
	for op in outers:
		var hs = []
		for h in final_holes:
			if h.size() > 0 and Geometry.is_point_in_polygon(h[0], op):
				hs.append(h)
		new_entries.append({"outer": op, "holes": hs, "w": float(stroke["width"])})
	_merge_store_write(sk, new_entries)
	if reg == null:
		return null
	reg = reg.grow(w + 2.0)
	reg = reg.clip(Rect2(Vector2(), Vector2(img.get_width(), img.get_height())))
	if reg.size.x < 1.0 or reg.size.y < 1.0:
		return null
	return reg


# The exact polygon a shape stroke stamps (rect corners / ellipse
# 96-gon), in world px.
func _merge_stroke_poly(stroke) -> PoolVector2Array:
	var r = stroke["rect"]
	var poly = PoolVector2Array()
	if int(stroke["mode"]) == MODE_RECT:
		poly.append(r.position)
		poly.append(r.position + Vector2(r.size.x, 0))
		poly.append(r.position + r.size)
		poly.append(r.position + Vector2(0, r.size.y))
	else:
		var c = r.position + r.size * 0.5
		for i in range(ELLIPSE_SEGMENTS):
			var a = float(i) / float(ELLIPSE_SEGMENTS) * PI * 2.0
			poly.append(c + Vector2(cos(a) * r.size.x * 0.5, sin(a) * r.size.y * 0.5))
	return poly


# Boolean SUBTRACT (right-click shape with Merge Shapes ON): the shape
# is clipped OUT of every stored silhouette it overlaps; the resulting
# holes are STORED with their silhouette and survive later unions.
func _merge_subtract_cleanup(img, stroke):
	var sk = _active_sketch()
	if sk == null:
		return null
	var poly = _merge_stroke_poly(stroke)
	var entries = _merge_store_entries(sk)
	var hits = []
	var keep = []
	for e in entries:
		# Touch-aware: a carve FLUSH against a wall must still be
		# processed, or the erase margin nibbles the wall and nothing
		# ever repaints it.
		if _merge_polys_touch(poly, e["outer"]):
			hits.append(e)
		else:
			keep.append(e)
	if hits.empty():
		return null
	var w = max(1.0, float(stroke["width"]) * _tex_scale)
	var ts = _tex_scale
	var col = stroke["color"]
	col.a = 1.0
	var tex_poly = PoolVector2Array()
	for p in poly:
		tex_poly.append(p * ts)
	var reg = null
	img.lock()
	for gp in Geometry.offset_polygon_2d(tex_poly, w * 0.55 + 2.0):
		var br = _poly_bbox(gp)
		if reg == null:
			reg = br
		else:
			reg = reg.merge(br)
		_img_fill_polygon(img, gp, Color(0, 0, 0, 0))
	if reg == null:
		img.unlock()
		return null
	var touch = reg.grow(w + 2.0)
	var new_entries = keep
	for e in hits:
		# The OLD boundary near the carve goes first: a carve crossing
		# the silhouette edge reshapes it, and half-covered old corner
		# pixels otherwise survive as doubled stubs next to the new
		# wall. Far edges are left strictly alone.
		var we2 = max(w, float(e.get("w", 32.0)) * ts)
		_merge_erase_ring(img, e["outer"], ts, we2, touch)
		for h0 in e["holes"]:
			_merge_erase_ring(img, h0, ts, we2, touch)
		var outers = []
		for rp in Geometry.clip_polygons_2d(e["outer"], poly):
			if not Geometry.is_polygon_clockwise(rp):
				outers.append(rp)
		# Hole material: the old holes plus the part of the shape lying
		# inside the silhouette. Overlapping rings then merge pairwise
		# until stable, so two crossing carves become ONE hole with one
		# wall (keeping both the raw carve ring and the merged ring
		# used to draw the second outline inside the first hole).
		var rings = []
		for h in e["holes"]:
			rings.append(h)
		for ip in Geometry.intersect_polygons_2d(poly, e["outer"]):
			if ip.size() >= 3:
				rings.append(_merge_ccw(ip))
		var merged_rings = []
		while rings.size() > 0:
			var cur = rings.pop_back()
			var again = true
			while again:
				again = false
				for i in range(rings.size()):
					if not _merge_polys_touch(cur, rings[i]):
						continue
					var mm = Geometry.merge_polygons_2d(cur, rings[i])
					rings.remove(i)
					var first = null
					for r2 in mm:
						if Geometry.is_polygon_clockwise(r2):
							continue
						if first == null:
							first = r2
						else:
							rings.append(r2)
					if first != null:
						cur = first
					again = true
					break
			merged_rings.append(cur)
		for o in outers:
			var hs = []
			for ring in merged_rings:
				# Clipped to the surviving outer: a hole ring never
				# leaks past its silhouette.
				for piece in Geometry.intersect_polygons_2d(ring, o):
					if piece.size() >= 3:
						hs.append(_merge_ccw(piece))
			new_entries.append({"outer": o, "holes": hs, "w": float(stroke["width"])})
			_merge_draw_ring(img, o, ts, col, w, touch)
			for h2 in hs:
				_merge_draw_ring(img, h2, ts, col, w, touch)
	img.unlock()
	_merge_store_write(sk, new_entries)
	reg = reg.grow(w + 2.0)
	reg = reg.clip(Rect2(Vector2(), Vector2(img.get_width(), img.get_height())))
	if reg.size.x < 1.0 or reg.size.y < 1.0:
		return null
	return reg


func _poly_bbox(p) -> Rect2:
	var r = Rect2(p[0], Vector2())
	for q in p:
		r = r.expand(q)
	return r


# Scanline polygon fill straight into the image (the per-pixel
# point-in-polygon test was far too slow for ellipse unions).
func _img_fill_polygon(img, poly, col: Color) -> void:
	var n = poly.size()
	if n < 3:
		return
	var y0 = int(max(0, floor(_poly_bbox(poly).position.y)))
	var y1 = int(min(img.get_height() - 1, ceil(_poly_bbox(poly).end.y)))
	for y in range(y0, y1 + 1):
		var yc = float(y) + 0.5
		var xs = []
		for i in range(n):
			var a = poly[i]
			var b = poly[(i + 1) % n]
			if (a.y <= yc and b.y > yc) or (b.y <= yc and a.y > yc):
				xs.append(a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x))
		xs.sort()
		var k = 0
		while k + 1 < xs.size():
			var sx = int(max(0, ceil(float(xs[k]) - 0.5)))
			var ex = int(min(img.get_width() - 1, floor(float(xs[k + 1]) - 0.5)))
			for x in range(sx, ex + 1):
				img.set_pixel(x, y, col)
			k += 2


# Stroke bounding box, in texture pixels, clamped to the texture.
func _stroke_tex_rect() -> Rect2:
	var mode = int(_stroke["mode"])
	var half = float(_stroke["width"]) * 0.5
	var r = Rect2()
	if mode == MODE_RECT or mode == MODE_ELLIPSE:
		# Filled shapes draw their border too, which extends half the stroke
		# width outside the rect: always grow, or undo leaves a residue ring.
		r = _stroke["rect"]
		r = r.grow(half)
	else:
		var pts = _stroke["pts"]
		r = Rect2(pts[0], Vector2())
		for p in pts:
			r = r.expand(p)
		r = r.grow(half)
	_dbg("stroke_tex_rect from " + str(r))
	var pos = (r.position * _tex_scale).floor() - Vector2(3, 3)
	var end = ((r.position + r.size) * _tex_scale).ceil() + Vector2(3, 3)
	pos.x = clamp(pos.x, 0, _tex_size.x - 1)
	pos.y = clamp(pos.y, 0, _tex_size.y - 1)
	end.x = clamp(end.x, pos.x + 1, _tex_size.x)
	end.y = clamp(end.y, pos.y + 1, _tex_size.y)
	return Rect2(pos, end - pos)


# ============================================================================
# Selection tool (rectangular marquee, move / copy / rotate / delete)
# ============================================================================

func _sel_floating() -> bool:
	return _sel != null and String(_sel["state"]) == "float"


func _sel_press() -> void:
	if _op_busy > 0 or not _ops.empty():
		return
	var raw = _mouse_world()
	if _sel_floating():
		var h = _sel_hit_corner(raw)
		if h >= 0:
			_sel_start_resize(h, raw)
			return
		if _sel_point_inside(raw):
			if Input.is_key_pressed(KEY_ALT):
				# Alt+drag: stamp a copy at the current spot, keep dragging.
				_sel_duplicate_here()
			_sel["drag"] = {"kind": "move", "grab": raw, "start": _sel["center"]}
			return
		# Click outside applies the floating selection, then a new marquee
		# starts right away. Always a commit: its history record carries the
		# selection, so undo can bring THIS selection back.
		_sel_commit()
	elif _sel != null:
		_sel_discard()
	var p = _snap_point(raw)
	_sel = {
		"state": "marquee",
		"anchor": p,
		"rect_world": Rect2(p, Vector2()),
		"rect_tex": Rect2(),
		"img": null, "tex": null, "pre": null,
		"copy": false,
		"center": Vector2(),
		"rot": 0.0,
		"drag": null
	}
	_sel_show_overlay()


func _sel_motion() -> void:
	if _sel == null:
		return
	var raw = _mouse_world()
	var state = String(_sel["state"])
	if state == "marquee":
		var a = _sel["anchor"]
		var p = _snap_point(raw)
		var d = p - a
		if Input.is_key_pressed(KEY_SHIFT):
			var m = max(abs(d.x), abs(d.y))
			d = Vector2(m * sign(d.x if d.x != 0.0 else 1.0), m * sign(d.y if d.y != 0.0 else 1.0))
		if Input.is_key_pressed(KEY_ALT):
			_sel["rect_world"] = Rect2(a - d, d * 2.0).abs()
		else:
			_sel["rect_world"] = Rect2(a, d).abs()
		_sel_show_overlay()
	elif state == "liftwait":
		pass
	elif state == "float" and _sel["drag"] != null:
		var drag = _sel["drag"]
		if String(drag.get("kind", "move")) == "resize":
			_sel_resize_to(raw)
		else:
			var half = _sel["size"] * 0.5
			var new_center = drag["start"] + (raw - drag["grab"])
			# Snap the (unrotated) top-left corner so edges land on the grid.
			var tl = _snap_point(new_center - half)
			_sel["center"] = tl + half
			_sel_update_sprite()
			_sel_show_overlay()


func _sel_release() -> void:
	if _sel == null:
		return
	var state = String(_sel["state"])
	if state == "marquee":
		_sel["copy"] = Input.is_key_pressed(KEY_CONTROL)
		_sel["state"] = "liftwait"
	elif state == "float":
		_sel["drag"] = null
		if bool(_sel.get("move_mode", false)):
			# The Move tool applies on release; an unmoved click restores
			# silently instead of polluting the history.
			_sel_commit_or_restore()


# Lifts the marquee region out of the sketch into a floating sprite. Runs
# from the frame driver once the op queue is idle (the readback must see a
# fully composited texture).
func _sel_lift() -> void:
	var r = _sel["rect_world"]
	var pos = (r.position * _tex_scale).floor()
	var end = ((r.position + r.size) * _tex_scale).ceil()
	pos.x = clamp(pos.x, 0, _tex_size.x - 1)
	pos.y = clamp(pos.y, 0, _tex_size.y - 1)
	end.x = clamp(end.x, pos.x, _tex_size.x)
	end.y = clamp(end.y, pos.y, _tex_size.y)
	var r_tex = Rect2(pos, end - pos)
	if r_tex.size.x < 1 or r_tex.size.y < 1:
		_sel_discard()
		return
	var pre = _readback_a()
	if pre == null:
		_sel_discard()
		return
	_sel_float_from(r_tex, pre, bool(_sel["copy"]), false)


func _sel_float_from(r_tex: Rect2, pre, copy: bool, move_mode: bool, override_img = null, erase_img = null) -> void:
	# override_img: masked content to lift (Contiguous move); erase_img: what
	# to stamp (replace) over the source instead of a full clear, so pixels
	# NOT part of the lifted content are preserved.
	var img = override_img
	if img == null:
		img = pre.get_rect(r_tex)
	var restore_img = pre.get_rect(r_tex)
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	var rw = Rect2(r_tex.position / _tex_scale, r_tex.size / _tex_scale)
	_sel = {
		"state": "float",
		"anchor": Vector2(),
		"rect_world": rw,
		"rect_tex": r_tex,
		"img": img,
		"restore_img": restore_img,
		"erase_img": erase_img,
		"tex": tex,
		"pre": pre,
		"copy": copy,
		"center": rw.position + rw.size * 0.5,
		"size": rw.size,
		"orig_center": rw.position + rw.size * 0.5,
		"orig_size": rw.size,
		"rot": 0.0,
		"drag": null,
		"move_mode": move_mode
	}
	_sel_reset_rotation_slider()
	_sel_make_sprite()
	if not copy:
		if erase_img != null:
			_ops.append({"type": "stamp", "image": erase_img, "tex_rect": r_tex})
		else:
			_ops.append({"type": "clear_rect", "rect": r_tex})
	_sel_show_overlay()


func _sel_make_sprite() -> void:
	_sel_sprite = Sprite.new()
	_sel_sprite.centered = true
	_sel_sprite.texture = _sel["tex"]
	_sel_sprite.scale = _sel_sprite_scale()
	_sel_sprite.position = _sel["center"]
	_sel_sprite.rotation = float(_sel["rot"])
	_sel_sprite.material = _mat_premul
	_root.add_child(_sel_sprite)
	# Keep the overlay and cursor above the floating sprite.
	_root.move_child(_sel_item, _root.get_child_count() - 1)
	_root.move_child(_cursor_item, _root.get_child_count() - 1)


# Rebuilds a floating selection from history data (undo of a commit/delete).
func _sel_float_from_data(sd, pre_full, already_erased: bool = false) -> void:
	_sel_discard()
	var img = sd["img"]
	var tex = ImageTexture.new()
	tex.create_from_image(img, 0)
	var r_tex = sd["rect_tex"]
	var rw = Rect2(r_tex.position / _tex_scale, r_tex.size / _tex_scale)
	_sel = {
		"state": "float",
		"anchor": Vector2(),
		"rect_world": rw,
		"rect_tex": r_tex,
		"img": img,
		"restore_img": sd.get("restore_img", img),
		"erase_img": sd.get("erase_img", null),
		"tex": tex,
		"pre": pre_full,
		"copy": bool(sd["copy"]),
		"center": sd["center"],
		"size": sd["size"],
		"orig_center": rw.position + rw.size * 0.5,
		"orig_size": rw.size,
		"rot": float(sd["rot"]),
		"drag": null,
		"move_mode": false
	}
	if _slider_rotation != null and is_instance_valid(_slider_rotation):
		_sync_ui = true
		_slider_rotation.value = rad2deg(float(_sel["rot"]))
		_sync_ui = false
	_sel_make_sprite()
	if not bool(_sel["copy"]) and not already_erased:
		if _sel["erase_img"] != null:
			_ops.append({"type": "stamp", "image": _sel["erase_img"], "tex_rect": r_tex})
		else:
			_ops.append({"type": "clear_rect", "rect": r_tex})
	_sel_show_overlay()


func _sel_capture_data():
	# The stored geometry is the SOURCE one (not the committed transform):
	# undoing a commit re-floats the selection at its original place, i.e.
	# the undo step semantically undoes the move itself.
	var rw = _sel["rect_world"]
	return {
		"rect_tex": _sel["rect_tex"],
		"img": _sel["img"],
		"restore_img": _sel.get("restore_img", _sel["img"]),
		"erase_img": _sel.get("erase_img", null),
		"center": rw.position + rw.size * 0.5,
		"size": rw.size,
		"rot": 0.0,
		"copy": bool(_sel["copy"])
	}


# Move tool (and Alt+drag from drawing modes): lifts the whole sketch
# content and drags it; the move is applied on release.
func _move_press() -> void:
	if _op_busy > 0 or not _ops.empty():
		_dbg("move press ignored (ops busy)")
		return
	var raw = _mouse_world()
	if _sel_floating():
		var h = _sel_hit_corner(raw)
		if h >= 0:
			_sel_start_resize(h, raw)
			return
		if _sel_point_inside(raw):
			if Input.is_key_pressed(KEY_ALT):
				_sel_duplicate_here()
			_sel["drag"] = {"kind": "move", "grab": raw, "start": _sel["center"]}
			return
		# Clicking beside an existing selection deselects it. Always a
		# commit so undo can re-float this exact selection.
		_sel_commit()
		return
	if _sel != null:
		_sel_discard()
	var pre = _readback_a()
	if pre == null:
		return
	var used = pre.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		return
	# In Move mode, Alt at press time drags a COPY.
	var copy = _mode == MODE_MOVE and Input.is_key_pressed(KEY_ALT)
	if _mode == MODE_MOVE and _move_contiguous:
		_start_flood(pre, raw, copy)
		return
	_sel_float_from(Rect2(used.position, used.size), pre, copy, true)
	_sel["drag"] = {"kind": "move", "grab": raw, "start": _sel["center"]}


# Contiguous-region extraction runs on a background Thread: the scanline
# flood plus the region/remainder buffer split are pure GDScript pixel work
# and can take a second or two on large complex blobs. Running them off the
# main thread keeps DD responsive; the frame driver picks up the result and
# creates the floating selection (starting the drag if the button is still
# held, or leaving it floating if the click was already released).
func _start_flood(pre, world_p: Vector2, copy: bool) -> void:
	if _flood_thread != null:
		return
	var w = int(pre.get_width())
	var h = int(pre.get_height())
	var sx = int(floor(world_p.x * _tex_scale))
	var sy = int(floor(world_p.y * _tex_scale))
	if sx < 0 or sy < 0 or sx >= w or sy >= h:
		return
	var data = pre.get_data()
	if data.size() < w * h * 4:
		return
	if data[(sy * w + sx) * 4 + 3] <= 8:
		_dbg("contiguous: empty pixel at " + str(Vector2(sx, sy)))
		return
	# Keep a main-thread reference on the source buffer for the whole thread
	# lifetime: PoolByteArray copy-on-write refcounting is not thread-safe in
	# Godot 3, and letting the local go out of scope while the worker reads
	# it can free the buffer under its feet (garbage pixels).
	_flood_ctx = {"copy": copy, "pre": pre, "data": data, "t0": OS.get_ticks_msec()}
	_flood_thread = Thread.new()
	_flood_thread.start(self, "_flood_worker", {"data": data, "w": w, "h": h, "sx": sx, "sy": sy})


func _poll_flood() -> void:
	if _flood_thread == null or _flood_thread.is_alive():
		return
	var res = _flood_thread.wait_to_finish()
	_flood_thread = null
	var ctx = _flood_ctx
	_flood_ctx = null
	if res == null or ctx == null:
		return
	if not _tool_active or _mode != MODE_MOVE or _sel != null or _busy():
		return
	var region_img = res["img"]
	var remainder_img = res["remainder"]
	if region_img == null or region_img.get_width() <= 0:
		_dbg("contiguous: worker returned an invalid image, aborting")
		return
	_dbg("contiguous: bbox " + str(res["rect"]) + " in " + str(OS.get_ticks_msec() - int(ctx["t0"])) + " ms")
	_sel_float_from(res["rect"], ctx["pre"], bool(ctx["copy"]), true, region_img, remainder_img)
	if Input.is_mouse_button_pressed(BUTTON_LEFT):
		_sel["drag"] = {"kind": "move", "grab": _mouse_world(), "start": _sel["center"]}


# Pure array work; must not touch the scene tree (runs on the Thread).
func _flood_worker(args):
	var data = args["data"]
	var w = int(args["w"])
	var h = int(args["h"])
	var sx = int(args["sx"])
	var sy = int(args["sy"])
	# CAUTION: PoolByteArray.resize() does NOT zero-initialize its memory in
	# Godot 3 (heap garbage). Image.create() DOES memset its data to zero on
	# the C++ side, so zeroed buffers are obtained through a scratch Image
	# instead of a (multi-second) GDScript clearing loop.
	var vz = Image.new()
	vz.create(w, h, false, Image.FORMAT_L8)
	var visited = vz.get_data()
	var stack = [sy * w + sx]
	visited[sy * w + sx] = 1
	var minx = sx
	var maxx = sx
	var miny = sy
	var maxy = sy
	while not stack.empty():
		var idx = stack.pop_back()
		var y = idx / w
		var x = idx - y * w
		# Expand the scanline left and right.
		var x0 = x
		while x0 > 0 and visited[idx - (x - x0) - 1] == 0 and data[(idx - (x - x0) - 1) * 4 + 3] > 8:
			x0 -= 1
			visited[y * w + x0] = 1
		var x1 = x
		while x1 < w - 1 and visited[y * w + x1 + 1] == 0 and data[(y * w + x1 + 1) * 4 + 3] > 8:
			x1 += 1
			visited[y * w + x1] = 1
		if x0 < minx:
			minx = x0
		if x1 > maxx:
			maxx = x1
		if y < miny:
			miny = y
		if y > maxy:
			maxy = y
		# Queue candidates above and below the span.
		for yy in [y - 1, y + 1]:
			if yy < 0 or yy >= h:
				continue
			for xx in range(x0, x1 + 1):
				var j = yy * w + xx
				if visited[j] == 0 and data[j * 4 + 3] > 8:
					visited[j] = 1
					stack.append(j)
	var bw = maxx - minx + 1
	var bh = maxy - miny + 1
	# Zeroed output buffers (see the note above about resize()): only the
	# non-empty side of each pixel needs to be written.
	var zr = Image.new()
	zr.create(bw, bh, false, Image.FORMAT_RGBA8)
	var region_data = zr.get_data()
	var remainder_data = zr.get_data()
	for yy in range(bh):
		var srow = (miny + yy) * w + minx
		var drow = yy * bw
		for xx in range(bw):
			var si = srow + xx
			var src = si * 4
			var dst = (drow + xx) * 4
			if visited[si] == 1:
				region_data[dst] = data[src]
				region_data[dst + 1] = data[src + 1]
				region_data[dst + 2] = data[src + 2]
				region_data[dst + 3] = data[src + 3]
			elif data[src + 3] != 0:
				remainder_data[dst] = data[src]
				remainder_data[dst + 1] = data[src + 1]
				remainder_data[dst + 2] = data[src + 2]
				remainder_data[dst + 3] = data[src + 3]
	if region_data.size() != bw * bh * 4 or remainder_data.size() != bw * bh * 4:
		print("[SketchTool][DBG] flood worker: buffer size mismatch, aborting")
		return null
	var region_img = Image.new()
	region_img.create_from_data(bw, bh, false, Image.FORMAT_RGBA8, region_data)
	var remainder_img = Image.new()
	remainder_img.create_from_data(bw, bh, false, Image.FORMAT_RGBA8, remainder_data)
	return {"rect": Rect2(minx, miny, bw, bh), "img": region_img, "remainder": remainder_img}


func _sel_corner_points() -> Array:
	var c = _sel["center"]
	var half = _sel["size"] * 0.5
	var rot = float(_sel["rot"])
	var out = []
	for k in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
		out.append(c + k.rotated(rot))
	return out


func _sel_hit_corner(p: Vector2) -> int:
	if not _sel_floating():
		return -1
	var r = _ui_px(12.0)
	var pts = _sel_corner_points()
	for i in range(4):
		if pts[i].distance_to(p) <= r:
			return i
	return -1


func _sel_start_resize(corner: int, raw: Vector2) -> void:
	_sel["drag"] = {
		"kind": "resize",
		"corner": corner,
		"grab": raw,
		"center0": _sel["center"],
		"size0": _sel["size"]
	}


# Resize from a corner handle. Default: the opposite corner stays fixed.
# Shift keeps the aspect ratio; Alt resizes from the center (both combine).
func _sel_resize_to(raw: Vector2) -> void:
	var drag = _sel["drag"]
	var rot = float(_sel["rot"])
	var c0 = drag["center0"]
	var size0 = drag["size0"]
	var half0 = size0 * 0.5
	var signs_list = [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]
	var signs = signs_list[int(drag["corner"])]
	var lp = (raw - c0).rotated(-rot)
	var new_size = size0
	var new_center_local = Vector2()
	if Input.is_key_pressed(KEY_ALT):
		new_size = Vector2(abs(lp.x), abs(lp.y)) * 2.0
		if Input.is_key_pressed(KEY_SHIFT):
			var k = max(new_size.x / max(size0.x, 0.001), new_size.y / max(size0.y, 0.001))
			new_size = size0 * k
	else:
		var fixed = Vector2(-signs.x * half0.x, -signs.y * half0.y)
		var d = lp - fixed
		new_size = Vector2(abs(d.x), abs(d.y))
		if Input.is_key_pressed(KEY_SHIFT):
			var k2 = max(new_size.x / max(size0.x, 0.001), new_size.y / max(size0.y, 0.001))
			new_size = size0 * k2
		var dir_x = signs.x
		if d.x != 0.0:
			dir_x = sign(d.x)
		var dir_y = signs.y
		if d.y != 0.0:
			dir_y = sign(d.y)
		new_center_local = fixed + Vector2(dir_x * new_size.x, dir_y * new_size.y) * 0.5
	new_size.x = max(new_size.x, 2.0)
	new_size.y = max(new_size.y, 2.0)
	_sel["size"] = new_size
	_sel["center"] = c0 + new_center_local.rotated(rot)
	_sel_update_sprite()
	_sel_show_overlay()


# Used for Move-tool releases: applies the floating selection if it was
# actually transformed, otherwise silently puts the pixels back without
# polluting the undo history.
func _sel_is_modified() -> bool:
	if not _sel_floating():
		return false
	var moved = _sel["center"].distance_to(_sel["orig_center"]) > 0.01
	var rotated = abs(float(_sel["rot"])) > 0.0001
	var resized = _sel["size"].distance_to(_sel["orig_size"]) > 0.01
	return moved or rotated or resized


func _sel_commit_or_restore() -> void:
	if not _sel_floating():
		_sel_discard()
		return
	if _sel_is_modified():
		_sel_commit()
	else:
		_sel_cancel()


func _sel_duplicate_here() -> void:
	if not _sel_floating():
		return
	var dup_pre = _readback_a()
	if dup_pre == null:
		return
	var fp = _sel_footprint_rect_tex()
	_ops.append({
		"type": "stamp_rotated",
		"tex": _sel["tex"],
		"center": _sel["center"] * _tex_scale,
		"rot": float(_sel["rot"]),
		"scale": _sel_stamp_scale(),
		"callback": "_after_sel_duplicate",
		"args": [fp, dup_pre]
	})


func _after_sel_duplicate(fp: Rect2, dup_pre) -> void:
	var post = _readback_a()
	if post != null and dup_pre != null:
		_push_history(int(_active_sketch()["uid"]), fp, dup_pre.get_rect(fp), post.get_rect(fp))
	# Maintain the pre-lift invariant used by bypass serialization: the true
	# committed state is now A plus the source region patched back.
	if post != null and _sel_floating():
		var pre2 = post
		if not bool(_sel["copy"]):
			var ri = _sel.get("restore_img", _sel["img"])
			pre2.blit_rect(ri, Rect2(Vector2(), ri.get_size()), _sel["rect_tex"].position)
		_sel["pre"] = pre2
	_mark_dirty()


func _sel_sprite_scale() -> Vector2:
	# World size shown / texture pixel count.
	var r = _sel["rect_tex"]
	var size = _sel["size"]
	return Vector2(size.x / max(r.size.x, 1.0), size.y / max(r.size.y, 1.0))


# Scale of the pasted sprite inside viewport A (texture px space).
func _sel_stamp_scale() -> Vector2:
	var r = _sel["rect_tex"]
	var size = _sel["size"] * _tex_scale
	return Vector2(size.x / max(r.size.x, 1.0), size.y / max(r.size.y, 1.0))


func _sel_update_sprite() -> void:
	if _sel_sprite != null and is_instance_valid(_sel_sprite) and _sel_floating():
		_sel_sprite.position = _sel["center"]
		_sel_sprite.rotation = float(_sel["rot"])
		_sel_sprite.scale = _sel_sprite_scale()
	if _labels_item != null and is_instance_valid(_labels_item):
		_labels_item.update()


func _sel_point_inside(p: Vector2) -> bool:
	if not _sel_floating():
		return false
	var lp = (p - _sel["center"]).rotated(-float(_sel["rot"]))
	var half = _sel["size"] * 0.5
	return abs(lp.x) <= half.x and abs(lp.y) <= half.y


func _clamp_rect_tex(u: Rect2) -> Rect2:
	var pos = u.position.floor()
	var end = (u.position + u.size).ceil()
	pos.x = clamp(pos.x, 0, _tex_size.x - 1)
	pos.y = clamp(pos.y, 0, _tex_size.y - 1)
	end.x = clamp(end.x, pos.x + 1, _tex_size.x)
	end.y = clamp(end.y, pos.y + 1, _tex_size.y)
	return Rect2(pos, end - pos)


# Rotated destination footprint of the floating selection, in texture px.
func _sel_footprint_rect_tex() -> Rect2:
	var c = _sel["center"] * _tex_scale
	var half = _sel["size"] * _tex_scale * 0.5
	var rot = float(_sel["rot"])
	var u = Rect2(c + Vector2(-half.x, -half.y).rotated(rot), Vector2())
	for k in [Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
		u = u.expand(c + k.rotated(rot))
	return _clamp_rect_tex(u.grow(3))


func _sel_union_rect_tex() -> Rect2:
	# Union of the source rect and the rotated destination footprint.
	var u = _sel["rect_tex"]
	var c = _sel["center"] * _tex_scale
	var half = _sel["size"] * _tex_scale * 0.5
	var rot = float(_sel["rot"])
	for k in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
		u = u.expand(c + k.rotated(rot))
	return _clamp_rect_tex(u.grow(3))


# Labels whose center sits in the selection's SOURCE rect follow the
# committed transform (translate, rotate, per-axis scale averaged).
func _sel_apply_labels() -> void:
	if bool(_sel["copy"]):
		return
	var sk = _active_sketch()
	if sk == null or not sk.has("labels"):
		return
	var src = _sel["rect_tex"]
	var src_pos = src.position / _tex_scale
	var src_size = src.size / _tex_scale
	var src_c = src_pos + src_size * 0.5
	# World-space scale: sprite scale is world/tex and embeds 1/_tex_scale.
	var spr_sc = _sel_sprite_scale() * _tex_scale
	var rot = float(_sel["rot"])
	var moved = false
	for lb in sk["labels"]:
		var lp = Vector2(float(lb["x"]), float(lb["y"]))
		if lp.x < src_pos.x or lp.y < src_pos.y \
				or lp.x > src_pos.x + src_size.x or lp.y > src_pos.y + src_size.y:
			continue
		var rel = lp - src_c
		var np = _sel["center"] + Vector2(rel.x * spr_sc.x, rel.y * spr_sc.y).rotated(rot)
		lb["x"] = np.x
		lb["y"] = np.y
		lb["ang"] = fmod(float(lb.get("ang", 0.0)) + rot, TAU)
		lb["s"] = clamp(float(lb.get("s", 1.0)) * (spr_sc.x + spr_sc.y) * 0.5, 0.1, 6.0)
		moved = true
	if moved:
		_lbl_edited()


func _sel_delete_labels() -> void:
	if bool(_sel["copy"]):
		return
	var sk = _active_sketch()
	if sk == null or not sk.has("labels"):
		return
	var src = _sel["rect_tex"]
	var src_pos = src.position / _tex_scale
	var src_size = src.size / _tex_scale
	var removed = false
	for i in range(sk["labels"].size() - 1, -1, -1):
		var lb = sk["labels"][i]
		var lp = Vector2(float(lb["x"]), float(lb["y"]))
		if lp.x >= src_pos.x and lp.y >= src_pos.y \
				and lp.x <= src_pos.x + src_size.x and lp.y <= src_pos.y + src_size.y:
			sk["labels"].remove(i)
			removed = true
	if removed:
		_lbl_edited()


func _sel_commit() -> void:
	if not _sel_floating():
		return
	_sel_apply_labels()
	var union = _sel_union_rect_tex()
	var sd = _sel_capture_data()
	_ops.append({
		"type": "stamp_rotated",
		"tex": _sel["tex"],
		"center": _sel["center"] * _tex_scale,
		"rot": float(_sel["rot"]),
		"scale": _sel_stamp_scale(),
		"callback": "_after_sel_commit",
		"args": [union, _sel["pre"], sd]
	})
	# Keep the floating sprite visible until the composite has rendered.
	_sel_commit_sprite = _sel_sprite
	_sel_sprite = null
	_sel = null
	_sel_show_overlay()
	_sel_reset_rotation_slider()


func _after_sel_commit(union: Rect2, pre_img, sd) -> void:
	if _sel_commit_sprite != null and is_instance_valid(_sel_commit_sprite):
		_sel_commit_sprite.queue_free()
	_sel_commit_sprite = null
	var post = _readback_a()
	if post != null and pre_img != null:
		_push_history(int(_active_sketch()["uid"]), union, pre_img.get_rect(union), post.get_rect(union), sd)
	_mark_dirty()


func _sel_cancel() -> void:
	if _sel == null:
		return
	if _sel_floating() and not bool(_sel["copy"]):
		_ops.append({"type": "stamp", "image": _sel.get("restore_img", _sel["img"]), "tex_rect": _sel["rect_tex"]})
		_mark_dirty()
	_sel_discard()


func _sel_delete() -> void:
	if not _sel_floating():
		_sel_discard()
		return
	if not bool(_sel["copy"]):
		_sel_delete_labels()
		var r = _sel["rect_tex"]
		var sd = _sel_capture_data()
		var post = _readback_a()
		if post != null and _sel["pre"] != null:
			_push_history(int(_active_sketch()["uid"]), r, _sel["pre"].get_rect(r), post.get_rect(r), sd)
		_mark_dirty()
	_sel_discard()


func _sel_discard() -> void:
	if _sel_sprite != null and is_instance_valid(_sel_sprite):
		_sel_sprite.queue_free()
	_sel_sprite = null
	_sel = null
	_sel_show_overlay()
	_sel_reset_rotation_slider()


func _sel_show_overlay() -> void:
	if _sel_item == null or not is_instance_valid(_sel_item):
		return
	_sel_item.visible = _sel != null or _plan_drag != null
	if _sel_item.visible:
		_sel_item.update()


func _sel_reset_rotation_slider() -> void:
	if _slider_rotation != null and is_instance_valid(_slider_rotation):
		_sync_ui = true
		_slider_rotation.value = 0.0
		_sync_ui = false


# Mirrors the floating selection in place (its image flips in local
# space, the committed stamp follows).
func _sel_flip(horizontal: bool) -> void:
	if not _sel_floating():
		return
	var img = _sel.get("img")
	if img == null:
		return
	if horizontal:
		img.flip_x()
	else:
		img.flip_y()
	var tex = _sel.get("tex")
	if tex != null:
		tex.create_from_image(img, 0)
	_sel_update_sprite()
	_sel_show_overlay()


# Rotate / mirror applied to the SELECTION when one floats, to the
# WHOLE SKETCH otherwise (the full canvas is floated, transformed and
# committed on the spot - one undo step).
func _transform_selection_or_all(op: String) -> void:
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	if _busy():
		return
	var whole = not _sel_floating()
	if whole:
		if _stroke != null:
			return
		var pre = _readback_a()
		if pre == null:
			return
		_sel = null
		if _mode != MODE_SELECT:
			_change_mode(MODE_SELECT)
		_sel_float_from(Rect2(Vector2(), _tex_size), pre, false, false)
	if op == "cw":
		_sel_rotate_step(90.0)
	elif op == "ccw":
		_sel_rotate_step(-90.0)
	elif op == "h":
		_sel_flip(true)
	else:
		_sel_flip(false)
	if whole:
		_on_sel_apply_btn()


func _sel_rotate_step(deg: float) -> void:
	if not _sel_floating():
		return
	var v = rad2deg(float(_sel["rot"])) + deg
	v = wrapf(v, -180.0, 180.0)
	if _slider_rotation != null and is_instance_valid(_slider_rotation):
		_slider_rotation.value = v
	else:
		_sel["rot"] = deg2rad(v)
		_sel_update_sprite()
		_sel_show_overlay()


func _on_move_choice_pressed(i: int) -> void:
	if _sync_ui:
		return
	_move_contiguous = i == 1


func _on_sel_rotation_changed(v: float) -> void:
	if _sync_ui:
		return
	if not _sel_floating() and _mode == MODE_SELECT and abs(v) > 0.01 \
			and not _busy() and _stroke == null:
		# Nothing selected: the slider grabs the WHOLE sketch (floated
		# full-canvas; it commits through the usual paths - click
		# outside, mode change).
		var pre = _readback_a()
		if pre != null:
			_sel = null
			_sel_float_from(Rect2(Vector2(), _tex_size), pre, false, false)
	if _sel_floating():
		_sel["rot"] = deg2rad(v)
		_sel_update_sprite()
		_sel_show_overlay()


func _on_sel_apply_btn() -> void:
	_sel_commit()


func _on_sel_cancel_btn() -> void:
	_sel_cancel()


func _on_sel_delete_btn() -> void:
	_sel_delete()


# For sketch switches / rebuilds: the true committed state of the active
# sketch is the pre-lift snapshot, not the on-screen texture with its hole.
func _flush_or_bypass() -> void:
	_last_plan_undo = null
	if _sel_floating() and not bool(_sel["copy"]):
		_serialize_active_from_image(_sel["pre"])
		_save_countdown = -1.0
		_sel_discard()
	else:
		_sel_discard()
		_flush_serialize()


# Line widths are given in screen pixels and scaled by the camera zoom so
# the selection stays clearly visible at any zoom level.
func _ui_px(base: float) -> float:
	var cam = Global.get("Camera")
	if cam != null and is_instance_valid(cam):
		var z = cam.get("zoom")
		if z is Vector2:
			return base * max(z.x, 0.001)
	return base


func _draw_select(item) -> void:
	if _plan_drag != null:
		var pr = _plan_drag["rect"]
		if pr.size.x >= 0.5 and pr.size.y >= 0.5:
			var pw = _ui_px(2.0)
			item.draw_rect(pr, Color(1.0, 0.8, 0.3, 0.12), true)
			item.draw_rect(pr, Color(1, 1, 1, 1.0), false, pw, true)
			item.draw_rect(pr.grow(pw), Color(0, 0, 0, 0.9), false, pw, true)
			# Live size readout in CELLS by the dragged corner (half
			# cells show one decimal - the convert-area pick snaps to
			# the half grid).
			var fnt = _plan_get_font_big()
			if fnt != null:
				var cw2 = pr.size.x / CELL
				var chh = pr.size.y / CELL
				var stxt = ""
				if abs(cw2 - round(cw2)) < 0.01 and abs(chh - round(chh)) < 0.01:
					stxt = str(int(round(cw2))) + " x " + str(int(round(chh)))
				else:
					stxt = ("%.1f x %.1f" % [cw2, chh])
				# The big font is 60 px: scale it down to ~20 px on
				# screen, constant whatever the zoom. Plate sized from
				# the real ascent / descent so nothing clips.
				var tsc = _ui_px(20.0 / 60.0)
				var tw2 = fnt.get_string_size(stxt).x * tsc
				var tasc = fnt.get_ascent() * tsc
				var tdesc = fnt.get_descent() * tsc
				var tp = _mouse_world() + Vector2(_ui_px(22.0), -_ui_px(18.0))
				var pad = _ui_px(6.0)
				item.draw_rect(Rect2(tp + Vector2(-pad, -tasc - pad),
					Vector2(tw2 + pad * 2.0, tasc + tdesc + pad * 2.0)),
					Color(0, 0, 0, 0.78), true)
				item.draw_set_transform(tp, 0.0, Vector2(tsc, tsc))
				# Faux bold, same trick as the room labels.
				item.draw_string(fnt, Vector2(), stxt, Color(1, 1, 1))
				item.draw_string(fnt, Vector2(1.5, 0), stxt, Color(1, 1, 1))
				item.draw_string(fnt, Vector2(0, 1.5), stxt, Color(1, 1, 1))
				item.draw_set_transform(Vector2(), 0.0, Vector2(1, 1))
	if _sel == null:
		return
	var w2 = _ui_px(2.0)
	var state = String(_sel["state"])
	if state == "marquee" or state == "liftwait":
		var r = _sel["rect_world"]
		if r.size.x < 0.5 or r.size.y < 0.5:
			return
		item.draw_rect(r, Color(0.35, 0.65, 1.0, 0.15), true)
		item.draw_rect(r, Color(1, 1, 1, 1.0), false, w2, true)
		item.draw_rect(r.grow(w2), Color(0, 0, 0, 0.9), false, w2, true)
	elif state == "float":
		var c = _sel["center"]
		var half = _sel["size"] * 0.5
		var rot = float(_sel["rot"])
		var pts = []
		for k in [Vector2(-half.x, -half.y), Vector2(half.x, -half.y), Vector2(half.x, half.y), Vector2(-half.x, half.y)]:
			pts.append(c + k.rotated(rot))
		for i in range(4):
			item.draw_line(pts[i], pts[(i + 1) % 4], Color(0, 0, 0, 0.9), _ui_px(4.0), true)
		for i in range(4):
			item.draw_line(pts[i], pts[(i + 1) % 4], Color(1, 1, 1, 1.0), w2, true)
		# Corner handles for visibility.
		var hs = _ui_px(5.0)
		for pnt in pts:
			item.draw_rect(Rect2(pnt - Vector2(hs, hs), Vector2(hs, hs) * 2.0), Color(1, 1, 1, 1.0), true)
			item.draw_rect(Rect2(pnt - Vector2(hs, hs), Vector2(hs, hs) * 2.0), Color(0, 0, 0, 0.9), false, _ui_px(1.0), true)


# Raw input hook (listener _input): intercept Escape while a stroke or a
# selection is active, cancel the action ourselves and consume the event so
# DD's global Escape shortcut doesn't kick us out of the Sketch tool.
func _on_raw_input(node, event) -> void:
	if not _tool_active:
		return
	if not (event is InputEventKey) or not event.pressed:
		return
	if event.scancode == KEY_ESCAPE:
		if _stroke == null and _sel == null and _plan_drag == null:
			return
		if _stroke != null:
			_cancel_stroke()
		elif _sel != null:
			_sel_cancel()
		elif _plan_drag != null:
			_plan_drag = null
			_sel_show_overlay()
		if node != null and is_instance_valid(node) and node.is_inside_tree():
			node.get_tree().set_input_as_handled()
	elif event.scancode == KEY_Z and (event.control or event.command) and not event.shift and not event.echo:
		# Undo with an uncommitted, modified floating selection: cancel the
		# transform in progress instead of letting DD pop a history record
		# underneath it (which would skip an undo step).
		if _sel_is_modified():
			_sel_cancel()
			if node != null and is_instance_valid(node) and node.is_inside_tree():
				node.get_tree().set_input_as_handled()


func _key_just(code: int) -> bool:
	var now = Input.is_key_pressed(code)
	var was = bool(_key_prev.get(code, false))
	_key_prev[code] = now
	return now and not was


# ============================================================================
# Floorplan generator (Plan mode)
# ----------------------------------------------------------------------------
# Grid-cell based. Footprint = union of shrunk rectangles minus subtractive
# notches (originality drives both), largest connected component kept.
# Corridors (1-2 cells wide) cross large buildings and become rooms of their
# own; the remaining regions are BSP-split, fragments merged, and occasional
# 1x1/1x2 closets carved. Doors = spanning tree BFS STARTING FROM THE
# CORRIDOR (rooms radiate from it instead of chaining in enfilade), brown
# marks, with some plain door-sized openings; windows = light blue marks on
# exterior walls (guaranteed at least one, count scales with the building).
# Convex corners get 45-degree bevels or towers drawn as a 270-degree arc
# open toward the building, walls carved to the tower radius. Corner work
# happens BEFORE windows so they never collide.
# ============================================================================

func _plan_press() -> void:
	if _busy():
		return
	var p = _mouse_world()
	# The convert-area pick accepts HALF-cell corners; the generator
	# keeps full cells.
	var st = CELL
	if _cv_area_pick:
		st = CELL * 0.5
	var a = Vector2(round(p.x / st) * st, round(p.y / st) * st)
	_plan_drag = {"anchor": a, "rect": Rect2(a, Vector2())}
	_sel_show_overlay()


func _plan_motion() -> void:
	if _plan_drag == null:
		return
	var p = _mouse_world()
	var st2 = CELL
	if _cv_area_pick:
		st2 = CELL * 0.5
	var b = Vector2(round(p.x / st2) * st2, round(p.y / st2) * st2)
	var a = _plan_drag["anchor"]
	_plan_drag["rect"] = Rect2(a, b - a).abs()
	_sel_show_overlay()


func _plan_release() -> void:
	if _plan_drag == null:
		return
	var r = _plan_drag["rect"]
	_plan_drag = null
	_sel_show_overlay()
	if _cv_area_pick:
		_cv_area_pick = false
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		if r.size.x >= CELL and r.size.y >= CELL:
			_cv_area = r
			if _cvw != null:
				# Settings were captured by the wizard: straight to work.
				_cv_start_vectorize()
			else:
				_plan_convert_to_dd()
		return
	if _shape_area_pick:
		_shape_area_pick = false
		if r.size.x >= CELL and r.size.y >= CELL:
			_shape_save_raster_rect(r)
		return
	if r.size.x >= CELL * 2.0 and r.size.y >= CELL * 2.0:
		_generate_plan(r)
	else:
		_dbg("plan: area too small (needs at least 2x2 cells)")


func _on_plan_whole_map() -> void:
	var wox = Global.World.WoxelDimensions
	var m = CELL * 2.0
	if wox.x < CELL * 9.0 or wox.y < CELL * 9.0:
		m = 0.0
	# Whole-map generation replaces whatever is on the sketch.
	_generate_plan(Rect2(m, m, wox.x - m * 2.0, wox.y - m * 2.0), true)


func _on_plan_reroll() -> void:
	if _stroke != null or _plan_pending != null or _plan_render != null:
		return
	# The last generation replaced the whole sketch: rerolling means doing
	# that again, not restoring the pre image (which held older content).
	if _last_plan_undo != null and bool(_last_plan_undo.get("clear", false)):
		_on_plan_whole_map()
		return
	_plan_wipe_before_regen()
	if _last_plan_area != null:
		_generate_plan(_last_plan_area)
	else:
		_on_plan_whole_map()


# Queues the removal of the last generation (raster restore + labels
# truncation); the queued restore lands before the next pre-image readback.
# Applies a rotation (mode 0) or a mirror (1 horizontal, 2 vertical) to
# the last generation, in place.
func _transform_last(mode: int) -> void:
	if _stroke != null or _plan_pending != null or _plan_render != null:
		return
	if _last_plan_payload == null or _last_plan_area == null or not _nodes_ok():
		return
	var rect = _last_plan_area
	var new_size = rect.size
	if mode == 0 or mode == 3:
		new_size = Vector2(rect.size.y, rect.size.x)
		# Keep the rotated area on the map.
		var wox = Global.World.WoxelDimensions
		if rect.position.x + new_size.x > wox.x or rect.position.y + new_size.y > wox.y:
			rect.position.x = min(rect.position.x, max(0, wox.x - new_size.x))
			rect.position.y = min(rect.position.y, max(0, wox.y - new_size.y))
	var pl = _transform_payload(_last_plan_payload, _last_plan_area, rect.position, mode)
	_plan_wipe_before_regen()
	_last_plan_area = Rect2(rect.position, new_size)
	var margin = 32.0 + CELL * 3.0
	var world_rect = Rect2(_last_plan_area.position - Vector2(margin, margin),
		_last_plan_area.size + Vector2(margin, margin) * 2.0)
	var tex_rect = _clamp_rect_tex(Rect2(world_rect.position * _tex_scale, world_rect.size * _tex_scale))
	if _last_plan_undo != null and bool(_last_plan_undo.get("clear", false)):
		tex_rect = Rect2(Vector2(), _tex_size)
	_plan_pending = {"payload": pl, "rect_tex": tex_rect, "clear": _last_plan_undo != null and bool(_last_plan_undo.get("clear", false))}
	_last_plan_payload = pl


func _tf_point(p: Vector2, src: Rect2, dst_origin: Vector2, mode: int) -> Vector2:
	var r = p - src.position
	if mode == 0:
		r = Vector2(src.size.y - r.y, r.x)
	elif mode == 1:
		r = Vector2(src.size.x - r.x, r.y)
	elif mode == 2:
		r = Vector2(r.x, src.size.y - r.y)
	elif mode == 3:
		# Counter-clockwise quarter turn.
		r = Vector2(r.y, src.size.x - r.x)
	return dst_origin + r


func _transform_payload(pl: Dictionary, src: Rect2, dst_origin: Vector2, mode: int) -> Dictionary:
	var out = {"segs": [], "wins": [], "doors": [], "arcs": [], "labels": [],
		"color": pl.get("color", _color), "w": pl.get("w", _width)}
	for key in ["segs", "wins", "doors"]:
		for sg in pl[key]:
			out[key].append([_tf_point(sg[0], src, dst_origin, mode),
				_tf_point(sg[1], src, dst_origin, mode)])
	for a in pl["arcs"]:
		var na = {"c": _tf_point(a["c"], src, dst_origin, mode), "r": a["r"]}
		var a0 = float(a["a0"])
		var a1 = float(a["a1"])
		if mode == 0:
			na["a0"] = a0 + PI * 0.5
			na["a1"] = a1 + PI * 0.5
		elif mode == 3:
			na["a0"] = a0 - PI * 0.5
			na["a1"] = a1 - PI * 0.5
		elif mode == 1:
			na["a0"] = PI - a1
			na["a1"] = PI - a0
		else:
			na["a0"] = -a1
			na["a1"] = -a0
		out["arcs"].append(na)
	for lb in pl["labels"]:
		var np = _tf_point(Vector2(float(lb["x"]), float(lb["y"])), src, dst_origin, mode)
		var nl = {"t": lb["t"], "x": np.x, "y": np.y, "w": float(lb["w"]), "h": float(lb["h"])}
		if mode == 0 or mode == 3:
			nl["w"] = float(lb["h"])
			nl["h"] = float(lb["w"])
		out["labels"].append(nl)
	return out


const SHAPES_DIR = "user://Sketch_Tool/Saves_Shapes"


func _shapes_dir_ensure() -> void:
	var d = Directory.new()
	d.make_dir_recursive(SHAPES_DIR)


func _shapes_list() -> Array:
	_shapes_dir_ensure()
	var out = []
	var d = Directory.new()
	if d.open(SHAPES_DIR) != OK:
		return out
	d.list_dir_begin(true, true)
	var f = d.get_next()
	while f != "":
		if f.ends_with(".json"):
			out.append(f.substr(0, f.length() - 5))
		f = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


func _shape_read(name: String):
	var f = File.new()
	var path = SHAPES_DIR + "/" + name + ".json"
	if not f.file_exists(path):
		return null
	if f.open(path, File.READ) != OK:
		return null
	var parsed = JSON.parse(f.get_as_text())
	f.close()
	if parsed.error != OK or not (parsed.result is Dictionary):
		return null
	var ser = parsed.result
	if String(ser.get("kind", "vector")) == "raster":
		var img = Image.new()
		if img.load(SHAPES_DIR + "/" + name + ".png") != OK:
			return null
		ser["_img"] = img
	return ser


func _shape_write(name: String, ser: Dictionary) -> void:
	_shapes_dir_ensure()
	var img = ser.get("_img", null)
	var clean = ser.duplicate()
	clean.erase("_img")
	var f = File.new()
	if f.open(SHAPES_DIR + "/" + name + ".json", File.WRITE) == OK:
		f.store_string(JSON.print(clean))
		f.close()
	if img != null:
		img.save_png(SHAPES_DIR + "/" + name + ".png")


func _shape_delete_files(name: String) -> void:
	var d = Directory.new()
	d.remove(SHAPES_DIR + "/" + name + ".json")
	d.remove(SHAPES_DIR + "/" + name + ".png")


func _shape_sanitize(name: String) -> String:
	var bad = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
	for b in bad:
		name = name.replace(b, "_")
	return name.strip_edges()


# ---- name dialog (save & rename) and delete confirmation ----

func _shape_ask_name(default_name: String, action: String) -> void:
	_shape_dialog_action = action
	if _shape_name_dialog == null or not is_instance_valid(_shape_name_dialog):
		_shape_name_dialog = ConfirmationDialog.new()
		_shape_name_dialog.window_title = "Shape Name"
		_shape_name_edit = LineEdit.new()
		_shape_name_edit.rect_min_size = Vector2(220, 24)
		_shape_name_dialog.add_child(_shape_name_edit)
		_shape_name_dialog.connect("confirmed", self, "_on_shape_name_confirmed")
		# Enter in the field validates like OK.
		_shape_name_dialog.register_text_enter(_shape_name_edit)
		# OK and Cancel share the row half/half: the dialog centers its
		# buttons between stretchy spacers, so the spacers go and the
		# buttons expand, with a small gap and side margins.
		var okb = _shape_name_dialog.get_ok()
		var cab = _shape_name_dialog.get_cancel()
		var brow = okb.get_parent()
		if brow != null and brow is HBoxContainer:
			for bc in brow.get_children():
				if bc != okb and bc != cab:
					bc.queue_free()
			brow.set("custom_constants/separation", 10)
		okb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_tool_panel.add_child(_shape_name_dialog)
	_shape_name_edit.text = default_name
	_shape_name_dialog.popup_centered()
	_shape_name_edit.grab_focus()
	_shape_name_edit.select_all()


func _on_shape_name_confirmed() -> void:
	var name = _shape_sanitize(_shape_name_edit.text)
	if name == "":
		return
	if _shape_dialog_action == "rename":
		var old = _shape_selected_name()
		if old == "" or old == name:
			return
		var ser = _shape_read(old)
		if ser == null:
			return
		_shape_write(name, ser)
		_shape_delete_files(old)
	elif _shape_pending_save != null:
		_shape_write(name, _shape_pending_save)
		_shape_pending_save = null
	_shape_refresh_dropdown()


func _shape_selected_name() -> String:
	if _shape_dropdown == null or not is_instance_valid(_shape_dropdown):
		return ""
	var i = _shape_dropdown.selected
	if i < 0:
		return ""
	var t = String(_shape_dropdown.get_item_text(i))
	if t == "---":
		return ""
	return t


func _shape_refresh_dropdown() -> void:
	if _shape_dropdown == null or not is_instance_valid(_shape_dropdown):
		return
	var cur = _shape_selected_name()
	_shape_dropdown.clear()
	_shape_dropdown.add_item("---", 0)
	var names = _shapes_list()
	for i in range(names.size()):
		_shape_dropdown.add_item(String(names[i]), i + 1)
		if String(names[i]) == cur:
			_shape_dropdown.selected = i + 1
	if _shape_dropdown2 != null and is_instance_valid(_shape_dropdown2):
		_shape_dropdown2.clear()
		_shape_dropdown2.add_item("---", 0)
		for i in range(names.size()):
			_shape_dropdown2.add_item(String(names[i]), i + 1)
		_shape_dropdown2.selected = _shape_dropdown.selected


# ---- save menu: last roll / whole sketch / select an area ----

func _on_shape_save_menu() -> void:
	var pm = PopupMenu.new()
	if _mode == MODE_PLAN:
		# The last generated roll is a Plan-tab concept.
		pm.add_item("Last Roll", 0)
	pm.add_item("Whole Sketch", 1)
	pm.add_item("Select Area", 2)
	pm.connect("id_pressed", self, "_on_shape_save_choice")
	pm.connect("popup_hide", pm, "queue_free")
	_tool_panel.add_child(pm)
	pm.popup(Rect2(_tool_panel.get_global_mouse_position(), Vector2(1, 1)))


func _on_shape_save_choice(id: int) -> void:
	if id == 0:
		_shape_save_last_roll()
	elif id == 1:
		_shape_save_raster_rect(null)
	else:
		# Next drag selects the area to save.
		_shape_area_pick = true
		Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		_update_cursor()


func _shape_save_last_roll() -> void:
	if _last_plan_payload == null or _last_plan_area == null:
		return
	var o = _last_plan_area.position
	var ser = {"kind": "vector", "w": _last_plan_payload.get("w", _width),
		"color": _color.to_html(),
		"size": [_last_plan_area.size.x, _last_plan_area.size.y],
		"segs": [], "wins": [], "doors": [], "arcs": [], "labels": []}
	for key in ["segs", "wins", "doors"]:
		for sg in _last_plan_payload[key]:
			ser[key].append([sg[0].x - o.x, sg[0].y - o.y, sg[1].x - o.x, sg[1].y - o.y])
	for a in _last_plan_payload["arcs"]:
		ser["arcs"].append({"cx": a["c"].x - o.x, "cy": a["c"].y - o.y,
			"r": float(a["r"]), "a0": float(a["a0"]), "a1": float(a["a1"])})
	for lb in _last_plan_payload["labels"]:
		ser["labels"].append({"t": lb["t"], "x": float(lb["x"]) - o.x,
			"y": float(lb["y"]) - o.y, "w": float(lb["w"]), "h": float(lb["h"])})
	_shape_pending_save = ser
	_shape_ask_name("Shape " + str(_shapes_list().size() + 1), "save")


# Captures the sketch raster (whole used area when rect_world is null).
# True when the sketch raster holds nothing worth processing.
func _canvas_empty() -> bool:
	var full = _readback_a()
	if full == null:
		return true
	var used = full.get_used_rect()
	return used.size.x < 2 or used.size.y < 2


func _shape_save_raster_rect(rect_world) -> void:
	var full = _readback_a()
	if full == null:
		return
	var tex_rect = null
	if rect_world == null:
		var used = full.get_used_rect()
		if used.size.x < 2 or used.size.y < 2:
			_float_toast("Canvas is empty, snapshot aborted.")
			return
		tex_rect = used
	else:
		tex_rect = _clamp_rect_tex(Rect2(rect_world.position * _tex_scale, rect_world.size * _tex_scale))
	var img = full.get_rect(tex_rect)
	if rect_world != null:
		var used2 = img.get_used_rect()
		if used2.size.x < 2 or used2.size.y < 2:
			_float_toast("Selected area is empty, snapshot aborted.")
			return
	var wsize = tex_rect.size / _tex_scale
	var ser = {"kind": "raster", "size": [wsize.x, wsize.y]}
	ser["_img"] = img
	_shape_pending_save = ser
	_shape_ask_name("Shape " + str(_shapes_list().size() + 1), "save")


func _on_shape_rename() -> void:
	var name = _shape_selected_name()
	if name == "":
		return
	_shape_ask_name(name, "rename")


func _on_shape_delete() -> void:
	var name = _shape_selected_name()
	if name == "":
		return
	if _shape_del_dialog == null or not is_instance_valid(_shape_del_dialog):
		_shape_del_dialog = ConfirmationDialog.new()
		_shape_del_dialog.connect("confirmed", self, "_on_shape_delete_confirmed")
		_tool_panel.add_child(_shape_del_dialog)
	_shape_del_dialog.dialog_text = "Delete shape \"" + name + "\" ?"
	_shape_del_dialog.popup_centered()


func _on_shape_delete_confirmed() -> void:
	var name = _shape_selected_name()
	if name == "":
		return
	_shape_delete_files(name)
	_shape_refresh_dropdown()


func _on_shape_picked(idx: int) -> void:
	_shape_dropdown.select(idx)
	if _shape_dropdown2 != null and is_instance_valid(_shape_dropdown2) \
			and idx < _shape_dropdown2.get_item_count():
		_shape_dropdown2.select(idx)
	_on_shape_load()


func _on_shape_picked2(idx: int) -> void:
	# The mirror dropdown drives the SAME selection state: every shape
	# handler reads _shape_dropdown.
	_on_shape_picked(idx)


func _on_shape_load() -> void:
	var name = _shape_selected_name()
	if name == "":
		return
	var ser = _shape_read(name)
	if ser == null:
		return
	if String(ser.get("kind", "vector")) == "raster":
		_shape_ghost = {"kind": "raster", "img": ser["_img"]}
		_shape_ghost_size = Vector2(float(ser["size"][0]), float(ser["size"][1]))
		_shape_show_ghost()
		return
	var pl = {"segs": [], "wins": [], "doors": [], "arcs": [], "labels": [],
		"color": Color(String(ser.get("color", _color.to_html()))),
		"w": float(ser.get("w", _width))}
	for key in ["segs", "wins", "doors"]:
		for sg in ser[key]:
			pl[key].append([Vector2(float(sg[0]), float(sg[1])), Vector2(float(sg[2]), float(sg[3]))])
	for a in ser["arcs"]:
		pl["arcs"].append({"c": Vector2(float(a["cx"]), float(a["cy"])),
			"r": float(a["r"]), "a0": float(a["a0"]), "a1": float(a["a1"])})
	for lb in ser["labels"]:
		pl["labels"].append({"t": lb["t"], "x": float(lb["x"]), "y": float(lb["y"]),
			"w": float(lb["w"]), "h": float(lb["h"])})
	_shape_ghost = pl
	_shape_ghost_size = Vector2(float(ser["size"][0]), float(ser["size"][1]))
	_shape_show_ghost()


func _on_seg_type(i: int) -> void:
	# Clicking the active sub-tool switches it off.
	if _seg_type == i:
		_seg_type = -1
	else:
		_seg_type = i
	_seg_sync_btns()
	if _seg_type < 0 and _seg_item != null and is_instance_valid(_seg_item):
		_seg_item.visible = false
	_update_mode_buttons()
	_update_panel_visibility()
	_update_cursor()


func _seg_sync_btns() -> void:
	for sb in _seg_btns:
		if is_instance_valid(sb):
			sb.pressed = int(sb.get_meta("seg_tid")) == _seg_type
	for sb in _seg_btns2:
		if is_instance_valid(sb):
			sb.pressed = int(sb.get_meta("seg_tid")) == _seg_type


func _seg_eff_type() -> int:
	if _seg_erase_rmb:
		return 3
	return _seg_type


# Hovered 1-cell segment. The orientation is EXPLICIT (wheel cycles
# h / v / d1 / d2, middle click switches sub-tool); the mouse only picks
# WHERE, snapped to the half grid. Centering the segment on the nearest
# half-lattice anchor makes both diagonal parity families (tile-centered
# and crossing-centered) fall out of the same rounding.
func _seg_hover():
	var m = _mouse_world()
	var a = Vector2()
	var b = Vector2()
	# Wheel order follows the ANGLE: 0 (h), 45 (d1), 90 (v), 135 (d2).
	var orient = ["h", "d1", "v", "d2"][int(clamp(_seg_orient_mode, 0, 3))]
	var line = 0.0
	if orient == "h":
		a = Vector2(round(m.x / CELL * 2.0 - 1.0) * 0.5, round(m.y / CELL * 2.0) * 0.5)
		b = a + Vector2(1.0, 0.0)
		line = a.y
	elif orient == "v":
		a = Vector2(round(m.x / CELL * 2.0) * 0.5, round(m.y / CELL * 2.0 - 1.0) * 0.5)
		b = a + Vector2(0.0, 1.0)
		line = a.x
	elif orient == "d1":
		a = Vector2(round(m.x / CELL * 2.0 - 1.0) * 0.5, round(m.y / CELL * 2.0 - 1.0) * 0.5)
		b = a + Vector2(1.0, 1.0)
		line = a.x - a.y
	else:
		a = Vector2(round(m.x / CELL * 2.0 + 1.0) * 0.5, round(m.y / CELL * 2.0 - 1.0) * 0.5)
		b = a + Vector2(-1.0, 1.0)
		line = a.x + a.y - 1.0
	return {"a": a * CELL, "b": b * CELL, "key": str(a) + "|" + str(b),
		"orient": orient, "line": line}


# Hovered tower: center snapped to the half lattice, radius from the
# alt+wheel setting, opening position from the wheel in 1/8-turn
# notches (the opening itself stays a quarter wide). The CLOSED sweep
# is always 3/4 of a turn starting at the end of the opening (canvas
# angles, y down). Right-click carries the erase flag: same disc, but
# the stamp wipes structure instead of painting the arc.
func _seg_tower_hover() -> Dictionary:
	var m = _mouse_world()
	var g = CELL * 0.5
	var c = Vector2(round(m.x / g) * g, round(m.y / g) * g)
	var a0 = fposmod(float(_seg_tower_orient) * PI * 0.25 + PI * 0.5, TAU)
	return {"c": c, "r": _seg_tower_r * CELL, "a0": a0, "a1": a0 + PI * 1.5,
		"erase": _seg_erase_rmb,
		"key": str(c) + "|" + str(_seg_tower_r) + "|" + str(_seg_tower_orient)}


func _seg_color(alpha: float) -> Color:
	# Plan segments are STRUCTURE: walls are always black (the white
	# default brush color made them invisible and unconvertible), the
	# openings keep their fixed colors. The brush color never leaks in.
	var c = Color(0, 0, 0, 1)
	var t = _seg_eff_type()
	if t == 1:
		c = WINDOW_COLOR
	elif t == 2:
		c = DOOR_COLOR
	elif t == 3:
		c = Color(0.9, 0.25, 0.2)
	c.a = alpha
	return c


func _seg_width() -> float:
	# HARD-CODED sizes, deliberately decoupled from the Width slider
	# (whose value leaked into Plan mode and inflated everything):
	# walls 32, portals 16 on top of the continuous wall, eraser a
	# little wider than the walls it wipes.
	var t = _seg_eff_type()
	if t == 3:
		return 43.0
	if t == 1 or t == 2:
		return 16.0
	return 32.0


# ---- label editing (Move mode) --------------------------------------------

func _lbl_hit(pos: Vector2) -> int:
	# One hit function for every mode: the Text tool's radial test uses
	# the REAL drawn scale (_lbl_metrics); the old copy here read the
	# raw "s" and free texts resized through the panel (px changes, s
	# stays 1) grew phantom radii that shadowed their neighbours.
	return _txt_hit(pos)


func _lbl_edited() -> void:
	if _labels_item != null and is_instance_valid(_labels_item):
		_labels_item.update()
	_write_map_data()


# Text tool hit test: [index, zone] with zone 1 = inside the text
# (rename), 2 = the grab ring around it (move), or [-1, 0].
func _txt_hit(pos: Vector2) -> int:
	var sk = _active_sketch()
	if sk == null or not sk.has("labels"):
		return -1
	var f = _plan_get_font_big()
	if f == null:
		return -1
	var show_gen = _plan_labels or _mode == MODE_TEXT
	# One zone, radial (the proven Move-mode math): anywhere on the
	# text counts.
	var best = -1
	var best_d = 1e12
	for i in range(sk["labels"].size() - 1, -1, -1):
		var lb = sk["labels"][i]
		if not bool(lb.get("free", false)) and not show_gen:
			continue
		var sz = f.get_string_size(String(lb["t"]))
		if sz.x < 1.0:
			continue
		var met = _lbl_metrics(lb, sz)
		var sc = max(0.02, float(met[0]))
		var c = Vector2(float(lb["x"]), float(lb["y"]))
		var rad = max(20.0, sz.x * 0.5 * sc * 0.75 + 10.0)
		var d = c.distance_to(pos)
		if d <= rad and d < best_d:
			best_d = d
			best = i
	return best


# Inline on-map editing: a LineEdit floats right on the label (or the
# click point), like DD's own Text tool - no popup.
func _txt_ask(default_text: String, target) -> void:
	_txt_target = target
	if _txt_edit == null or not is_instance_valid(_txt_edit):
		_txt_edit = LineEdit.new()
		_txt_edit.rect_min_size = Vector2(200, 0)
		_txt_edit.connect("text_entered", self, "_on_txt_entered")
		_txt_edit.connect("focus_exited", self, "_on_txt_focus_lost")
		_txt_edit.connect("gui_input", self, "_on_txt_edit_gui")
		Global.Editor.add_child(_txt_edit)
		_owned.append(_txt_edit)
	var wpos = null
	if target is Vector2:
		wpos = target
	else:
		var sk = _active_sketch()
		if sk != null and target is int and target >= 0 and target < sk.get("labels", []).size():
			var lb = sk["labels"][target]
			wpos = Vector2(float(lb["x"]), float(lb["y"]))
	if wpos == null:
		return
	var spos = wpos
	if _labels_item != null and is_instance_valid(_labels_item):
		spos = _labels_item.get_global_transform_with_canvas().xform(wpos)
	_txt_edit.text = default_text
	_txt_edit.rect_global_position = spos - Vector2(100, 14)
	_txt_edit.visible = true
	_txt_edit.raise()
	_txt_edit.grab_focus()
	_txt_edit.caret_position = default_text.length()
	if _labels_item != null and is_instance_valid(_labels_item):
		_labels_item.update()


func _on_txt_edit_gui(event) -> void:
	if event is InputEventKey and event.pressed and event.scancode == KEY_ESCAPE:
		# Cancel: nothing committed.
		_txt_target = null
		_txt_edit.visible = false
		_txt_close_ms = OS.get_ticks_msec()
		if _labels_item != null and is_instance_valid(_labels_item):
			_labels_item.update()


func _on_txt_focus_lost() -> void:
	# Clicking away commits, exactly like DD's text tool.
	_on_txt_confirmed()


func _on_txt_entered(_t: String) -> void:
	_on_txt_confirmed()


func _on_txt_confirmed() -> void:
	if _txt_target == null:
		return
	var t = _txt_edit.text.strip_edges()
	var tgt = _txt_target
	_txt_target = null
	_txt_edit.visible = false
	_txt_close_ms = OS.get_ticks_msec()
	var sk = _active_sketch()
	if sk == null or t == "":
		if _labels_item != null and is_instance_valid(_labels_item):
			_labels_item.update()
		return
	_txt_target = tgt
	if not sk.has("labels"):
		sk["labels"] = []
	if _txt_target is Vector2:
		sk["labels"].append({"x": _txt_target.x, "y": _txt_target.y, "t": t,
			"ang": deg2rad(_text_rot), "s": 1.0, "free": true, "px": _text_size,
			"col": _text_color.to_html(false)})
		_txt_sel = sk["labels"].size() - 1
	elif _txt_target is int and _txt_target >= 0 and _txt_target < sk["labels"].size():
		sk["labels"][_txt_target]["t"] = t
		_txt_sel = int(_txt_target)
	if _labels_item != null and is_instance_valid(_labels_item):
		_labels_item.visible = _map_data != null and bool(_map_data["visible"])
	_lbl_edited()


func _lbl_wheel(lb: Dictionary, idx: int, up: bool, event) -> void:
	var dirn = 1.0
	if not up:
		dirn = -1.0
	if event.alt:
		var f = 1.05
		if dirn < 0.0:
			f = 1.0 / 1.05
		lb["s"] = clamp(float(lb.get("s", 1.0)) * f, 0.1, 6.0)
	else:
		var step = 10.0
		if Input.is_key_pressed(KEY_Z):
			step = 5.0
			if event.shift:
				step = 1.0
		lb["ang"] = fmod(float(lb.get("ang", 0.0)) + deg2rad(step) * dirn, TAU)
	if idx == _txt_sel:
		# The panel sliders follow the live values.
		_txt_select(idx)
	_lbl_edited()


# Selecting a label loads its properties into the panel (guarded).
func _txt_select(idx: int) -> void:
	_txt_sel = idx
	var sk = _active_sketch()
	if sk == null or idx < 0 or idx >= sk["labels"].size():
		return
	var lb = sk["labels"][idx]
	_sync_ui = true
	if _txt_color_btn != null and is_instance_valid(_txt_color_btn) and lb.has("col"):
		var lc = Color(String(lb["col"]))
		_text_color = lc
		# The palette is a C# widget: try the PascalCase property, the
		# snake_case one, then a setter - whichever exists wins.
		_txt_color_btn.set("Color", lc)
		_txt_color_btn.set("color", lc)
		if _txt_color_btn.has_method("SetColor"):
			_txt_color_btn.call("SetColor", lc)
	if _slider_text_size != null and is_instance_valid(_slider_text_size):
		if bool(lb.get("free", false)):
			_slider_text_size.value = float(lb.get("px", 60.0)) * float(lb.get("s", 1.0))
		else:
			_slider_text_size.value = 60.0 * float(lb.get("s", 1.0))
	if _slider_text_rot != null and is_instance_valid(_slider_text_rot):
		_slider_text_rot.value = rad2deg(float(lb.get("ang", 0.0)))
		_text_rot = _slider_text_rot.value
	_sync_ui = false


func _txt_input(event) -> void:
	if not _tool_active:
		return
	var sk = _active_sketch()
	if sk == null:
		return
	if event is InputEventMouseMotion:
		if _txt_drag != null:
			if not bool(_txt_drag["moved"]) \
					and _mouse_world().distance_to(_txt_drag["press"]) > 4.0:
				_txt_drag["moved"] = true
			if bool(_txt_drag["moved"]):
				var lb = sk["labels"][int(_txt_drag["idx"])]
				var np = _mouse_world() + _txt_drag["off"]
				lb["x"] = np.x
				lb["y"] = np.y
				if _labels_item != null and is_instance_valid(_labels_item):
					_labels_item.update()
			return
		var hv = _txt_hit(_mouse_world())
		if hv != _lbl_hover:
			_lbl_hover = hv
			if _labels_item != null and is_instance_valid(_labels_item):
				_labels_item.update()
		if hv >= 0:
			Input.set_default_cursor_shape(Input.CURSOR_MOVE)
		else:
			Input.set_default_cursor_shape(Input.CURSOR_ARROW)
		return
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				if _txt_edit != null and is_instance_valid(_txt_edit) and _txt_edit.visible:
					# Editing in progress: this click just commits and
					# closes it - no new text, no reselection.
					_on_txt_confirmed()
					return
				if OS.get_ticks_msec() - _txt_close_ms < 250:
					# The click that closed the editor (its focus loss
					# committed a beat before this press arrived): the
					# press is spent, nothing else happens.
					return
				var hit = _txt_hit(_mouse_world())
				if hit >= 0 and event.doubleclick:
					# Double click: edit in place.
					_txt_select(hit)
					_txt_ask(String(sk["labels"][hit]["t"]), hit)
				elif hit >= 0:
					# Click: select; holding and dragging moves.
					var lb2 = sk["labels"][hit]
					_txt_select(hit)
					_txt_drag = {"idx": hit, "moved": false, "press": _mouse_world(),
						"off": Vector2(float(lb2["x"]), float(lb2["y"])) - _mouse_world()}
					if _labels_item != null and is_instance_valid(_labels_item):
						_labels_item.update()
				elif _txt_sel >= 0:
					# Empty click with a selection: deselect only.
					_txt_sel = -1
					if _labels_item != null and is_instance_valid(_labels_item):
						_labels_item.update()
				else:
					_txt_ask("", _mouse_world())
			elif _txt_drag != null:
				var was = bool(_txt_drag["moved"])
				_txt_drag = null
				if was:
					_lbl_edited()
		elif (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) \
				and event.pressed:
			var ti = _lbl_hover
			if ti < 0:
				ti = _txt_sel
			if ti >= 0 and ti < sk.get("labels", []).size():
				_lbl_wheel(sk["labels"][ti], ti,
					event.button_index == BUTTON_WHEEL_UP, event)
	if event is InputEventKey and event.pressed and event.scancode == KEY_DELETE:
		var di = _txt_sel
		if _lbl_hover >= 0:
			di = _lbl_hover
		if di >= 0 and di < sk.get("labels", []).size():
			sk["labels"].remove(di)
			_txt_sel = -1
			_lbl_hover = -1
			_lbl_edited()


# Returns true when the event was consumed by label editing.
func _lbl_input(event) -> bool:
	var sk = _active_sketch()
	if sk == null or not sk.has("labels"):
		return false
	if event is InputEventMouseMotion:
		if _lbl_drag != null:
			var lb = sk["labels"][int(_lbl_drag["idx"])]
			var np = _mouse_world() + _lbl_drag["off"]
			lb["x"] = np.x
			lb["y"] = np.y
			if _labels_item != null and is_instance_valid(_labels_item):
				_labels_item.update()
			return true
		var hv0 = _lbl_hit(_mouse_world())
		if hv0 != _lbl_hover:
			_lbl_hover = hv0
			if _labels_item != null and is_instance_valid(_labels_item):
				_labels_item.update()
		return false
	if event is InputEventMouseButton:
		if event.button_index == BUTTON_LEFT:
			if event.pressed:
				var hit = _txt_hit(_mouse_world())
				if hit < 0 and _txt_sel >= 0:
					# Empty click: the selection dies, the event lives
					# on (segments and moves still get it).
					_txt_sel = -1
					if _labels_item != null and is_instance_valid(_labels_item):
						_labels_item.update()
				if hit >= 0 and event.doubleclick:
					# Rename without switching to the Text tool.
					_txt_ask(String(sk["labels"][hit]["t"]), hit)
					return true
				if hit >= 0:
					var lb2 = sk["labels"][hit]
					_txt_sel = hit
					_lbl_drag = {"idx": hit,
						"off": Vector2(float(lb2["x"]), float(lb2["y"])) - _mouse_world()}
					if _labels_item != null and is_instance_valid(_labels_item):
						_labels_item.update()
					return true
			elif _lbl_drag != null:
				_lbl_drag = null
				_lbl_edited()
				return true
		elif (event.button_index == BUTTON_WHEEL_UP or event.button_index == BUTTON_WHEEL_DOWN) \
				and event.pressed:
			var idx = _lbl_hover
			if _lbl_drag != null:
				idx = int(_lbl_drag["idx"])
			if idx < 0:
				idx = _txt_sel
			if idx >= 0 and idx < sk["labels"].size():
				_lbl_wheel(sk["labels"][idx], idx,
					event.button_index == BUTTON_WHEEL_UP, event)
				return true
	if event is InputEventKey and event.pressed and event.scancode == KEY_DELETE:
		if _lbl_hover >= 0 and _lbl_hover < sk["labels"].size():
			sk["labels"].remove(_lbl_hover)
			_lbl_hover = -1
			_lbl_edited()
			return true
	return false


func _draw_seg_preview(item) -> void:
	var seg_mode = _mode == MODE_PLAN and not _cv_area_pick
	if not seg_mode or not _tool_active or _shape_ghost != null:
		return
	if _seg_type < 0 and not _seg_dragging:
		return
	var col = _seg_color(0.55)
	if _seg_type == 4:
		var th = _seg_batch[0] if _seg_batch.size() > 0 else _seg_tower_hover()
		if bool(th.get("erase", false)):
			# Red wash: this right-click wipes the whole disc (ring
			# included), no arc painted.
			item.draw_circle(th["c"], float(th["r"]) + 16.0, Color(0.9, 0.25, 0.2, 0.25))
		else:
			# Blue wash = the erased disc, solid arc = the wall stroke.
			var wash = Color(UI_BLUE.r, UI_BLUE.g, UI_BLUE.b, 0.18)
			item.draw_circle(th["c"], float(th["r"]), wash)
			item.draw_arc(th["c"], float(th["r"]), float(th["a0"]), float(th["a1"]),
				64, Color(0, 0, 0, 0.55), 32.0, true)
		return
	for sg in _seg_batch:
		item.draw_line(sg[0], sg[1], col, _seg_width(), true)
	var h = _seg_hover()
	if _seg_dragging and _seg_lock != null:
		if String(h["orient"]) != String(_seg_lock["orient"]) \
				or abs(float(h["line"]) - float(_seg_lock["line"])) > 0.01:
			return
	item.draw_line(h["a"], h["b"], col, _seg_width(), true)


func _seg_process(_delta) -> void:
	var seg_mode = _mode == MODE_PLAN and not _cv_area_pick
	if _seg_item != null and is_instance_valid(_seg_item) and seg_mode \
			and _tool_active and (_seg_type >= 0 or _seg_dragging):
		_seg_item.update()


func _sub_ensure_item() -> void:
	if _sub_item == null or not is_instance_valid(_sub_item):
		_sub_item = _make_proxy("_draw_sub_preview", "_sub_process")
		_sub_item.name = "SketchSubtractPreview"
		_root.add_child(_sub_item)
	_sub_item.visible = true


func _sub_process(_delta) -> void:
	if _sub_item == null or not is_instance_valid(_sub_item):
		return
	if _stroke != null and _stroke_dragging and bool(_stroke.get("sub", false)):
		_sub_item.update()
	elif _sub_item.visible:
		_sub_item.visible = false
		_sub_item.update()


# Translucent blue wash over the dragged shape: the visual cue that
# this right-click stroke REMOVES instead of drawing.
func _draw_sub_preview(item) -> void:
	if _stroke == null or not _stroke_dragging or not bool(_stroke.get("sub", false)):
		return
	var r = _stroke["rect"]
	var col = Color(UI_BLUE.r, UI_BLUE.g, UI_BLUE.b, 0.35)
	var line = Color(UI_BLUE.r, UI_BLUE.g, UI_BLUE.b, 0.9)
	var w = max(1.0, float(_stroke["width"]))
	if int(_stroke["mode"]) == MODE_RECT:
		item.draw_rect(r, col, true)
		if r.size.x >= 1.0 and r.size.y >= 1.0:
			item.draw_rect(r, line, false, w, false)
	else:
		var c = r.position + r.size * 0.5
		var pts = PoolVector2Array()
		for i in range(ELLIPSE_SEGMENTS):
			var a = float(i) / float(ELLIPSE_SEGMENTS) * PI * 2.0
			pts.append(c + Vector2(cos(a) * r.size.x * 0.5, sin(a) * r.size.y * 0.5))
		if pts.size() >= 3:
			item.draw_colored_polygon(pts, col)
			var closed = PoolVector2Array(pts)
			closed.append(pts[0])
			item.draw_polyline(closed, line, w, false)
			for p in pts:
				item.draw_circle(p, w * 0.5, line)


func _seg_ensure_item() -> void:
	if _seg_item == null or not is_instance_valid(_seg_item):
		_seg_item = _make_proxy("_draw_seg_preview", "_seg_process")
		_seg_item.name = "SketchSegPreview"
		_root.add_child(_seg_item)
	_seg_item.visible = true


func _seg_push_hovered() -> void:
	if _seg_type == 4:
		# One tower per press: the drag never chains. Right-click rides
		# the same path with the erase flag raised.
		if _seg_batch.empty():
			_seg_batch.append(_seg_tower_hover())
		return
	var h = _seg_hover()
	if String(h["key"]) == _seg_last_key:
		return
	if _seg_lock == null:
		_seg_lock = {"orient": String(h["orient"]), "line": float(h["line"])}
	elif String(h["orient"]) != String(_seg_lock["orient"]) \
			or abs(float(h["line"]) - float(_seg_lock["line"])) > 0.01:
		# The drag stays on its starting line: off-line hovers are ignored
		# instead of spraying parasite segments.
		return
	if _seg_eff_type() == 3 and _seg_batch.size() > 0:
		# Erase hysteresis: half-cell offsets meant the smallest drag
		# jitter appended the neighbouring half segments and widened the
		# erased span; a new segment needs 3/4 cell of real travel.
		var lc = (_seg_batch[_seg_batch.size() - 1][0] + _seg_batch[_seg_batch.size() - 1][1]) * 0.5
		var nc = (h["a"] + h["b"]) * 0.5
		if lc.distance_to(nc) < CELL * 0.75:
			return
	_seg_last_key = String(h["key"])
	_seg_batch.append([h["a"], h["b"]])


func _img_draw_line(img, a: Vector2, b: Vector2, col: Color, w: float, square_ends: bool = false) -> void:
	var x0 = int(max(0, floor(min(a.x, b.x) - w)))
	var x1 = int(min(img.get_width() - 1, ceil(max(a.x, b.x) + w)))
	var y0 = int(max(0, floor(min(a.y, b.y) - w)))
	var y1 = int(min(img.get_height() - 1, ceil(max(a.y, b.y) + w)))
	var hw = w * 0.5
	var v = b - a
	var vl2 = v.length_squared()
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var pnt = Vector2(x + 0.5, y + 0.5)
			if square_ends and vl2 > 0.0:
				# Flat ends: strict band between the two endpoints.
				var tp = (pnt - a).dot(v) / vl2
				if tp < 0.0 or tp > 1.0:
					continue
				if (pnt - (a + v * tp)).length() <= hw:
					img.set_pixel(x, y, col)
			else:
				var q = Geometry.get_closest_point_to_segment_2d(pnt, a, b)
				if q.distance_to(pnt) <= hw:
					img.set_pixel(x, y, col)


func _img_pixel(img, q: Vector2) -> Color:
	if q.x < 0 or q.x >= img.get_width() or q.y < 0 or q.y >= img.get_height():
		return Color(0, 0, 0, 0)
	return img.get_pixel(int(q.x), int(q.y))


func _col_close(a: Color, b: Color) -> bool:
	return abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b) <= 0.4


# Erases a band with flat ends. Probing happens on the UNMODIFIED probe
# image (clearing pixels must not blind later probes). A pixel survives
# when an opaque, same-colored continuation exists on BOTH sides of it in
# one of three directions (perpendicular or either 45): straight and
# diagonal crossings both hold, while foreign-colored door/window caps on
# a wall are cleared. Extensions past the endpoints kill orphan round
# caps, with a guard color protecting a continuing wall there.
func _img_erase_line(img, probe, a: Vector2, b: Vector2, w: float, ext_a: float, ext_b: float, guard_a = null, guard_b = null) -> Dictionary:
	var v = b - a
	var vl = v.length()
	if vl <= 0.0:
		return {"kept": 0, "repair": 0, "guard": 0, "cleared": 0, "kept_pos": []}
	var vn = v / vl
	var pn = Vector2(-vn.y, vn.x)
	var hw = w * 0.5
	var ea = a - vn * ext_a
	var eb = b + vn * ext_b
	var x0 = int(max(0, floor(min(ea.x, eb.x) - w)))
	var x1 = int(min(img.get_width() - 1, ceil(max(ea.x, eb.x) + w)))
	var y0 = int(max(0, floor(min(ea.y, eb.y) - w)))
	var y1 = int(min(img.get_height() - 1, ceil(max(ea.y, eb.y) + w)))
	var el = vl + ext_a + ext_b
	var stats = {"kept": 0, "repair": 0, "guard": 0, "cleared": 0, "kept_pos": []}
	var dirs = [pn, (pn + vn).normalized(), (pn - vn).normalized()]
	for di in range(dirs.size()):
		if dirs[di].dot(pn) < 0.0:
			dirs[di] = -dirs[di]
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var pnt = Vector2(x + 0.5, y + 0.5)
			var tp = (pnt - ea).dot(vn)
			if tp < 0.0 or tp > el:
				continue
			var dpn = (pnt - ea).dot(pn)
			if abs(dpn) > hw:
				continue
			var pc = _img_pixel(probe, pnt)
			var kept = false
			var repair = null
			if pc.a > 0.4:
				# A crossing stroke must pass THROUGH the pixel AND exit
				# the band on BOTH sides. A raw length test still kept the
				# diagonal roots at the corners: their run merged with the
				# junction blob and got long enough, but it only ever
				# exits on the wall side, never on the interior side.
				# Long-run threshold: a stroke reaching this far on ONE
				# side clearly extends well beyond the band (a wall ending
				# at the corner), while the diagonal only has short chords
				# in the tested directions. The erased element itself can
				# never use this rescue: its own axis is not among dirs.
				var long_need = hw * 2.0 + 10.0
				for di2 in range(dirs.size()):
					var dirn = dirs[di2]
					var comp = max(0.35, dirn.dot(pn))
					var need_p = (hw - dpn) / comp + 2.0
					var need_m = (hw + dpn) / comp + 2.0
					var reach_p = 0.0
					for st in range(1, 40):
						var qc = _img_pixel(probe, pnt + dirn * float(st))
						if qc.a <= 0.4 or not _col_close(pc, qc):
							break
						reach_p = float(st)
					var reach_m = 0.0
					for st in range(1, 40):
						var qc2 = _img_pixel(probe, pnt - dirn * float(st))
						if qc2.a <= 0.4 or not _col_close(pc, qc2):
							break
						reach_m = float(st)
					# One-sided long-run rescue ONLY along the pure
					# perpendicular. Allowing it on the +-45 probes kept
					# the miter overhang of the axis walls when the
					# window sits on a one-cell chamfer (the axis wall
					# runs exactly along the 45 probe there): the
					# leftover ticks at both corners.
					if (reach_p >= need_p and reach_m >= need_m) \
							or (di2 == 0 and (reach_p >= long_need or reach_m >= long_need)):
						kept = true
						break
				if not kept:
					# Foreign-colored cap painted over a crossing wall:
					# both perpendicular exits opaque and mutually equal
					# while the pixel itself differs = repaint the wall.
					var comp = max(0.35, dirs[0].dot(pn))
					for extra in [2.0, 4.5]:
						var qp = pnt + dirs[0] * ((hw - dpn + extra) / comp)
						var qm = pnt - dirs[0] * ((hw + dpn + extra) / comp)
						var c1 = _img_pixel(probe, qp)
						var c2 = _img_pixel(probe, qm)
						if c1.a > 0.4 and c2.a > 0.4 and _col_close(c1, c2) \
								and not _col_close(pc, c1):
							repair = c1
							break
			if kept:
				if pc.a > 0.4:
					stats["kept"] = int(stats["kept"]) + 1
					if stats["kept_pos"].size() < 8:
						stats["kept_pos"].append([round(tp - ext_a), round(dpn)])
				continue
			var guard = null
			if tp < ext_a:
				guard = guard_a
			elif tp > ext_a + vl:
				guard = guard_b
			if guard != null and _col_close(pc, guard):
				stats["guard"] = int(stats["guard"]) + 1
				continue
			if repair != null:
				stats["repair"] = int(stats["repair"]) + 1
				img.set_pixel(x, y, repair)
				continue
			if pc.a > 0.4:
				stats["cleared"] = int(stats["cleared"]) + 1
			img.set_pixel(x, y, Color(0, 0, 0, 0))
	return stats


# Records manual segment activity as vector data in the active sketch:
# draws append {t, ax..by}; erases prune covered journal entries and pile
# up as erasures for the conversion to subtract from the generated plan.
func _seg_journal_record(t: int, batch: Array) -> void:
	var sk = _active_sketch()
	if sk == null:
		return
	if not sk.has("seg_journal"):
		sk["seg_journal"] = []
	if not sk.has("seg_erase"):
		sk["seg_erase"] = []
	for sg in batch:
		var a = sg[0]
		var b = sg[1]
		if t == 3:
			sk["seg_erase"].append({"ax": a.x, "ay": a.y, "bx": b.x, "by": b.y})
			# Prune journal entries whose center falls inside this band.
			var i = sk["seg_journal"].size() - 1
			while i >= 0:
				var e = sk["seg_journal"][i]
				var c = Vector2((float(e["ax"]) + float(e["bx"])) * 0.5,
					(float(e["ay"]) + float(e["by"])) * 0.5)
				if _cv_on_band(c, a, b, CELL * 0.35):
					sk["seg_journal"].remove(i)
				i -= 1
		else:
			sk["seg_journal"].append({"t": t, "ax": a.x, "ay": a.y, "bx": b.x, "by": b.y})
	_write_map_data()


# True when point c sits within the band of half-width hw around [a, b].
func _cv_on_band(c: Vector2, a: Vector2, b: Vector2, hw: float) -> bool:
	var v = b - a
	var vl = v.length()
	if vl <= 0.0:
		return false
	var vn = v / vl
	var tp = (c - a).dot(vn)
	if tp < -hw or tp > vl + hw:
		return false
	return abs((c - a).dot(Vector2(-vn.y, vn.x))) <= hw


# Splits [a, b] by the collinear erasure bands: returns surviving pieces.
func _cv_subtract(a: Vector2, b: Vector2, erasures: Array) -> Array:
	var pieces = [[a, b]]
	for e in erasures:
		var ea = Vector2(float(e["ax"]), float(e["ay"]))
		var eb = Vector2(float(e["bx"]), float(e["by"]))
		var ev = eb - ea
		var el = ev.length()
		if el <= 0.0:
			continue
		var en = ev / el
		var out = []
		for pc in pieces:
			var v = pc[1] - pc[0]
			var vl = v.length()
			if vl <= 1.0:
				continue
			var vn = v / vl
			# Collinear and on (nearly) the same line?
			if abs(vn.cross(en)) > 0.05 \
					or abs((pc[0] - ea).dot(Vector2(-en.y, en.x))) > CELL * 0.35:
				out.append(pc)
				continue
			var t0 = (ea - pc[0]).dot(vn)
			var t1 = (eb - pc[0]).dot(vn)
			var lo = min(t0, t1)
			var hi = max(t0, t1)
			lo = max(lo, 0.0)
			hi = min(hi, vl)
			if hi - lo <= 1.0:
				out.append(pc)
				continue
			if lo > 1.0:
				out.append([pc[0], pc[0] + vn * lo])
			if hi < vl - 1.0:
				out.append([pc[0] + vn * hi, pc[1]])
		pieces = out
	return pieces


# Eraser application with endpoint handling: a free endpoint gets a full
# extension (orphan cap cleanup); a continuing wall gets a color-guarded
# one, proven collinear by three axis samples, so door/window caps die
# without notching the wall.
func _seg_do_erase(post, pre, la: Vector2, lb: Vector2, wpx: float, cap: float) -> void:
	var vn2 = (lb - la).normalized()
	var ext_a = cap
	var ext_b = cap
	var guard_a = null
	var guard_b = null
	var base_g = wpx * 0.5 + 2.0
	var ga_ok = true
	var ga_col = null
	for gk in [0.0, 4.0, 8.0]:
		var cg = _img_pixel(pre, la - vn2 * (base_g + gk))
		if cg.a <= 0.5 or (ga_col != null and not _col_close(ga_col, cg)):
			ga_ok = false
			break
		if ga_col == null:
			ga_col = cg
	if ga_ok:
		guard_a = ga_col
	var gb_ok = true
	var gb_col = null
	for gk in [0.0, 4.0, 8.0]:
		var cg2 = _img_pixel(pre, lb + vn2 * (base_g + gk))
		if cg2.a <= 0.5 or (gb_col != null and not _col_close(gb_col, cg2)):
			gb_ok = false
			break
		if gb_col == null:
			gb_col = cg2
	if gb_ok:
		guard_b = gb_col
	var _est = _img_erase_line(post, pre, la, lb, wpx, ext_a, ext_b, guard_a, guard_b)


func _seg_commit() -> void:
	if _seg_batch.empty() or not _nodes_ok():
		_seg_batch = []
		return
	if _seg_batch[0] is Dictionary:
		var tw = _seg_batch[0]
		_seg_batch = []
		_seg_tower_commit(tw)
		return
	var mn3 = Vector2(1e12, 1e12)
	var mx3 = Vector2(-1e12, -1e12)
	for sg in _seg_batch:
		for pnt in sg:
			mn3.x = min(mn3.x, pnt.x)
			mn3.y = min(mn3.y, pnt.y)
			mx3.x = max(mx3.x, pnt.x)
			mx3.y = max(mx3.y, pnt.y)
	var margin = _seg_width() + 24.0 / _tex_scale
	var wr = Rect2(mn3 - Vector2(margin, margin), mx3 - mn3 + Vector2(margin, margin) * 2.0)
	var rect = _clamp_rect_tex(Rect2(wr.position * _tex_scale, wr.size * _tex_scale))
	var full = _readback_a()
	if full == null:
		_seg_batch = []
		return
	var erasing = _seg_eff_type() == 3
	_seg_journal_record(_seg_eff_type(), _seg_batch)
	var pre = full.get_rect(rect)
	var post = pre.duplicate()
	# BOTH images must be locked: the eraser probes pre with get_pixel and
	# an unlocked access hard-crashes DD's Mono build without any log.
	pre.lock()
	post.lock()
	var col = _seg_color(1.0)
	var wpx = _seg_width() * _tex_scale
	if erasing:
		# +4px absolute: covers the AA fringe whatever the stroke width.
		wpx += 4.0
	var cap = 32.0 * _tex_scale * 0.5 + 3.0
	for sg in _seg_batch:
		var la = sg[0] * _tex_scale - rect.position
		var lb = sg[1] * _tex_scale - rect.position
		if erasing:
			_seg_do_erase(post, pre, la, lb, wpx, cap)
		else:
			# Doors and windows now sit ON TOP of the wall (half its
			# width) instead of replacing it: no more eraser here. The
			# old erase-then-paint chewed the miter joins on one-cell
			# chamfers and left the wall disconnected at the corners.
			_img_draw_line(post, la, lb, col, wpx, true)
	post.unlock()
	pre.unlock()
	_seg_batch = []
	_ops.append({"type": "stamp", "image": post, "tex_rect": rect})
	_push_history(int(_active_sketch()["uid"]), rect, pre, post)
	_mark_dirty()


# Stamps one tower: every STRUCTURE pixel (wall black, window / door
# colors) strictly inside the circle is erased - colored annotations
# are left alone - then the 3/4 arc is painted at wall width. Walls
# crossing the rim die exactly on the circle, the open quadrant stays
# a bare mouth. Raster is the single source of truth (the converter's
# circle pass rebuilds the arc), so no journal entry is needed.
func _seg_tower_commit(tw: Dictionary) -> void:
	var c = tw["c"]
	var r = float(tw["r"])
	var hw = 16.0
	var margin = hw * 2.0 + 4.0 + 24.0 / _tex_scale
	var wr = Rect2(c - Vector2(r + margin, r + margin),
		Vector2((r + margin) * 2.0, (r + margin) * 2.0))
	var rect = _clamp_rect_tex(Rect2(wr.position * _tex_scale, wr.size * _tex_scale))
	var full = _readback_a()
	if full == null:
		return
	var pre = full.get_rect(rect)
	var post = pre.duplicate()
	pre.lock()
	post.lock()
	var ct = c * _tex_scale - rect.position
	var rt = r * _tex_scale
	var hwt = hw * _tex_scale
	# Towers are WALLS: always black, whatever the brush color.
	var col = Color(0, 0, 0, 1)
	var wipe = bool(tw.get("erase", false))
	var a0 = float(tw["a0"])
	var span = float(tw["a1"]) - a0
	var x0 = int(max(0, floor(ct.x - rt - hwt - 2.0)))
	var x1 = int(min(post.get_width() - 1, ceil(ct.x + rt + hwt + 2.0)))
	var y0 = int(max(0, floor(ct.y - rt - hwt - 2.0)))
	var y1 = int(min(post.get_height() - 1, ceil(ct.y + rt + hwt + 2.0)))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var pv = Vector2(x + 0.5, y + 0.5)
			var d = pv.distance_to(ct)
			if wipe:
				# Right-click: wipe structure over the whole disc, ring
				# included (+2 px for the AA fringe), paint nothing.
				if d <= rt + hwt + 2.0:
					var pw = pre.get_pixel(x, y)
					if pw.a > 0.5 and _seg_tower_is_structure(pw):
						post.set_pixel(x, y, Color(0, 0, 0, 0))
				continue
			if d < rt - 0.5:
				var pc = pre.get_pixel(x, y)
				if pc.a > 0.5 and _seg_tower_is_structure(pc):
					post.set_pixel(x, y, Color(0, 0, 0, 0))
			if abs(d - rt) <= hwt:
				# Wrap-safe sweep test (same trap as _plan_on_arc: a
				# pixel on the a0 lip can land at TAU - epsilon).
				var dd = fposmod((pv - ct).angle() - a0, TAU)
				if dd <= span + 0.02 or dd >= TAU - 0.02:
					post.set_pixel(x, y, col)
	post.unlock()
	pre.unlock()
	_ops.append({"type": "stamp", "image": post, "tex_rect": rect})
	_push_history(int(_active_sketch()["uid"]), rect, pre, post)
	_mark_dirty()


# Structure = what the converter recognizes: near-black walls and the
# window / door stroke colors. Anything else is an annotation.
func _seg_tower_is_structure(pc: Color) -> bool:
	if pc.r + pc.g + pc.b < 0.706:
		return true
	var dw = abs(pc.r - WINDOW_COLOR.r) + abs(pc.g - WINDOW_COLOR.g) + abs(pc.b - WINDOW_COLOR.b)
	if dw < 0.353:
		return true
	var dd = abs(pc.r - DOOR_COLOR.r) + abs(pc.g - DOOR_COLOR.g) + abs(pc.b - DOOR_COLOR.b)
	return dd < 0.353


func _shape_show_ghost() -> void:
	if _ghost_item == null or not is_instance_valid(_ghost_item):
		_ghost_item = _make_proxy("_draw_ghost", "_ghost_process")
		_ghost_item.name = "SketchShapeGhost"
		_root.add_child(_ghost_item)
	_ghost_item.visible = true
	_ghost_item.update()


func _ghost_process(_delta) -> void:
	if _shape_ghost != null and _ghost_item != null and is_instance_valid(_ghost_item):
		_ghost_item.update()


func _shape_eff_size() -> Vector2:
	# AABB of the rotated+scaled shape.
	var sc = float(_shape_ghost.get("scale", 1.0))
	var ang = float(_shape_ghost.get("ang", 0.0))
	var b = _shape_ghost_size * sc
	return Vector2(abs(b.x * cos(ang)) + abs(b.y * sin(ang)),
		abs(b.x * sin(ang)) + abs(b.y * cos(ang)))


# Offset of a base-space point (0..size) from the shape CENTER, rotated and
# scaled. Center-based so zooming keeps the shape anchored under the mouse.
func _shape_tf(p: Vector2) -> Vector2:
	var ang = float(_shape_ghost.get("ang", 0.0))
	return ((p - _shape_ghost_size * 0.5) * float(_shape_ghost.get("scale", 1.0))).rotated(ang)


func _shape_center() -> Vector2:
	var m = _mouse_world()
	if Global.Editor.get("IsSnapping") != true:
		return m
	var g = CELL * 0.5
	return Vector2(round(m.x / g) * g, round(m.y / g) * g)


func _draw_ghost(item) -> void:
	if _shape_ghost == null:
		return
	var c = _shape_center()
	var sc = float(_shape_ghost.get("scale", 1.0))
	var ang = float(_shape_ghost.get("ang", 0.0))
	if String(_shape_ghost.get("kind", "vector")) == "raster":
		if not _shape_ghost.has("_tex_cache"):
			var t = ImageTexture.new()
			t.create_from_image(_shape_ghost["img"], 0)
			_shape_ghost["_tex_cache"] = t
		var base = _shape_ghost_size * sc
		item.draw_set_transform(c, ang, Vector2(1, 1))
		item.draw_texture_rect(_shape_ghost["_tex_cache"], Rect2(-base * 0.5, base),
			false, Color(1, 1, 1, 0.45))
		item.draw_set_transform(Vector2(), 0.0, Vector2(1, 1))
		return
	var col = Color(_shape_ghost["color"])
	col.a = 0.45
	var w = float(_shape_ghost["w"]) * sc
	for sg in _shape_ghost["segs"]:
		item.draw_line(c + _shape_tf(sg[0]), c + _shape_tf(sg[1]), col, w, true)
	for a in _shape_ghost["arcs"]:
		item.draw_arc(c + _shape_tf(a["c"]), float(a["r"]) * sc,
			float(a["a0"]) + ang, float(a["a1"]) + ang, 48, col, w, true)
	var wc = Color(0.45, 0.75, 1.0, 0.45)
	for sg in _shape_ghost["wins"]:
		item.draw_line(c + _shape_tf(sg[0]), c + _shape_tf(sg[1]), wc, w, true)
	var dc = Color(0.55, 0.35, 0.16, 0.45)
	for sg in _shape_ghost["doors"]:
		item.draw_line(c + _shape_tf(sg[0]), c + _shape_tf(sg[1]), dc, w, true)


func _shape_cancel() -> void:
	_shape_ghost = null
	if _ghost_item != null and is_instance_valid(_ghost_item):
		_ghost_item.visible = false


func _shape_stamp() -> void:
	if _shape_ghost == null or _stroke != null or _plan_pending != null or _plan_render != null:
		return
	var c = _shape_center()
	var sc = float(_shape_ghost.get("scale", 1.0))
	var ang = float(_shape_ghost.get("ang", 0.0))
	var eff = _shape_eff_size()
	var o = c - eff * 0.5
	if String(_shape_ghost.get("kind", "vector")) == "raster":
		var plr = {"segs": [], "wins": [], "doors": [], "arcs": [], "labels": [],
			"color": _color, "w": _width,
			"img": _shape_ghost["img"], "img_center": c,
			"img_base": _shape_ghost_size * sc, "img_rot": ang}
		_last_plan_area = Rect2(o, eff)
		var m2 = CELL
		var wr2 = Rect2(o - Vector2(m2, m2), eff + Vector2(m2, m2) * 2.0)
		var tr2 = _clamp_rect_tex(Rect2(wr2.position * _tex_scale, wr2.size * _tex_scale))
		_plan_pending = {"payload": plr, "rect_tex": tr2, "clear": false}
		_last_plan_payload = null
		_shape_cancel()
		return
	var pl = {"segs": [], "wins": [], "doors": [], "arcs": [], "labels": [],
		"color": _shape_ghost["color"], "w": float(_shape_ghost["w"]) * sc}
	for key in ["segs", "wins", "doors"]:
		for sg in _shape_ghost[key]:
			pl[key].append([c + _shape_tf(sg[0]), c + _shape_tf(sg[1])])
	for a in _shape_ghost["arcs"]:
		pl["arcs"].append({"c": c + _shape_tf(a["c"]), "r": float(a["r"]) * sc,
			"a0": float(a["a0"]) + ang, "a1": float(a["a1"]) + ang})
	var swap_lb = int(round(fmod(abs(ang), PI) / (PI * 0.5))) % 2 == 1
	for lb in _shape_ghost["labels"]:
		var lp = c + _shape_tf(Vector2(float(lb["x"]), float(lb["y"])))
		var lw = float(lb["w"]) * sc
		var lh = float(lb["h"]) * sc
		if swap_lb:
			var tmp = lw
			lw = lh
			lh = tmp
		pl["labels"].append({"t": lb["t"], "x": lp.x, "y": lp.y, "w": lw, "h": lh})
	_last_plan_area = Rect2(o, eff)
	var margin = float(pl["w"]) + CELL * 3.0
	var world_rect = Rect2(o - Vector2(margin, margin), _shape_ghost_size + Vector2(margin, margin) * 2.0)
	var tex_rect = _clamp_rect_tex(Rect2(world_rect.position * _tex_scale, world_rect.size * _tex_scale))
	_plan_pending = {"payload": pl, "rect_tex": tex_rect, "clear": false}
	_last_plan_payload = pl
	_shape_cancel()


func _on_plan_rotate_ccw() -> void:
	_transform_last(3)


func _on_plan_rotate() -> void:
	_transform_last(0)


func _on_plan_sym_h() -> void:
	_transform_last(1)


func _on_plan_sym_v() -> void:
	_transform_last(2)


# ============================================================================
# Raster vectorization for Convert to DD Walls: everything opaque on the
# sketch converts; pixels matching the exact door/window colors become
# portal holes, every other color is a wall.
# ============================================================================

# Overlapping pillars collapse to ONE: slightly offset junction picks
# (a T pass and a chain-end pass can land 30-60 px apart) keep the
# pillar sitting on a half-grid snap point when one is, otherwise the
# UNDERMOST one (created first, drawn below). Losers are freed before
# the undo record snapshots anything.
func _cv_pillar_overlap_pass(made_props: Array) -> Array:
	var kept = []
	for prop in made_props:
		if prop == null or not is_instance_valid(prop):
			continue
		var replaced = false
		var dropped = false
		for ki in range(kept.size()):
			var k = kept[ki]
			# Junction picks land within ~a quarter cell of each other
			# whatever the pillar size: a small pillar (scaled near the
			# wall width) must not shrink the merge radius under that.
			var thr = max(64.0, 0.5 * min(_cv_pillar_span(prop), _cv_pillar_span(k)))
			if prop.position.distance_to(k.position) >= thr:
				continue
			if _cv_pillar_snapped(prop.position) and not _cv_pillar_snapped(k.position):
				# The newcomer sits on the lattice: it wins the spot.
				_cv_pillar_free(k)
				kept[ki] = prop
				replaced = true
			else:
				# Snapped incumbent, or neither snapped: the UNDERMOST
				# (earlier) one stays.
				_cv_pillar_free(prop)
				dropped = true
			break
		if not replaced and not dropped:
			kept.append(prop)
	return kept


func _cv_pillar_span(prop) -> float:
	var tx = prop.get("Texture")
	if tx != null and tx is Texture:
		var sz = tx.get_size()
		return max(sz.x, sz.y) * abs(prop.scale.x)
	return 128.0


func _cv_pillar_snapped(p: Vector2) -> bool:
	var g = CELL * 0.5
	return abs(p.x - round(p.x / g) * g) <= 2.0 \
		and abs(p.y - round(p.y / g) * g) <= 2.0


func _cv_pillar_free(prop) -> void:
	if prop == null or not is_instance_valid(prop):
		return
	Global.World.Level.Objects.RemoveFromSearchTable(prop)
	prop.queue_free()


func _cv_pillar_setup(prop) -> void:
	if _cvw == null:
		return
	prop.HasShadow = bool(_cvw.get("shadow", true))
	if bool(_cvw.get("pillar_rand", false)):
		prop.rotation = deg2rad(90.0 * float(randi() % 4))
		if randi() % 2 == 0:
			prop.scale = Vector2(-1, 1)


# All selected pillar styles resolved to real textures (multi-select).
func _cvw_pillar_multi() -> Array:
	var out = []
	var il = _cvw_lists.get("pillar")
	if il == null or not is_instance_valid(il):
		return out
	var sel = il.get_selected_items()
	if sel.size() <= 1:
		var one = _cvw_sel_tex("pillar", false)
		if one != null:
			out.append(one)
		return out
	# Selected reads the FIRST selected item only: walk the selection by
	# single-selecting each entry, then restore the multi-selection.
	for i in sel:
		il.select(int(i))
		var t = il.Selected
		if t != null:
			out.append(t)
	for i2 in range(sel.size()):
		il.select(int(sel[i2]), i2 == 0)
	return out


func _cv_pick_pillar_tex():
	var arr = _cvw.get("pillar_texs", [])
	if arr is Array and arr.size() > 0:
		return arr[randi() % arr.size()]
	return _cvw.get("pillar_tex")


func _cvw_portal_tex(cls: int):
	if _cvw == null:
		return null
	if cls == 2 and not bool(_cvw.get("use_wins", true)):
		return null
	if cls != 2 and not bool(_cvw.get("use_doors", true)):
		return null
	var arr = _cvw.get("win_texs" if cls == 2 else "door_texs", [])
	if arr is Array and arr.size() > 0:
		return arr[randi() % arr.size()]
	if cls == 2:
		return _cvw.get("win_tex")
	return _cvw.get("door_tex")


# Every selected texture of a portal page, through the per-index
# resolver (search filters remap indices; entry 0 is the texture-less
# X portal and contributes null = skipped).
func _cvw_portal_multi(key: String) -> Array:
	var out = []
	var il = _cvw_lists.get(key)
	if il == null or not is_instance_valid(il):
		return out
	for i in il.get_selected_items():
		var oi = _cvw_sel_orig_at(il, int(i))
		if oi <= 0:
			continue
		var t = _cvw_item_tex(key, il, oi)
		if t != null:
			out.append(t)
	return out


# ---- Conversion wizard -----------------------------------------------------
# 1 wall (+ shadows/bevel/pillars) -> [2 pillar] -> 3 window -> 4 door.

# EnlargeUI (DD Preferences) swaps the whole theme for a larger-font
# one on restart, so config.ini matches the LIVE theme (except during
# the single pre-restart session, which is harmless). Everything we
# size in pixels - wizard layout, panel icons, floatbar icons - must
# follow. The exact factor is MEASURED against the live theme when a
# DD-panel control is reachable (theme propagation only crosses
# Controls, so the probe must live inside the panel tree); the 1.45
# constant is only the fallback.
func _ui_scale() -> float:
	if _cvw_us > 0.0:
		return _cvw_us
	_cvw_us = 1.0
	var cf = ConfigFile.new()
	if cf.load("user://config.ini") == OK \
			and bool(cf.get_value("Preferences", "enlarge_ui", false)):
		var eff = _ui_eff_font()
		if eff == null:
			# Probe not in the tree yet (early panel build): use the
			# fallback WITHOUT caching, so a later call re-measures.
			_cvw_us = -1.0
			return 1.45
		_cvw_us = 1.45
		var stock_c = Control.new()
		var stock = stock_c.get_font("font", "Label")
		stock_c.free()
		if stock != null and stock.get_height() > 1.0:
			var r = eff.get_height() / stock.get_height()
			if r > 1.05:
				_cvw_us = clamp(r, 1.1, 2.5)
	return _cvw_us


# The font DD actually renders with, resolved through a control living
# inside the themed panel tree. Null when the panel is not built yet.
func _ui_eff_font():
	if _sec != null and is_instance_valid(_sec) and _sec.is_inside_tree():
		return _sec.get_font("font", "Label")
	# The category/draw buttons are built before _sec exists: the
	# panel's Align container is already in the tree by then.
	if _tool_panel != null and is_instance_valid(_tool_panel):
		var al = _tool_panel.get("Align")
		if al != null and is_instance_valid(al) and al.is_inside_tree():
			return al.get_font("font", "Label")
	return null


# Icons assigned at their NATIVE size follow EnlargeUI too: resized by
# the UI factor only, so normal setups keep the exact original look.
func _ui_icon(tex):
	if tex == null:
		return null
	if _ui_scale() <= 1.01:
		return tex
	return _make_small_icon(tex, int(max(1, tex.get_width())))


func _cvw_open() -> void:
	# A map reload frees the cached dialog through _owned without nulling
	# this reference: normalize first, every check below assumes null.
	if _cvw_dlg != null and not is_instance_valid(_cvw_dlg):
		_cvw_dlg = null
	if _cvw_prime_wall_colors() and _cvw_dlg != null:
		# Wall list only just arrived/colored: the cached dialog is stale.
		_cvw_dlg.queue_free()
		_cvw_dlg = null
	if _cvw_dlg == null:
		_cvw_build()
	if _cvw_dlg == null or not is_instance_valid(_cvw_dlg):
		# No libraries reachable: fall back to the direct conversion.
		printerr("[SketchConv] wall library unreachable: converting without the wizard")
		_cv_start_vectorize()
		return
	_cvw_page = 0
	_cvw_show_page()
	# 680 was slightly under the content's minimum: the footer inset
	# only appeared after a manual resize forced a relayout. Under
	# EnlargeUI the budget scales with the theme, clamped to the window
	# so a 1080p screen still shows the whole footer.
	# The base 720 assumed no Soft Shadows rows: each optional entry
	# adds its own line so Back / Next stay inside the window.
	var want = Vector2(660, 720 + 30 * _cvw_ss_extra) * _ui_scale()
	want.x = min(want.x, OS.window_size.x * 0.95)
	want.y = min(want.y, OS.window_size.y * 0.92)
	_cvw_dlg.popup_centered(want)


# The per-wall default colors live in the wall list's icon modulates,
# populated by WallTool.Enable. If the tool never ran this session, all
# modulates are white: enable it once (quickswitch there and back).
# Returns true when it just primed the colors (WallTool.Enable fills the
# modulates; if the tool never ran, everything is white).
func _cvw_prime_wall_colors() -> bool:
	var panel = Global.Editor.Toolset.GetToolPanel("WallTool")
	if panel == null:
		return false
	# DD fills tool panels lazily: before the Wall tool ran once this
	# session its list is EMPTY, not just white. Bailing here used to skip
	# the priming entirely, the wizard then found 0 walls and silently
	# fell back to the direct conversion (no popup). Quickswitch in both
	# cases: WallTool.Enable populates the list and the modulates.
	var gm = _cvw_find_wall_list()
	var need = gm == null or gm.get_item_count() == 0
	if not need and not _cvw_primed:
		# First wizard of the session: prime unconditionally. The
		# all-white sampling below misses mixed lists (one tinted pack
		# wall and the sampling concludes "already primed" while the DD
		# defaults are still white).
		need = true
	if not need:
		var all_white = true
		for i in range(min(8, gm.get_item_count())):
			if not gm.get_item_icon_modulate(i).is_equal_approx(Color(1, 1, 1, 1)):
				all_white = false
				break
		need = all_white
	if not need:
		return false
	Global.Editor.Toolset.Quickswitch("WallTool")
	Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_cvw_primed = true
	printerr("[SketchConv] wall list primed")
	return true


func _cvw_build() -> void:
	_cvw_load_favs()
	_cvw_sort_load()
	var pages_def = [
		["wall", "Walls", "WallTool"],
		["door", "Doors", "PortalTool"],
		["win", "Windows", "PortalTool"],
		["pillar", "Pillars", "ObjectTool"],
		["floor", "Floor", "PatternShapeTool"],
		["summary", "Overview", ""]]
	var dlg = WindowDialog.new()
	dlg.window_title = "Convert to DD Walls"
	dlg.resizable = true
	# Clicking the map used to hide the popup (Godot closes any
	# non-exclusive Popup on an outside click) and lose the flow.
	dlg.popup_exclusive = true
	if _ui_scale() > 1.01:
		# The dialog hangs off a plain Node branch, so Control theme
		# propagation never reaches it: a theme is built by hand around
		# DD's EFFECTIVE font (probed through the tool panel, which does
		# live under the enlarged theme). If the probe is unreachable or
		# still stock-sized, the stock font is scaled by the factor.
		var base_f = _ui_eff_font()
		if base_f == null:
			var geth = Global.get("Theme")
			if geth != null and geth is Theme:
				base_f = geth.default_font
		if base_f == null:
			var bfc = Control.new()
			base_f = bfc.get_font("font", "Label")
			bfc.free()
		if base_f != null:
			var stc = Control.new()
			var stf = stc.get_font("font", "Label")
			stc.free()
			var already_big = stf != null and stf.get_height() > 1.0 \
					and base_f.get_height() / stf.get_height() > 1.05
			if not already_big and base_f is DynamicFont:
				base_f = base_f.duplicate()
				base_f.size = int(round(float(base_f.size) * _ui_scale()))
			var th2 = Theme.new()
			th2.default_font = base_f
			dlg.theme = th2
	_cvw_pages = []
	_cvw_lists = {}
	_cvw_checks = {}
	_cvw_tab_btns = []
	var vb = VBoxContainer.new()
	vb.anchor_right = 1.0
	vb.anchor_bottom = 1.0
	vb.margin_left = 8
	vb.margin_top = 8
	vb.margin_right = -8
	vb.margin_bottom = -14
	dlg.add_child(vb)
	# --- 1. the four step tabs on top -----------------------------------
	var tab_row = HBoxContainer.new()
	for ti in range(pages_def.size()):
		var tb = Button.new()
		tb.text = pages_def[ti][1]
		tb.toggle_mode = true
		tb.focus_mode = Control.FOCUS_NONE
		tb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tb.connect("pressed", self, "_on_cvw_tab_top", [ti])
		tab_row.add_child(tb)
		_cvw_tab_btns.append(tb)
	vb.add_child(tab_row)
	vb.add_child(HSeparator.new())
	# --- 2. body: options column on the left, pages on the right --------
	var body = HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vb.add_child(body)
	var opts = VBoxContainer.new()
	opts.rect_min_size = Vector2(200.0 * _ui_scale(), 0)
	opts.set("custom_constants/separation", 6)
	body.add_child(opts)
	var olbl = Label.new()
	olbl.text = "Options"
	olbl.align = Label.ALIGN_CENTER
	opts.add_child(olbl)
	opts.add_child(HSeparator.new())
	var t_walls = Label.new()
	t_walls.text = "Walls"
	t_walls.align = Label.ALIGN_CENTER
	opts.add_child(t_walls)
	var cb_sh = CheckButton.new()
	cb_sh.text = "Default Shadows"
	cb_sh.pressed = false
	cb_sh.focus_mode = Control.FOCUS_NONE
	cb_sh.hint_tooltip = "DD wall drop shadow"
	opts.add_child(cb_sh)
	_cvw_checks["shadow"] = cb_sh
	_cvw_ss_extra = 0
	if _softshadows_walls_inst() != null:
		_cvw_ss_extra += 1
		var ssw = CheckButton.new()
		ssw.text = "Soft Shadows"
		ssw.pressed = false
		ssw.focus_mode = Control.FOCUS_NONE
		ssw.hint_tooltip = "Apply the Soft Shadows mod's wall drop shadow (realistic mode, mod defaults)"
		opts.add_child(ssw)
		_cvw_checks["soft_walls"] = ssw
	var cb_bv = CheckButton.new()
	cb_bv.text = "Bevel Corners"
	cb_bv.pressed = false
	cb_bv.focus_mode = Control.FOCUS_NONE
	cb_bv.hint_tooltip = "Bevel joints instead of sharp"
	opts.add_child(cb_bv)
	_cvw_checks["bevel"] = cb_bv
	opts.add_child(HSeparator.new())
	var t_por = Label.new()
	t_por.text = "Portals"
	t_por.align = Label.ALIGN_CENTER
	opts.add_child(t_por)
	var cb_do = CheckButton.new()
	cb_do.text = "Doors"
	cb_do.pressed = true
	cb_do.focus_mode = Control.FOCUS_NONE
	cb_do.hint_tooltip = "Convert door openings into portals"
	cb_do.connect("toggled", self, "_on_cvw_portal_toggled")
	opts.add_child(cb_do)
	_cvw_checks["use_doors"] = cb_do
	var cb_wi = CheckButton.new()
	cb_wi.text = "Windows"
	cb_wi.pressed = true
	cb_wi.focus_mode = Control.FOCUS_NONE
	cb_wi.hint_tooltip = "Convert window openings into portals"
	cb_wi.connect("toggled", self, "_on_cvw_portal_toggled")
	opts.add_child(cb_wi)
	_cvw_checks["use_wins"] = cb_wi
	opts.add_child(HSeparator.new())
	var t_pil = Label.new()
	t_pil.text = "Pillars"
	t_pil.align = Label.ALIGN_CENTER
	opts.add_child(t_pil)
	var cb_pi = CheckButton.new()
	cb_pi.text = "Pillars on Corners"
	cb_pi.pressed = false
	cb_pi.focus_mode = Control.FOCUS_NONE
	cb_pi.hint_tooltip = "Place pillar props on junctions and corners"
	opts.add_child(cb_pi)
	_cvw_checks["pillars"] = cb_pi
	cb_pi.connect("toggled", self, "_on_cvw_pillars_toggled")
	var prand = CheckButton.new()
	prand.text = "Randomize Orientation"
	prand.pressed = false
	prand.focus_mode = Control.FOCUS_NONE
	prand.hint_tooltip = "Each pillar gets a random 0/90/180/270 rotation and a random mirror"
	opts.add_child(prand)
	_cvw_checks["pillar_rand"] = prand
	if _softshadows_objects_inst() != null:
		_cvw_ss_extra += 1
		var ssp = CheckButton.new()
		ssp.text = "Soft Shadow"
		ssp.pressed = false
		ssp.focus_mode = Control.FOCUS_NONE
		ssp.hint_tooltip = "Feed the generated pillars to the Soft Shadows object pipeline (mod defaults)"
		opts.add_child(ssp)
		_cvw_checks["soft_pillars"] = ssp
	opts.add_child(HSeparator.new())
	var t_flo = Label.new()
	t_flo.text = "Floor"
	t_flo.align = Label.ALIGN_CENTER
	opts.add_child(t_flo)
	var cb_fl = CheckButton.new()
	cb_fl.text = "Draw Floor"
	cb_fl.pressed = false
	cb_fl.focus_mode = Control.FOCUS_NONE
	cb_fl.hint_tooltip = "Fill the building footprint with the pattern picked in the Floor tab"
	cb_fl.connect("toggled", self, "_on_cvw_pillars_toggled")
	opts.add_child(cb_fl)
	_cvw_checks["use_floor"] = cb_fl
	if _softshadows_building_inst() != null:
		_cvw_ss_extra += 2
		opts.add_child(HSeparator.new())
		var ssb = CheckButton.new()
		ssb.text = "Building Shadow"
		ssb.pressed = false
		ssb.focus_mode = Control.FOCUS_NONE
		ssb.hint_tooltip = "After converting, pick the generated building in the Soft Shadows Building Shadow tool"
		opts.add_child(ssb)
		_cvw_checks["soft_building"] = ssb
	opts.add_child(HSeparator.new())
	_cvw_area_toggle = CheckButton.new()
	_cvw_area_toggle.text = "Select Area"
	_cvw_area_toggle.pressed = false
	_cvw_area_toggle.focus_mode = Control.FOCUS_NONE
	_cvw_area_toggle.hint_tooltip = "ON: Convert Sketch closes the wizard and lets you drag the rectangle to convert. OFF: the whole sketch is converted."
	opts.add_child(_cvw_area_toggle)
	var ospacer = Control.new()
	ospacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	opts.add_child(ospacer)
	var prev_cf = ConfigFile.new()
	if prev_cf.load(_cvw_last_path()) == OK:
		# Two-line button in a 1 px grey frame.
		var pbtn = Button.new()
		pbtn.focus_mode = Control.FOCUS_NONE
		pbtn.rect_min_size = Vector2(0, 60.0 * _ui_scale())
		pbtn.hint_tooltip = "Convert right away with the settings of the last conversion (any map)"
		var psb = StyleBoxFlat.new()
		psb.bg_color = Color(1, 1, 1, 0.04)
		psb.border_width_left = 1
		psb.border_width_right = 1
		psb.border_width_top = 1
		psb.border_width_bottom = 1
		psb.border_color = Color(0.6, 0.6, 0.6)
		psb.corner_radius_top_left = 3
		psb.corner_radius_top_right = 3
		psb.corner_radius_bottom_left = 3
		psb.corner_radius_bottom_right = 3
		psb.anti_aliasing = true
		var psb_h = psb.duplicate()
		psb_h.bg_color = Color(1, 1, 1, 0.12)
		var psb_p = psb.duplicate()
		psb_p.bg_color = Color(1, 1, 1, 0.18)
		psb_p.border_color = Color(1, 1, 1, 1)
		pbtn.add_stylebox_override("normal", psb)
		pbtn.add_stylebox_override("hover", psb_h)
		pbtn.add_stylebox_override("pressed", psb_p)
		var pcc = CenterContainer.new()
		pcc.anchor_right = 1.0
		pcc.anchor_bottom = 1.0
		pcc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var plab = Label.new()
		plab.text = "Convert with\nPrevious Settings"
		plab.align = Label.ALIGN_CENTER
		plab.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pcc.add_child(plab)
		pbtn.add_child(pcc)
		pbtn.connect("pressed", self, "_cvw_apply_previous")
		opts.add_child(pbtn)
	body.add_child(VSeparator.new())
	var pages_holder = VBoxContainer.new()
	pages_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pages_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(pages_holder)
	for pd in pages_def:
		# Each page VBox lives inside a plain Control wrapper: a
		# VBoxContainer lays its children out and IGNORES anchors, so
		# the dark overlays ended up stacked at the bottom instead of
		# covering the page.
		var wrap = Control.new()
		wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
		wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var page = VBoxContainer.new()
		page.anchor_right = 1.0
		page.anchor_bottom = 1.0
		if pd[0] == "summary":
			var sv = VBoxContainer.new()
			sv.size_flags_vertical = Control.SIZE_EXPAND_FILL
			var sscroll = ScrollContainer.new()
			sscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
			sscroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			sscroll.scroll_horizontal_enabled = false
			_cvw_sum_box = VBoxContainer.new()
			_cvw_sum_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_cvw_sum_box.set("custom_constants/separation", 8)
			sscroll.add_child(_cvw_sum_box)
			sv.add_child(sscroll)
			page.add_child(sv)
			wrap.add_child(page)
			pages_holder.add_child(wrap)
			_cvw_pages.append(wrap)
			continue
		var il = _cvw_make_list(pd[0], pd[2])
		if il != null:
			# 1. search row (labeled)
			var srow = HBoxContainer.new()
			var slbl = Label.new()
			slbl.text = "Search"
			slbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			srow.add_child(slbl)
			var se = LineEdit.new()
			se.placeholder_text = "Search..."
			se.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			se.connect("text_changed", self, "_on_cvw_search", [pd[0]])
			srow.add_child(se)
			var sortb = OptionButton.new()
			sortb.add_item("Sort: Default", 0)
			sortb.add_item("Sort: A-Z", 1)
			sortb.add_item("Sort: Pack", 2)
			if pd[0] != "floor":
				sortb.add_item("Sort: Size", 3)
			sortb.focus_mode = Control.FOCUS_NONE
			sortb.connect("item_selected", self, "_on_cvw_sort", [pd[0]])
			_cvw_sort_btns[pd[0]] = sortb
			# The sort survives map reloads and sessions, shared
			# across tabs: the GLOBAL mode applies where offered, a
			# tab lacking it falls back to its own stored pick.
			# Deferred: the list's snapshot fills later in build.
			var smode = _cvw_sort_global
			if smode >= sortb.get_item_count():
				smode = int(_cvw_sort.get(pd[0], 0))
			if smode > 0 and smode < sortb.get_item_count():
				sortb.select(smode)
				call_deferred("_cvw_apply_sort", pd[0], smode)
			srow.add_child(sortb)
			page.add_child(srow)
			_cvw_search_edits[pd[0]] = se
			# 2. preview size
			var zrow = HBoxContainer.new()
			var zlbl = Label.new()
			zlbl.text = "Preview size"
			zlbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			zrow.add_child(zlbl)
			var zs = HSlider.new()
			zs.min_value = 0.5
			zs.max_value = 1.95
			zs.step = 0.05
			zs.value = 1.0
			zs.rect_min_size = Vector2(140.0 * _ui_scale(), 0)
			zs.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			zs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			zs.connect("value_changed", self, "_on_cvw_zoom", [pd[0]])
			_cvw_zoom_sliders[pd[0]] = zs
			zrow.add_child(zs)
			if pd[0] == "pillar":
				# Selected wall's visible height, for eyeballing the
				# pillar scale against it.
				var wlbl = Label.new()
				wlbl.text = "Wall: ? px"
				wlbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				_cvw_wall_px_lbl = wlbl
				zrow.add_child(wlbl)
				var wil = _cvw_lists.get("wall")
				if wil != null and is_instance_valid(wil):
					wil.connect("item_selected", self, "_on_cvw_wall_for_px")
			page.add_child(zrow)
			if pd[0] == "pillar":
				# Placement scale: resizes the pillars DD receives and
				# the size captions in this list, live.
				var prow = HBoxContainer.new()
				var plbl2 = Label.new()
				plbl2.text = "Pillar Size"
				plbl2.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				prow.add_child(plbl2)
				var pslider = HSlider.new()
				pslider.min_value = 0.5
				pslider.max_value = 2.0
				pslider.step = 0.01
				pslider.value = _cvw_pillar_scale
				pslider.rect_min_size = Vector2(140.0 * _ui_scale(), 0)
				pslider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				pslider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
				pslider.hint_tooltip = "Scale applied to placed pillars (and to the sizes shown below)"
				pslider.connect("value_changed", self, "_on_cvw_pillar_scale")
				_cvw_pillar_scale_slider = pslider
				prow.add_child(pslider)
				var pspin = SpinBox.new()
				pspin.min_value = 50
				pspin.max_value = 200
				pspin.step = 1
				pspin.value = round(_cvw_pillar_scale * 100.0)
				pspin.suffix = "%"
				pspin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				pspin.connect("value_changed", self, "_on_cvw_pillar_scale_pct")
				prow.add_child(pspin)
				_cvw_pillar_scale_spin = pspin
				var prst = Button.new()
				prst.icon = _make_small_icon(_load_icon("reset"), 18)
				prst.hint_tooltip = "Reset to 100%"
				prst.focus_mode = Control.FOCUS_NONE
				prst.connect("pressed", pslider, "set_value", [1.0])
				prow.add_child(prst)
				page.add_child(prow)
			# 3. hints
			var hint = Label.new()
			hint.text = "Right-click an asset to favorite it."
			hint.modulate = Color(1, 1, 1, 0.55)
			page.add_child(hint)
			if pd[0] != "wall":
				var hint2 = Label.new()
				hint2.text = "Shift-click or Ctrl-click to select multiple assets."
				hint2.modulate = Color(1, 1, 1, 0.55)
				page.add_child(hint2)
			# 4. All / Favorites tabs right above the library
			var trow = HBoxContainer.new()
			var tab_all = Button.new()
			tab_all.text = "All"
			tab_all.toggle_mode = true
			tab_all.pressed = true
			tab_all.focus_mode = Control.FOCUS_NONE
			tab_all.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tab_all.connect("pressed", self, "_on_cvw_tab", [pd[0], 0])
			trow.add_child(tab_all)
			var tab_used = Button.new()
			tab_used.text = "Used"
			tab_used.hint_tooltip = "Assets of this type already placed on the current map"
			tab_used.toggle_mode = true
			tab_used.focus_mode = Control.FOCUS_NONE
			tab_used.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tab_used.connect("pressed", self, "_on_cvw_tab", [pd[0], 1])
			trow.add_child(tab_used)
			var tab_fav = Button.new()
			tab_fav.text = "Favorites"
			tab_fav.toggle_mode = true
			tab_fav.focus_mode = Control.FOCUS_NONE
			tab_fav.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tab_fav.connect("pressed", self, "_on_cvw_tab", [pd[0], 2])
			trow.add_child(tab_fav)
			# Index layout is [All, Favorites, Used]: the Favorites
			# consumers keep reading tabs[1] untouched.
			_cvw_fav_toggles[pd[0]] = [tab_all, tab_fav, tab_used]
			page.add_child(trow)
			# The All tab always starts selected: opening on Favorites
			# just because some exist hid the rest of the library.
			# 5. the library itself
			il.connect("gui_input", self, "_on_cvw_list_gui", [pd[0]])
			page.add_child(il)
			_cvw_lists[pd[0]] = il
		wrap.add_child(page)
		pages_holder.add_child(wrap)
		_cvw_pages.append(wrap)
	_cvw_overlays = {}
	var ov_texts = {
		1: "Doors are turned off,\nyou can enable them in the options on the left.",
		2: "Windows are turned off,\nyou can enable them in the options on the left.",
		3: "Pillars on corners are turned off,\nyou can enable them in the options on the left.",
		4: "Floors are turned off,\nyou can enable them in the options on the left."}
	for opi in ov_texts:
		if opi >= _cvw_pages.size():
			continue
		var ovp = Panel.new()
		var osb = StyleBoxFlat.new()
		osb.bg_color = Color(0, 0, 0, 0.9)
		ovp.add_stylebox_override("panel", osb)
		ovp.anchor_right = 1.0
		ovp.anchor_bottom = 1.0
		ovp.visible = false
		var occ = CenterContainer.new()
		occ.anchor_right = 1.0
		occ.anchor_bottom = 1.0
		var olab = Label.new()
		olab.text = ov_texts[opi]
		olab.align = Label.ALIGN_CENTER
		olab.valign = Label.VALIGN_CENTER
		var obase = olab.get_font("font")
		if obase != null and obase is DynamicFont:
			var obig = obase.duplicate()
			obig.size = int(round(float(obig.size) * 1.15 * _ui_scale()))
			olab.add_font_override("font", obig)
		occ.add_child(olab)
		ovp.add_child(occ)
		_cvw_pages[opi].add_child(ovp)
		_cvw_overlays[opi] = ovp
	# --- 3. footer: Back / Next, then Convert Area / Convert All --------
	var btn_row = HBoxContainer.new()
	_cvw_back = Button.new()
	_cvw_back.text = "Back"
	_cvw_back.focus_mode = Control.FOCUS_NONE
	_cvw_back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cvw_back.connect("pressed", self, "_on_cvw_back")
	btn_row.add_child(_cvw_back)
	_cvw_area_btn = Button.new()
	_cvw_area_btn.text = "Convert Area"
	_cvw_area_btn.focus_mode = Control.FOCUS_NONE
	_cvw_area_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cvw_area_btn.hint_tooltip = "Close the wizard and drag a rectangle on the map: only the sketch inside it is converted with these settings."
	_cvw_area_btn.visible = false
	_cvw_area_btn.connect("pressed", self, "_on_cvw_area")
	btn_row.add_child(_cvw_area_btn)
	_cvw_btn = Button.new()
	_cvw_btn.text = "Next"
	_cvw_btn.focus_mode = Control.FOCUS_NONE
	_cvw_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cvw_btn.connect("pressed", self, "_on_cvw_next")
	btn_row.add_child(_cvw_btn)
	_cvw_go_btn = Button.new()
	_cvw_go_btn.text = "Convert Sketch"
	_cvw_go_btn.focus_mode = Control.FOCUS_NONE
	_cvw_go_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cvw_go_btn.rect_min_size = Vector2(0, 40.0 * _ui_scale())
	var gsb = StyleBoxFlat.new()
	gsb.bg_color = Color(1, 1, 1, 0.04)
	gsb.border_width_left = 1
	gsb.border_width_right = 1
	gsb.border_width_top = 1
	gsb.border_width_bottom = 1
	gsb.border_color = Color(0.6, 0.6, 0.6)
	gsb.corner_radius_top_left = 3
	gsb.corner_radius_top_right = 3
	gsb.corner_radius_bottom_left = 3
	gsb.corner_radius_bottom_right = 3
	gsb.anti_aliasing = true
	var gsb_h = gsb.duplicate()
	gsb_h.bg_color = Color(1, 1, 1, 0.12)
	var gsb_p = gsb.duplicate()
	gsb_p.bg_color = Color(1, 1, 1, 0.18)
	gsb_p.border_color = Color(1, 1, 1, 1)
	_cvw_go_btn.add_stylebox_override("normal", gsb)
	_cvw_go_btn.add_stylebox_override("hover", gsb_h)
	_cvw_go_btn.add_stylebox_override("pressed", gsb_p)
	_cvw_go_btn.visible = false
	_cvw_go_btn.connect("pressed", self, "_on_cvw_go")
	btn_row.add_child(_cvw_go_btn)
	vb.add_child(btn_row)
	if not _cvw_lists.has("wall") or _cvw_lists["wall"].get_item_count() == 0:
		printerr("[SketchConv] wizard build failed: wall list empty")
		dlg.queue_free()
		_cvw_dlg = null
		return
	_on_cvw_pillars_toggled(false)
	_cvw_update_overlays()
	Global.Editor.add_child(dlg)
	_owned.append(dlg)
	_cvw_dlg = dlg
	_cvw_size_scan_start()
	call_deferred("_on_cvw_zoom", 1.0, "wall")
	_cvw_fit_pending = 30
	# Every list opens PRE-SELECTED with the last conversion's picks.
	call_deferred("_cvw_preselect_last")
	# Unofficial Patch Popup Blur: opt in when the singleton is around.
	if Engine.has_meta("popup_blur_singleton"):
		var pb = Engine.get_meta("popup_blur_singleton")
		if pb != null and is_instance_valid(pb) and pb.has_method("register"):
			pb.register(dlg)


# Top tab clicked: every tab is reachable, even the "off" ones (their
# page shows a dark overlay explaining where to enable the feature).
# The Summary page: every current pick, thumbnails included.
func _cvw_fill_summary() -> void:
	if _cvw_sum_box == null or not is_instance_valid(_cvw_sum_box):
		return
	for ch in _cvw_sum_box.get_children():
		ch.queue_free()
	_cvw_sum_row("Wall", "wall", false)
	if not _cvw_checks.has("use_doors") or _cvw_checks["use_doors"].pressed:
		_cvw_sum_row("Doors", "door", true)
	if not _cvw_checks.has("use_wins") or _cvw_checks["use_wins"].pressed:
		_cvw_sum_row("Windows", "win", true)
	if _cvw_checks.has("pillars") and _cvw_checks["pillars"].pressed:
		_cvw_sum_row("Pillars", "pillar", true)
	if _cvw_checks.has("use_floor") and _cvw_checks["use_floor"].pressed:
		_cvw_sum_row("Floor", "floor", true)


# A texture trimmed to its visible pixels (AtlasTexture crop, cached
# by instance): the overview thumbnails lose their transparent halo.
func _cvw_cropped(tex):
	var iid = tex.get_instance_id()
	if _cvw_crop_cache.has(iid):
		return _cvw_crop_cache[iid]
	var out = tex
	var im = tex.get_data()
	if im != null:
		if im.is_compressed():
			im.decompress()
		var ur = im.get_used_rect()
		if ur.size.x >= 1 and ur.size.y >= 1 \
				and (ur.size.x < im.get_width() or ur.size.y < im.get_height()):
			var at3 = AtlasTexture.new()
			at3.atlas = tex
			at3.region = ur
			out = at3
	_cvw_crop_cache[iid] = out
	return out


func _cvw_sum_row(title: String, key: String, multi: bool) -> void:
	var il = _cvw_lists.get(key)
	var snap = _cvw_snaps.get(key)
	if il == null or not is_instance_valid(il) or snap == null:
		return
	# Breathing room above every section title (the child-count guard
	# misfired: queue_free leaves the old children in place until the
	# end of the frame, so the "first" fill was the unpadded one).
	var tpad = Control.new()
	tpad.rect_min_size = Vector2(0, 25)
	_cvw_sum_box.add_child(tpad)
	var lab = Label.new()
	lab.text = title
	lab.align = Label.ALIGN_CENTER
	lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cvw_sum_box.add_child(lab)
	# Each section scrolls HORIZONTALLY on its own: a big
	# multi-selection used to widen the shared box and push everything
	# off screen. The row expands to the scroll width, so it stays
	# centered while it fits.
	var srow2 = ScrollContainer.new()
	srow2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	srow2.scroll_vertical_enabled = false
	var row = HBoxContainer.new()
	row.alignment = BoxContainer.ALIGN_CENTER
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.set("custom_constants/separation", 10)
	var sel = il.get_selected_items()
	var shown = 0
	var row_h = 24.0
	for si in sel:
		var oi = _cvw_sel_orig_at(il, int(si))
		if oi < 0 or oi >= snap.size():
			continue
		var ic = snap[oi]["icon"]
		if ic == null:
			continue
		# Trim the transparent padding around the asset; the wall
		# shows two mirrored tiles, larger than the rest.
		var dtex = ic
		if key == "wall" and ic is AtlasTexture and _cvw_wall_strips.has(oi):
			var tw2 = float(_cvw_wall_strips[oi][0]) / 6.0
			dtex = AtlasTexture.new()
			dtex.atlas = ic.atlas
			dtex.region = Rect2(0, 0, tw2 * 2.0, _cvw_wall_strips[oi][1])
		elif ic.has_method("get_data"):
			dtex = _cvw_cropped(ic)
		var tr = TextureRect.new()
		tr.texture = dtex
		tr.expand = true
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# Box sized to the scaled CONTENT: a fixed square box
		# letterboxed flat assets and kept the sections tall no matter
		# how tight the texture crop was.
		var maxw = 150.0
		var maxh = 130.0
		if key == "wall":
			maxw = 340.0
		elif key == "pillar":
			maxw = 64.0
			maxh = 64.0
		var tsz = dtex.get_size()
		if tsz.x < 1.0 or tsz.y < 1.0:
			tsz = Vector2(64, 64)
		var fit = min(maxw / tsz.x, maxh / tsz.y)
		tr.rect_min_size = Vector2(max(24.0, tsz.x * fit), max(12.0, tsz.y * fit))
		row_h = max(row_h, tr.rect_min_size.y)
		tr.modulate = snap[oi].get("mod", Color(1, 1, 1))
		tr.hint_tooltip = String(snap[oi].get("tip", ""))
		row.add_child(tr)
		shown += 1
		if not multi:
			break
	if shown == 0:
		var none = Label.new()
		none.text = "None"
		none.modulate = Color(1, 1, 1, 0.6)
		row.add_child(none)
	# The scroll box hugs the TALLEST thumbnail actually shown (a
	# fixed height letterboxed the flat assets into tall sections).
	srow2.rect_min_size = Vector2(0, row_h + 14.0)
	srow2.add_child(row)
	_cvw_sum_box.add_child(srow2)
	_cvw_sum_box.add_child(HSeparator.new())


func _on_cvw_tab_top(i: int) -> void:
	_cvw_page = i
	_cvw_show_page()


# Pillars toggle: dims the tab and its two dependent options, and
# drives the page overlay.
func _on_cvw_pillars_toggled(v: bool) -> void:
	var dim = Color(1, 1, 1, 1) if v else Color(1, 1, 1, 0.35)
	for pk in ["pillar_rand", "soft_pillars"]:
		if _cvw_checks.has(pk) and is_instance_valid(_cvw_checks[pk]):
			_cvw_checks[pk].modulate = dim
	_cvw_update_overlays()


func _on_cvw_portal_toggled(_v: bool) -> void:
	_cvw_update_overlays()


# Dark overlays over the disabled pages, dimmed tab captions.
func _cvw_update_overlays() -> void:
	var states = {
		1: not _cvw_checks.has("use_doors") or _cvw_checks["use_doors"].pressed,
		2: not _cvw_checks.has("use_wins") or _cvw_checks["use_wins"].pressed,
		3: _cvw_checks.has("pillars") and _cvw_checks["pillars"].pressed,
		4: _cvw_checks.has("use_floor") and _cvw_checks["use_floor"].pressed}
	for pi in states:
		var on = bool(states[pi])
		if pi < _cvw_tab_btns.size() and is_instance_valid(_cvw_tab_btns[pi]):
			_cvw_tab_btns[pi].modulate = Color(1, 1, 1, 1) if on else Color(1, 1, 1, 0.4)
		var ov = _cvw_overlays.get(pi)
		if ov != null and is_instance_valid(ov):
			ov.visible = not on
	# Live overview: toggling an option refreshes the recap in place.
	if _cvw_pages.size() > 0 and _cvw_page == _cvw_pages.size() - 1:
		_cvw_fill_summary()


func _cvw_size_str(key: String, v: Vector2) -> String:
	if key == "pillar":
		v = v * _cvw_pillar_scale
	if key == "wall":
		return str(int(v.y)) + " px"
	if key == "door" or key == "win":
		# Portals read in map squares: the LARGER visible dimension
		# over the 256 px cell. Rounded to 0.10, except the first four
		# 0.02 steps above each whole unit (1.02..1.08, 5.02..5.08):
		# a door barely wider than N squares matters.
		var sq = max(v.x, v.y) / 256.0
		var whole = floor(sq)
		var frac = sq - whole
		if frac > 0.001 and frac < 0.089:
			sq = whole + stepify(frac, 0.02)
		else:
			sq = stepify(sq, 0.1)
		var txt = str(sq)
		if txt.ends_with(".0"):
			txt = txt.substr(0, txt.length() - 2)
		return txt + " sq."
	return str(int(v.x)) + " x " + str(int(v.y)) + " px"


# ---- visible-size pipeline: background decode + used_rect + cache ---------
const SIZE_CACHE_FILE = "user://Sketch_Tool/asset_sizes.cfg"


func _cv_size_cache_load() -> void:
	if _cv_size_cache != null:
		return
	_cv_size_cache = {}
	var cf = ConfigFile.new()
	if cf.load(SIZE_CACHE_FILE) != OK:
		return
	for k in cf.get_section_keys("sizes") if cf.has_section("sizes") else []:
		_cv_size_cache[k] = String(cf.get_value("sizes", k, ""))


func _cv_size_cache_get(path: String):
	_cv_size_cache_load()
	var v = _cv_size_cache.get(path.md5_text())
	if v == null:
		return null
	var parts = String(v).split("x")
	if parts.size() != 2:
		return null
	return Vector2(int(parts[0]), int(parts[1]))


func _cv_size_cache_save() -> void:
	if _cv_size_cache == null:
		return
	var d = Directory.new()
	d.make_dir_recursive("user://Sketch_Tool")
	var cf = ConfigFile.new()
	for k in _cv_size_cache:
		cf.set_value("sizes", k, _cv_size_cache[k])
	cf.save(SIZE_CACHE_FILE)


# Launch the background computation for every snapshot entry without a
# cached size: file decode when a path exists, otherwise the ICON's
# pixels (default assets ship without path metadata - their icon is
# the texture itself).
func _cvw_size_scan_start() -> void:
	if _cvw_size_thread != null:
		return
	var jobs = []
	var stats = {}
	for key in _cvw_snaps:
		if key == "floor":
			# Patterns and tilesets have no meaningful pixel size.
			continue
		var snap = _cvw_snaps[key]
		for i in range(snap.size()):
			if snap[i].get("rsz") != null:
				continue
			if key == "pillar":
				# Only the assets NAMED pillar: sizing all 2284
				# objects would take ages for nothing.
				var nm = (String(snap[i].get("tip", "")) + "|"
					+ String(snap[i].get("path", ""))).to_lower()
				if nm.find("pillar") < 0:
					continue
			if snap[i].get("path") != null:
				jobs.append([key, i, snap[i]["path"], null])
				stats[key] = int(stats.get(key, 0)) + 1
			else:
				var ic = snap[i].get("icon")
				# AtlasTexture (some default assets) has no get_data:
				# guard, or one bad icon aborts the whole queue build.
				if ic != null and ic.has_method("get_data"):
					var im = ic.get_data()
					if im != null:
						jobs.append([key, i, null, im])
						stats[key] = int(stats.get(key, 0)) + 1
				elif ic != null:
					jobs.append([key, i, null, null, Vector2(ic.get_width(), ic.get_height())])
					stats[key] = int(stats.get(key, 0)) + 1
	printerr("[SketchConv] size scan queue: ", stats)
	if jobs.empty():
		_cvw_size_done = true
		return
	_cvw_size_done = false
	_cvw_size_results = []
	_cvw_size_mutex = Mutex.new()
	_cvw_size_thread = Thread.new()
	_cvw_size_thread.start(self, "_cvw_size_worker", jobs)
	printerr("[SketchConv] visible-size scan: ", jobs.size(), " assets queued")


# THREAD: decode each file (PNG or WebP by magic), take the visible
# bounds (get_used_rect trims the transparent padding), forget the
# image. Scene tree untouched: results go through the mutex.
func _cvw_size_worker(jobs: Array) -> void:
	var fails = {}
	for jb in jobs:
		var img = null
		if jb[2] != null:
			var f = File.new()
			if f.open(jb[2], File.READ) != OK:
				# Imported (default) assets exist only as .stex inside
				# the PCK: unreadable by File, loadable by load() -
				# which must run on the MAIN thread. Hand them over.
				_cvw_size_mutex.lock()
				_cvw_size_results.append(["mainload", jb[0], jb[1], jb[2]])
				_cvw_size_mutex.unlock()
				continue
			var buf = f.get_buffer(f.get_len())
			f.close()
			if buf.size() < 16:
				continue
			img = Image.new()
			var err = FAILED
			if buf[0] == 0x89 and buf[1] == 0x50:
				err = img.load_png_from_buffer(buf)
			elif buf[0] == 0x52 and buf[1] == 0x49:
				err = img.load_webp_from_buffer(buf)
			elif buf[0] == 0xFF and buf[1] == 0xD8:
				err = img.load_jpg_from_buffer(buf)
			if err != OK:
				_cvw_size_mutex.lock()
				_cvw_size_results.append(["mainload", jb[0], jb[1], jb[2]])
				_cvw_size_mutex.unlock()
				continue
		else:
			img = jb[3]
		if img == null:
			# Atlas icon: canvas size only, carried in the job.
			if jb.size() > 4:
				_cvw_size_mutex.lock()
				_cvw_size_results.append([jb[0], jb[1], jb[4], null])
				_cvw_size_mutex.unlock()
			continue
		var used = img.get_used_rect().size
		if used.x < 1 or used.y < 1:
			used = Vector2(img.get_width(), img.get_height())
		_cvw_size_mutex.lock()
		_cvw_size_results.append([jb[0], jb[1], used, jb[2]])
		_cvw_size_mutex.unlock()
	if fails.size() > 0:
		printerr("[SketchConv] size scan failures: ", fails)
	_cvw_size_mutex.lock()
	_cvw_size_results.append(null)
	_cvw_size_mutex.unlock()


# MAIN THREAD (tick): drain the results, refresh items and snapshots.
func _cvw_size_apply(key: String, oi: int, v: Vector2, path) -> void:
	if path != null:
		_cv_size_cache_load()
		_cv_size_cache[String(path).md5_text()] = str(int(v.x)) + "x" + str(int(v.y))
	var snap = _cvw_snaps.get(key)
	if snap == null or oi >= snap.size():
		return
	snap[oi]["rsz"] = v
	snap[oi]["sz"] = _cvw_size_str(key, v)
	var il = _cvw_lists.get(key)
	if il != null and is_instance_valid(il):
		for di in range(il.get_item_count()):
			if int(il.get_item_metadata(di)) == oi:
				il.set_item_text(di, snap[oi]["sz"])
				break


func _cvw_size_poll() -> void:
	# Imported default assets: resolve a few per frame through load()
	# (ResourceLoader follows the .import redirection File cannot see).
	var nb = 0
	while _cvw_size_mainq.size() > 0 and nb < 8:
		nb += 1
		var mq = _cvw_size_mainq.pop_front()
		var t = load(String(mq[2]))
		if t == null or not (t is Texture):
			continue
		var im2 = t.get_data()
		if im2 == null:
			continue
		if im2.is_compressed():
			im2.decompress()
		var used2 = im2.get_used_rect().size
		if used2.x < 1 or used2.y < 1:
			used2 = Vector2(im2.get_width(), im2.get_height())
		_cvw_size_apply(String(mq[0]), int(mq[1]), used2, String(mq[2]))
	if _cvw_size_thread == null:
		return
	_cvw_size_mutex.lock()
	var batch = _cvw_size_results
	_cvw_size_results = []
	_cvw_size_mutex.unlock()
	if batch.empty():
		return
	var finished = false
	for r in batch:
		if r == null:
			finished = true
			continue
		if String(r[0]) == "mainload":
			_cvw_size_mainq.append([r[1], r[2], r[3]])
			continue
		var key = r[0]
		var oi = int(r[1])
		var v = r[2]
		_cvw_size_apply(key, oi, v, r[3])
	if finished:
		_cvw_size_thread.wait_to_finish()
		_cvw_size_thread = null
		printerr("[SketchConv] visible-size scan finished (main-thread queue: ",
			_cvw_size_mainq.size(), " left)")
	if (finished or _cvw_size_done == false) and _cvw_size_thread == null \
			and _cvw_size_mainq.empty() and not _cvw_size_done:
		_cvw_size_done = true
		_cv_size_cache_save()
		for dk in ["wall", "door", "win"]:
			var sn2 = _cvw_snaps.get(dk)
			if sn2 == null:
				continue
			var miss = []
			for mi6 in range(sn2.size()):
				if sn2[mi6].get("rsz") == null and miss.size() < 4:
					var ic6 = sn2[mi6].get("icon")
					miss.append(str(mi6) + ":path=" + str(sn2[mi6].get("path") != null)
						+ ",icon=" + (ic6.get_class() if ic6 != null else "null"))
			if miss.size() > 0:
				printerr("[SketchConv] sizeless in ", dk, ": ", miss)


# Builds a wizard list by DUPLICATING the tool's GridMenu node: script,
# display setup and items come along, so the look matches the tool
# exactly. Signal connections are not copied, the owning tool never
# hears from the clone. Selected reads go to the SOURCE (the clone's
# private C# category field is not duplicated) except for Objects, where
# the clone is filled via its public Load("Objects").
func _cvw_make_list(key: String, tool_name: String):
	var src = null
	if key == "floor":
		src = _cvw_build_floor_source()
	elif tool_name == "ObjectTool":
		var dock = _find_node_named(Global.Editor.get_tree().get_root(), "ObjectLibrary")
		if dock != null:
			src = _find_gridmenu(dock)
		if src == null:
			src = _find_gridmenu(Global.Editor.get_tree().get_root())
	elif tool_name == "WallTool":
		src = _cvw_find_wall_list()
	else:
		# PortalTool: same Patch reparenting as walls, same registry.
		src = _cvw_tool_library(tool_name)
		if src == null:
			var panel = Global.Editor.Toolset.GetToolPanel(tool_name)
			if panel != null:
				src = _find_itemlist(panel)
	if src == null:
		printerr("[SketchConv] library not found for ", key)
		return null
	var il = src.duplicate()
	il.visible = true
	il.size_flags_vertical = Control.SIZE_EXPAND_FILL
	il.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var wsrc = src.rect_size.x
	if wsrc < 60.0:
		wsrc = 320.0
	il.rect_min_size = Vector2(min(max(wsrc, 420.0), 620.0), 0)
	if key == "pillar":
		# The dock menu only shows the current census/filter: fill the
		# clone with the whole Objects category (its own field is set by
		# the public Load call, the dock stays untouched).
		il.clear()
		il.Load("Objects")
		il.select_mode = ItemList.SELECT_MULTI
		# The theme font carries a thick OUTLINE that fills glyphs into
		# blocks (Moulk's catch), and zeroing it still left the
		# SELECTED item drawn with an outlined variant from the theme
		# chain: bypass the chain entirely with Godot's built-in
		# bitmap font, which has no outline in any state.
		il.theme = null
		var ftmp = Control.new()
		var good_font = ftmp.get_font("font")
		ftmp.free()
		if good_font != null and _ui_scale() > 1.01:
			# EnlargeUI: the hand-picked outline-safe font follows -
			# DD's effective DynamicFont when reachable, else the stock
			# one scaled by the factor.
			var effil = _ui_eff_font()
			if effil != null and effil is DynamicFont \
					and effil.get_height() > good_font.get_height() * 1.05:
				good_font = effil
			elif good_font is DynamicFont:
				good_font = good_font.duplicate()
				good_font.size = int(round(float(good_font.size) * _ui_scale()))
		if good_font != null:
			il.add_font_override("font", good_font)
		il.add_color_override("font_color", Color(1, 1, 1))
		il.add_color_override("font_color_selected", Color(1, 1, 1))
		_cvw_srcs[key] = il
	elif key == "door" or key == "win":
		# Several door/window styles at once: portals pick one at
		# random per placement.
		il.select_mode = ItemList.SELECT_MULTI
		_cvw_srcs[key] = src
	elif key == "floor":
		# Several floors at once: rooms pick one at random each.
		il.select_mode = ItemList.SELECT_MULTI
		_cvw_srcs[key] = src
	else:
		_cvw_srcs[key] = src
	# duplicate() does not carry the per-item icon modulates: copy them
	# from the source for EVERY page, or the thumbnails (and the color
	# handed to the conversion) stay white even after priming - walls
	# had the fix, the floor patterns hit the exact same trap.
	for wm in range(min(il.get_item_count(), src.get_item_count())):
		il.set_item_icon_modulate(wm, src.get_item_icon_modulate(wm))
	if key == "wall":
		# Mirrored continuation, clipped: each wall icon becomes a wide
		# strip (tile, mirrored tile, tile...) wrapped in an
		# AtlasTexture whose region is recropped on zoom - the preview
		# extends seamlessly and CLIPS at the frame instead of
		# stretching or pushing the size column out.
		_cvw_wall_strips = {}
		for wi in range(il.get_item_count()):
			var wic = il.get_item_icon(wi)
			if wic == null or not wic.has_method("get_data"):
				continue
			var wim = wic.get_data()
			if wim == null:
				continue
			if wim.is_compressed():
				wim.decompress()
			wim.convert(Image.FORMAT_RGBA8)
			var tw = wim.get_width()
			var th = wim.get_height()
			var strip = Image.new()
			strip.create(tw * 6, th, false, Image.FORMAT_RGBA8)
			var flipped = wim.duplicate()
			flipped.flip_x()
			for rep in range(6):
				var srcim = wim if rep % 2 == 0 else flipped
				strip.blit_rect(srcim, Rect2(Vector2(), Vector2(tw, th)), Vector2(tw * rep, 0))
			var stx = ImageTexture.new()
			stx.create_from_image(strip, Texture.FLAG_FILTER)
			var at = AtlasTexture.new()
			at.atlas = stx
			at.region = Rect2(0, 0, min(tw * 3, tw * 6), th)
			il.set_item_icon(wi, at)
			_cvw_wall_strips[wi] = [tw * 6, th]
	if il.get_item_count() > 0:
		il.select(0)
	# Snapshot for the search filter. Tooltips (display names) read from
	# the SOURCE list: duplicate() leaves them empty on the clones.
	var tipsrc = src
	if key == "pillar":
		tipsrc = il
	# Size text below the icon (ICON_MODE_TOP) everywhere except the
	# walls, whose size sits in its own column on the RIGHT (list
	# mode, same column width = aligned sizes).
	if key == "wall":
		il.icon_mode = ItemList.ICON_MODE_LEFT
		il.same_column_width = true
		il.fixed_column_width = int(il.fixed_icon_size.x + 45)
	else:
		il.icon_mode = ItemList.ICON_MODE_TOP
		il.fixed_column_width = int(il.fixed_icon_size.x + 10)
	var snap = []
	var n_paths = 0
	for i2 in range(il.get_item_count()):
		# GridMenu stores the asset's FILE PATH in the item metadata
		# (decompiled _Load) - but duplicate() does NOT copy item
		# metadata, so read it from the SOURCE list (indices align
		# 1:1); the pillar clone ran its own Load and carries paths
		# itself. Sizes are the VISIBLE pixel bounds, decoded by a
		# background thread (disk-cached across sessions).
		var apath = null
		if key == "pillar":
			apath = il.get_item_metadata(i2)
		elif src != null and is_instance_valid(src) and i2 < src.get_item_count():
			apath = src.get_item_metadata(i2)
		if not (apath is String) or apath == "":
			apath = null
		else:
			n_paths += 1
		il.set_item_metadata(i2, i2)
		var tip = ""
		if i2 < tipsrc.get_item_count():
			tip = tipsrc.get_item_tooltip(i2)
		var sz = ""
		var rsz = null
		if apath != null:
			rsz = _cv_size_cache_get(apath)
		if rsz != null:
			sz = _cvw_size_str(key, rsz)
			il.set_item_text(i2, sz)
		snap.append({"icon": il.get_item_icon(i2), "tip": tip,
			"mod": il.get_item_icon_modulate(i2), "sz": sz, "rsz": rsz,
			"path": apath})
	printerr("[SketchConv] list ", key, ": ", n_paths, "/", il.get_item_count(), " asset paths")
	_cvw_snaps[key] = snap
	for i3 in range(il.get_item_count()):
		if _cvw_is_fav(key, i3):
			il.set_item_custom_bg_color(i3, Color(0.25, 0.55, 0.25, 0.35))
	_cvw_base_icon[key] = il.fixed_icon_size
	if _cvw_base_icon[key].x <= 0.0:
		# No fixed size on the source: derive the base from the first
		# icon's native size so walls keep their wide aspect.
		if il.get_item_count() > 0 and il.get_item_icon(0) != null:
			_cvw_base_icon[key] = il.get_item_icon(0).get_size()
		else:
			_cvw_base_icon[key] = Vector2(56, 56)
	printerr("[SketchConv] list ", key, ": ", il.get_item_count(), " items")
	return il


func _find_gridmenu(node):
	if node is ItemList and node.has_method("ShowSet"):
		return node
	for c in node.get_children():
		var r = _find_gridmenu(c)
		if r != null:
			return r
	return null


# Real asset texture of a wizard list item: resolved from the metadata
# path, the thumbnail icon only as a last resort.
# Sort selector: recomputes the display order of the snapshot, then
# refilters. Favorites and selections key on ORIGINAL indices through
# the item metadata, so sorting never corrupts them.
func _cvw_sort_path() -> String:
	return "user://Sketch_Tool/wizard_sort.cfg"


func _cvw_sort_save() -> void:
	var dr = Directory.new()
	dr.make_dir_recursive("user://Sketch_Tool")
	var cf = ConfigFile.new()
	for k in _cvw_sort:
		cf.set_value("sort", String(k), int(_cvw_sort[k]))
	cf.set_value("sort_global", "mode", _cvw_sort_global)
	cf.save(_cvw_sort_path())


func _cvw_sort_load() -> void:
	var cf = ConfigFile.new()
	if cf.load(_cvw_sort_path()) != OK:
		return
	for k in cf.get_section_keys("sort") if cf.has_section("sort") else []:
		_cvw_sort[k] = int(cf.get_value("sort", k, 0))
	_cvw_sort_global = int(cf.get_value("sort_global", "mode", 0))


# User picked a sort on ONE tab: it becomes the shared mode for every
# tab that offers it. A tab lacking the option (Floor has no Size)
# falls back to ITS OWN last pick, without touching the others.
func _on_cvw_sort(mode: int, key: String) -> void:
	_cvw_sort[key] = mode
	_cvw_sort_global = mode
	_cvw_sort_save()
	for k in _cvw_lists:
		var eff = mode
		var sb = _cvw_sort_btns.get(k)
		if sb != null and is_instance_valid(sb) and mode >= sb.get_item_count():
			eff = int(_cvw_sort.get(k, 0))
		if sb != null and is_instance_valid(sb) and eff < sb.get_item_count():
			sb.select(eff)
		_cvw_apply_sort(String(k), eff)


func _on_cvw_pillar_scale(v: float) -> void:
	_cvw_pillar_scale = clamp(v, 0.5, 2.0)
	if not _cvw_pillar_scale_sync and _cvw_pillar_scale_spin != null \
			and is_instance_valid(_cvw_pillar_scale_spin):
		_cvw_pillar_scale_sync = true
		_cvw_pillar_scale_spin.value = round(_cvw_pillar_scale * 100.0)
		_cvw_pillar_scale_sync = false
	var il = _cvw_lists.get("pillar")
	var snap = _cvw_snaps.get("pillar")
	if snap != null and il != null and is_instance_valid(il):
		for i in range(snap.size()):
			if snap[i].get("rsz") != null:
				snap[i]["sz"] = _cvw_size_str("pillar", snap[i]["rsz"])
		# Refill WITHOUT losing the multi-selection (same recipe as
		# the zoom rebuild).
		var keep = _cvw_sel_origs(il)
		var q = ""
		if _cvw_search_edits.has("pillar") and is_instance_valid(_cvw_search_edits["pillar"]):
			q = _cvw_search_edits["pillar"].text
		_on_cvw_search(q, "pillar")
		if not keep.empty():
			il.unselect_all()
			for i2 in range(il.get_item_count()):
				if int(il.get_item_metadata(i2)) in keep:
					il.select(i2, false)


func _on_cvw_pillar_scale_pct(p: float) -> void:
	if _cvw_pillar_scale_sync:
		return
	_cvw_pillar_scale_sync = true
	# Drive THROUGH the slider: its value_changed runs the one true
	# update path (the spin write-back inside is guarded).
	if _cvw_pillar_scale_slider != null and is_instance_valid(_cvw_pillar_scale_slider):
		_cvw_pillar_scale_slider.value = p / 100.0
	else:
		_on_cvw_pillar_scale(p / 100.0)
	_cvw_pillar_scale_sync = false


func _on_cvw_wall_for_px(_idx: int = -1) -> void:
	if _cvw_wall_px_lbl == null or not is_instance_valid(_cvw_wall_px_lbl):
		return
	var txt = "Wall: ? px"
	var widx = _cvw_sel_orig(_cvw_lists.get("wall"))
	var snapw = _cvw_snaps.get("wall")
	if snapw != null and widx >= 0 and widx < snapw.size():
		var rs = snapw[widx].get("rsz")
		if rs != null:
			txt = "Wall: " + str(int(rs.y)) + " px"
	_cvw_wall_px_lbl.text = txt


# Recomputes one list's display order for a mode, then refilters.
func _cvw_apply_sort(key: String, mode: int) -> void:
	var snap = _cvw_snaps.get(key)
	if snap == null:
		return
	var order = []
	if mode == 0:
		order = range(snap.size())
	else:
		var tmp = []
		for i in range(snap.size()):
			var tip = String(snap[i]["tip"])
			var k2 = tip.to_lower()
			if mode == 1:
				# A-Z on the asset NAME alone: tooltips start with the
				# pack, so the raw string grouped pack by pack.
				k2 = _cvw_tip_name(tip).to_lower()
			elif mode == 3:
				var rs = snap[i].get("rsz")
				var a = 0
				if rs != null:
					if key == "wall":
						a = int(rs.y)
					else:
						# Portals and pillars: the WIDTH is the size
						# that matters for placement.
						a = int(rs.x)
				k2 = "%012d" % a
			tmp.append([k2, i])
		tmp.sort_custom(self, "_cvw_pair_less")
		for t2 in tmp:
			order.append(int(t2[1]))
	_cvw_order[key] = order
	var q = ""
	if _cvw_search_edits.has(key) and is_instance_valid(_cvw_search_edits[key]):
		q = _cvw_search_edits[key].text
	_on_cvw_search(q, key)


func _cvw_pair_less(a, b) -> bool:
	if a[0] == b[0]:
		return int(a[1]) < int(b[1])
	return String(a[0]) < String(b[0])


# The asset NAME from a tooltip that may be prefixed by its pack: take
# what follows the last separator, or the whole string.
func _cvw_tip_name(tip: String) -> String:
	var best = -1
	for sep in ["\n", "/", ": ", " - "]:
		var i = tip.find_last(sep)
		if i >= 0:
			var cut = i + sep.length()
			if cut > best:
				best = cut
	if best >= 0 and best < tip.length():
		return tip.substr(best)
	return tip


func _on_cvw_search(text: String, key: String) -> void:
	var il = _cvw_lists.get(key)
	var snap = _cvw_snaps.get(key)
	if il == null or snap == null:
		return
	var q = text.strip_edges().to_lower()
	var favs_only = false
	var used_only = false
	var tabs2 = _cvw_fav_toggles.get(key)
	if tabs2 != null and is_instance_valid(tabs2[1]):
		favs_only = tabs2[1].pressed
	if tabs2 != null and tabs2.size() > 2 and is_instance_valid(tabs2[2]):
		used_only = tabs2[2].pressed
	var uset = {}
	if used_only:
		uset = _cvw_used_set(key)
	il.clear()
	var order = _cvw_order.get(key)
	if order == null or order.size() != snap.size():
		order = range(snap.size())
	for i in order:
		if q != "" and String(snap[i]["tip"]).to_lower().find(q) < 0:
			continue
		if favs_only and not _cvw_is_fav(key, i):
			continue
		if used_only:
			var uok = _cvw_path_used(uset, snap[i].get("path"))
			if not uok and key == "floor":
				uok = _cvw_path_used(uset, _cvw_floor_used_ref(i))
				if not uok and i < _cvw_floor_map.size() \
						and String(_cvw_floor_map[i][0]) == "pat":
					uok = uset.has("pati:" + str(int(_cvw_floor_map[i][1])))
			if not uok:
				continue
		il.add_item(String(snap[i].get("sz", "")), snap[i]["icon"])
		var ni = il.get_item_count() - 1
		il.set_item_icon_modulate(ni, snap[i]["mod"])
		il.set_item_tooltip(ni, snap[i]["tip"])
		il.set_item_metadata(ni, i)
		if _cvw_is_fav(key, i):
			il.set_item_custom_bg_color(ni, Color(0.25, 0.55, 0.25, 0.35))
	if il.get_item_count() > 0:
		il.select(0)


# Original (unfiltered) index of the selected item of a wizard list.
# ---- Soft Shadows mod discovery (no hard dependency) ----------------------
# DropShadowWalls / DropShadowObjects connect to World.OnAssignNode; their
# instances are identified by their own constants. BuildingShadow publishes
# a listener node whose handler is its instance.

func _softshadows_walls_inst():
	return _softshadows_find("SHADOW_DATA_KEY", "DropShadow")


func _softshadows_objects_inst():
	return _softshadows_find("SHADOW_META_KEY", "drop_shadow_obj_nodes")


func _softshadows_find(prop: String, value: String):
	if Global.World == null or not is_instance_valid(Global.World):
		return null
	for c in Global.World.get_signal_connection_list("OnAssignNode"):
		var t = c.get("target")
		if t != null and is_instance_valid(t) and String(t.get(prop)) == value:
			return t
	return null


func _softshadows_building_inst():
	if Engine.has_meta("SoftShadowsBuildingShadowListener"):
		var n = Engine.get_meta("SoftShadowsBuildingShadowListener")
		if n != null and is_instance_valid(n):
			var h = n.get("handler")
			if h != null and is_instance_valid(h):
				return h
	return null


func _cvw_last_path() -> String:
	return "user://Sketch_Tool/last_convert.cfg"


func _cvw_save_last() -> void:
	if _cvw == null:
		return
	var cf = ConfigFile.new()
	var widx2 = int(max(0, _cvw_sel_orig(_cvw_lists["wall"])))
	cf.set_value("last", "wall_tip", _cvw_tip("wall", widx2))
	cf.set_value("last", "door_tip", _cvw_tip("door", _cvw_sel_orig(_cvw_lists.get("door"))))
	cf.set_value("last", "win_tip", _cvw_tip("win", _cvw_sel_orig(_cvw_lists.get("win"))))
	var ptips = []
	var pil = _cvw_lists.get("pillar")
	if pil != null and is_instance_valid(pil):
		for si5 in pil.get_selected_items():
			ptips.append(_cvw_tip("pillar", _cvw_sel_orig_at(pil, int(si5))))
	cf.set_value("last", "pillar_tips", ptips)
	for tk in ["shadow", "bevel", "pillars", "pillar_rand", "use_floor", "soft_walls", "soft_building", "soft_pillars"]:
		cf.set_value("last", tk, bool(_cvw.get(tk, false)))
	# Floor picks travel with the quick-conversion settings, or the
	# quick button restored use_floor with an empty selection and the
	# floor stage bailed with "nothing selected".
	var fps = []
	for pk in _cvw.get("floor_picks", []):
		fps.append(String(pk[0]) + ":" + str(int(pk[1])))
	cf.set_value("last", "floor_picks", fps)
	var dr2 = Directory.new()
	dr2.make_dir_recursive("user://Sketch_Tool")
	cf.save(_cvw_last_path())


func _cvw_tip(key: String, orig: int) -> String:
	var snap = _cvw_snaps.get(key)
	if snap == null or orig < 0 or orig >= snap.size():
		return ""
	return String(snap[orig]["tip"])


func _cvw_orig_by_tip(key: String, tip: String) -> int:
	if tip == "":
		return -1
	var snap = _cvw_snaps.get(key)
	if snap == null:
		return -1
	for i in range(snap.size()):
		if String(snap[i]["tip"]) == tip:
			return i
	return -1


func _cvw_sel_orig_at(il, idx: int) -> int:
	var meta = il.get_item_metadata(idx)
	if meta != null and typeof(meta) == TYPE_INT:
		return int(meta)
	return idx


func _cvw_apply_previous() -> void:
	if _canvas_empty():
		_float_toast("Canvas is empty, conversion aborted.")
		return
	# The saved settings resolve through the wizard's list snapshots
	# (tips -> indices -> textures): if the wizard was never opened
	# this session, build it SILENTLY first - the dialog stays hidden,
	# only the snapshots matter.
	if _cvw_dlg != null and not is_instance_valid(_cvw_dlg):
		_cvw_dlg = null
	if _cvw_prime_wall_colors() and _cvw_dlg != null:
		_cvw_dlg.queue_free()
		_cvw_dlg = null
	if _cvw_dlg == null:
		_cvw_build()
	if _cvw_dlg == null or not is_instance_valid(_cvw_dlg):
		printerr("[SketchConv] wall library unreachable: converting without settings")
		_cv_start_vectorize()
		return
	var cf = ConfigFile.new()
	if cf.load(_cvw_last_path()) != OK:
		_float_toast("No previous conversion settings found.")
		printerr("[SketchConv] no previous settings saved")
		return
	var widx3 = _cvw_orig_by_tip("wall", String(cf.get_value("last", "wall_tip", "")))
	if widx3 < 0:
		printerr("[SketchConv] previous wall not found in the current libraries")
		return
	var door_orig = _cvw_orig_by_tip("door", String(cf.get_value("last", "door_tip", "")))
	var win_orig = _cvw_orig_by_tip("win", String(cf.get_value("last", "win_tip", "")))
	var ptex_list = []
	for pt6 in cf.get_value("last", "pillar_tips", []):
		var po = _cvw_orig_by_tip("pillar", String(pt6))
		var pil2 = _cvw_lists.get("pillar")
		if po >= 0 and pil2 != null and is_instance_valid(pil2):
			var found = -1
			for ii in range(pil2.get_item_count()):
				if int(pil2.get_item_metadata(ii)) == po:
					found = ii
					break
			if found >= 0:
				pil2.select(found)
				var ttx = pil2.Selected
				if ttx != null:
					ptex_list.append(ttx)
	_cvw = {
		"wall_tex": _cvw_item_tex("wall", _cvw_lists["wall"], widx3),
		"wall_col": _cvw_snaps["wall"][widx3]["mod"],
		"shadow": bool(cf.get_value("last", "shadow", false)),
		"bevel": bool(cf.get_value("last", "bevel", false)),
		"pillars": bool(cf.get_value("last", "pillars", false)),
		"use_floor": bool(cf.get_value("last", "use_floor", false)),
		"floor_picks": _cvw_parse_floor_picks(cf.get_value("last", "floor_picks", [])),
		"pillar_scale": _cvw_pillar_scale,
		"pillar_rand": bool(cf.get_value("last", "pillar_rand", false)),
		"soft_walls": bool(cf.get_value("last", "soft_walls", false)),
		"soft_building": bool(cf.get_value("last", "soft_building", false)),
		"soft_pillars": bool(cf.get_value("last", "soft_pillars", false)),
		"pillar_tex": ptex_list[0] if ptex_list.size() > 0 else null,
		"pillar_texs": ptex_list,
		"door_tex": null if door_orig <= 0 else _cvw_item_tex("door", _cvw_lists["door"], door_orig),
		"win_tex": null if win_orig <= 0 else _cvw_item_tex("win", _cvw_lists["win"], win_orig)
	}
	_cvw_dlg.hide()
	_cv_start_vectorize()


func _cvw_favs_path() -> String:
	return "user://Sketch_Tool/wizard_favs.cfg"


func _cvw_load_favs() -> void:
	_cvw_favs = {}
	var cf = ConfigFile.new()
	if cf.load(_cvw_favs_path()) != OK:
		return
	for sec in cf.get_sections():
		var d = {}
		for k in cf.get_section_keys(sec):
			d[k] = true
		_cvw_favs[sec] = d


func _cvw_save_favs() -> void:
	var dr = Directory.new()
	dr.make_dir_recursive("user://Sketch_Tool")
	var cf = ConfigFile.new()
	for sec in _cvw_favs:
		for k in _cvw_favs[sec]:
			cf.set_value(sec, k, true)
	cf.save(_cvw_favs_path())


func _on_cvw_tab(key: String, which: int) -> void:
	# 0 = All, 1 = Used, 2 = Favorites.
	var tabs = _cvw_fav_toggles.get(key)
	if tabs != null:
		tabs[0].pressed = which == 0
		tabs[1].pressed = which == 2
		if tabs.size() > 2:
			tabs[2].pressed = which == 1
	if which == 1:
		# Fresh scan on every visit: the map may have changed.
		_cvw_used_cache.erase(key)
	var q = ""
	if _cvw_search_edits.has(key) and is_instance_valid(_cvw_search_edits[key]):
		q = _cvw_search_edits[key].text
	_on_cvw_search(q, key)


# Set of asset paths (full path AND bare file name, lowercased) used on
# the map for a list's type: walls, portals (doors and windows share the
# pool), placed objects, pattern shapes. Every level is scanned; pattern
# layers go through GetShapes() (their children are LAYER nodes).
func _cvw_used_set(key: String) -> Dictionary:
	if _cvw_used_cache.has(key):
		return _cvw_used_cache[key]
	var out = {}
	var conts = []
	if key == "wall":
		conts = ["Walls"]
	elif key == "door" or key == "win":
		# Freestanding portals; the wall-attached ones (the common
		# case) are harvested from the walls below.
		conts = ["Portals", "Walls"]
	elif key == "pillar":
		conts = ["Objects"]
	elif key == "floor":
		# Patterns AND smart-tile floors: the floor page mixes both.
		conts = ["PatternShapes", "FloorShapes"]
	var lvls = []
	if Global.World != null and is_instance_valid(Global.World):
		var wl = Global.World.get("levels")
		if wl == null:
			wl = Global.World.get("Levels")
		if wl != null:
			for l in wl:
				lvls.append(l)
		elif Global.World.get("Level") != null:
			lvls.append(Global.World.get("Level"))
	for lvl in lvls:
		if lvl == null or not is_instance_valid(lvl):
			continue
		for cn in conts:
			var cont = lvl.get(cn)
			if cont == null or not (cont is Node):
				continue
			var kids = []
			if cn == "PatternShapes" and cont.has_method("GetShapes"):
				kids = cont.GetShapes()
				# The texture rides the LAYER nodes (shapes batch by
				# texture): harvest layers and shape parents too.
				for ci0 in range(cont.get_child_count()):
					kids.append(cont.get_child(ci0))
				for sh in cont.GetShapes():
					if sh != null and is_instance_valid(sh) and sh.get_parent() != null:
						if not (sh.get_parent() in kids):
							kids.append(sh.get_parent())
			else:
				for ci in range(cont.get_child_count()):
					kids.append(cont.get_child(ci))
			for k in kids:
				if k == null or not is_instance_valid(k):
					continue
				if cn == "Walls":
					if key == "wall":
						_cvw_used_add(out, k)
					else:
						# Portal harvest: portals ride their wall in
						# wall.Portals, NOT under level.Portals.
						var wps = k.get("Portals")
						if wps != null:
							for wp in wps:
								if wp != null and is_instance_valid(wp):
									_cvw_used_add(out, wp)
				else:
					_cvw_used_add(out, k)
	if key == "door" or key == "win":
		_cvw_used_cross_objects(out, key, lvls, "Objects")
	elif key == "wall":
		# Same twin logic for walls: a placed PATH with a wall-asset
		# name from the same pack lights up its wall counterpart.
		_cvw_used_cross_objects(out, key, lvls, "Pathways")
	if key == "floor":
		# Pack textures often carry NO resource_path: join by texture
		# INSTANCE instead. The pattern GridMenu is swept once (its
		# OnItemSelected resolves each item's full-res library
		# texture), mapping used instances back to item indices.
		var ridm = _cvw_pat_rid_map()
		for rk in out.keys():
			if String(rk).begins_with("rid:") and ridm.has(rk):
				out["pati:" + str(int(ridm[rk]))] = true
	_cvw_used_cache[key] = out
	return out


# DD ships many assets in TWO categories: doors/windows as portals and
# as objects, wall textures as walls and as paths. A placed node from
# cont_name whose name matches a list asset, from the SAME pack, with
# the MAJOR axis within 15%, marks the list twin as used. Size checks
# are skipped when either side is unknown.
func _cvw_used_cross_objects(out: Dictionary, key: String, lvls: Array, cont_name: String) -> void:
	var snapp = _cvw_snaps.get(key)
	if snapp == null:
		return
	var by_name = {}
	for si in range(snapp.size()):
		var e = snapp[si]
		var cands = [String(e.get("tip", ""))]
		if e.get("path") is String:
			cands.append(String(e["path"]).get_file())
		for cand in cands:
			var nn = _cvw_norm_name(cand)
			if nn == "":
				continue
			if not by_name.has(nn):
				by_name[nn] = []
			if not (si in by_name[nn]):
				by_name[nn].append(si)
	for lvl in lvls:
		if lvl == null or not is_instance_valid(lvl):
			continue
		var cont = lvl.get(cont_name)
		if cont == null or not (cont is Node):
			continue
		for ci in range(cont.get_child_count()):
			var k = cont.get_child(ci)
			if k == null or not is_instance_valid(k):
				continue
			var tx = k.get("Texture")
			if tx == null:
				tx = k.get("texture")
			if tx == null and k.has_method("get_texture"):
				tx = k.get_texture()
			if tx == null or not (tx is Texture):
				continue
			var op = String(tx.resource_path)
			var nn2 = _cvw_norm_name(op.get_file())
			if nn2 == "" or not by_name.has(nn2):
				continue
			if op == "":
				# Same-pack requirement: no path, no provenance.
				continue
			var opack = _cvw_pack_root(op)
			if opack == "":
				continue
			var osz = _cv_size_cache_get(op)
			if osz == null:
				osz = tx.get_size()
			for si2 in by_name[nn2]:
				var e2 = snapp[si2]
				var pth = e2.get("path")
				if not (pth is String) or String(pth) == "":
					continue
				if _cvw_pack_root(String(pth)) != opack:
					continue
				var rsz = e2.get("rsz")
				var ok = true
				if rsz != null and osz != null and osz.x > 0 and osz.y > 0:
					# MAJOR axis only: the portal variant is flattened
					# to the wall band (a 260 px deep object window is
					# a 52 px strip as a portal), so the thin axis says
					# nothing. The long axis still splits 1x1 from 2x1.
					var a = max(osz.x, osz.y)
					var b = max(rsz.x, rsz.y)
					ok = b > 0.0 and abs(a / b - 1.0) <= 0.15
				if not ok:
					continue
				out[String(pth).to_lower()] = true
				out[String(pth).get_file().to_lower()] = true


# Pack root of an asset path: everything before its "/textures/"
# segment ("" when the layout is unrecognized, which fails the
# same-pack requirement on purpose).
func _cvw_pack_root(p: String) -> String:
	var lp = p.to_lower().replace("\\", "/")
	var ix = lp.find("/textures/")
	if ix < 0:
		return ""
	return lp.substr(0, ix)


# Loose asset-name normalization: lowercase, extension dropped, every
# non-alphanumeric squeezed out ("Wood Door" == "wood_door.png").
func _cvw_norm_name(sname: String) -> String:
	var b = sname.to_lower()
	var dot = b.rfind(".")
	if dot > 0 and b.length() - dot <= 5:
		b = b.substr(0, dot)
	var outn = ""
	for i in range(b.length()):
		var c = b[i]
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			outn += c
	return outn


# Collects every match key a placed node offers: its Texture's full
# path and bare file name, plus a "tile:<id>" key for smart-tile floor
# shapes (their identity is the tile id, not a texture path).
func _cvw_used_add(out: Dictionary, k) -> void:
	# C# nodes expose "Texture", pattern shapes are plain Polygon2D
	# with Godot's lowercase "texture" - and PATTERNS carry theirs as
	# a sampler2D uniform on their ShaderMaterial (Pattern.material),
	# resolved generically below.
	var tx = k.get("Texture")
	if tx == null:
		tx = k.get("texture")
	_cvw_used_add_tex(out, tx)
	var mat = k.get("material")
	if mat != null and mat is ShaderMaterial and mat.shader != null:
		for un in _cvw_shader_tex_uniforms(mat.shader):
			_cvw_used_add_tex(out, mat.get_shader_param(un))
	var tid = k.get("SmartTileId")
	if tid == null:
		tid = k.get("TileId")
	if tid != null and (tid is int or tid is float):
		out["tile:" + str(int(tid))] = true


func _cvw_used_add_tex(out: Dictionary, tx) -> void:
	if tx == null or not (tx is Texture):
		return
	out["rid:" + str(tx.get_instance_id())] = true
	var rp = String(tx.resource_path)
	if rp != "":
		out[rp.to_lower()] = true
		out[rp.get_file().to_lower()] = true


# sampler2D uniform names of a shader, parsed once from its source and
# cached by shader instance.
var _cvw_shader_uniform_cache = {}
func _cvw_shader_tex_uniforms(sh) -> Array:
	var sid = sh.get_instance_id()
	if _cvw_shader_uniform_cache.has(sid):
		return _cvw_shader_uniform_cache[sid]
	var names = []
	for line in String(sh.code).split("\n"):
		var l = line.strip_edges()
		var ix = l.find("sampler2D")
		if not l.begins_with("uniform") or ix < 0:
			continue
		var rest = l.substr(ix + 9, l.length()).strip_edges()
		var endn = rest.length()
		for ci in range(rest.length()):
			var c = rest[ci]
			if not ((c >= "a" and c <= "z") or (c >= "A" and c <= "Z") \
					or (c >= "0" and c <= "9") or c == "_"):
				endn = ci
				break
		if endn > 0:
			names.append(rest.substr(0, endn))
	_cvw_shader_uniform_cache[sid] = names
	return names


# Sweeps the pattern GridMenu once: "rid:<texture instance>" ->
# item index. The current selection (texture AND default color wiring)
# is restored afterwards.
func _cvw_pat_rid_map() -> Dictionary:
	var mapd = {}
	var pat_tool = Global.Editor.Tools.get("PatternShapeTool")
	if pat_tool == null:
		return mapd
	var ctl = pat_tool.get("Controls")
	if ctl == null or not ctl.has("Texture"):
		return mapd
	var gm = ctl["Texture"]
	var prev = -1
	var psel = gm.get_selected_items()
	if psel.size() > 0:
		prev = psel[0]
	for gi in range(1, gm.get_item_count()):
		gm.select(gi)
		gm.call("OnItemSelected", gi)
		var t = pat_tool.get("Texture")
		if t != null and t is Texture:
			mapd["rid:" + str(t.get_instance_id())] = gi
	if prev >= 0:
		gm.select(prev)
		gm.call("OnItemSelected", prev)
	return mapd


# Match reference of a FLOOR page item (its snap has no path): pattern
# items resolve through the pattern GridMenu's metadata, smart tiles
# through their "tile:<id>" key.
func _cvw_floor_used_ref(orig: int):
	if orig < 0 or orig >= _cvw_floor_map.size():
		return null
	var fm = _cvw_floor_map[orig]
	if String(fm[0]) == "tile":
		return "tile:" + str(int(fm[1]))
	var pat_tool = Global.Editor.Tools.get("PatternShapeTool")
	if pat_tool == null:
		return null
	var ctl = pat_tool.get("Controls")
	if ctl == null or not ctl.has("Texture"):
		return null
	var gm = ctl["Texture"]
	var gi = int(fm[1])
	if gi < 0 or gi >= gm.get_item_count():
		return null
	var md = gm.get_item_metadata(gi)
	return md if md is String and md != "" else null


func _cvw_path_used(uset: Dictionary, p) -> bool:
	if not (p is String) or String(p) == "":
		return false
	var lp = String(p).to_lower()
	if uset.has(lp):
		return true
	return uset.has(lp.get_file())


func _on_cvw_list_gui(event, key: String) -> void:
	if event is InputEventMouseButton and event.button_index == BUTTON_LEFT \
			and event.pressed and event.shift:
		# Shift+click on a SELECTED item deselects it (any page); the
		# built-in only offers ctrl-toggle and shift-range.
		var ils = _cvw_lists.get(key)
		if ils != null and is_instance_valid(ils):
			var hit = ils.get_item_at_position(event.position, true)
			if hit >= 0 and ils.is_selected(hit):
				ils.unselect(hit)
				ils.accept_event()
		return
	if not (event is InputEventMouseButton and event.button_index == BUTTON_RIGHT and event.pressed):
		return
	var il = _cvw_lists.get(key)
	var snap = _cvw_snaps.get(key)
	if il == null or snap == null:
		return
	var idx = il.get_item_at_position(il.get_local_mouse_position(), true)
	if idx < 0:
		return
	var orig = int(il.get_item_metadata(idx))
	var tip = String(snap[orig]["tip"])
	if tip == "":
		tip = "#" + str(orig)
	if not _cvw_favs.has(key):
		_cvw_favs[key] = {}
	if _cvw_favs[key].has(tip):
		_cvw_favs[key].erase(tip)
	else:
		_cvw_favs[key][tip] = true
	_cvw_save_favs()
	# Refresh the row tint in place (green = in the Custom Selection).
	if _cvw_favs[key].has(tip):
		il.set_item_custom_bg_color(idx, Color(0.25, 0.55, 0.25, 0.35))
	else:
		il.set_item_custom_bg_color(idx, Color(0, 0, 0, 0))


func _cvw_is_fav(key: String, orig: int) -> bool:
	if not _cvw_favs.has(key):
		return false
	var snap = _cvw_snaps.get(key)
	if snap == null or orig >= snap.size():
		return false
	var tip = String(snap[orig]["tip"])
	if tip == "":
		tip = "#" + str(orig)
	return _cvw_favs[key].has(tip)


# Default preview scale computed from the real list width so FOUR
# columns fit (the stock icon size left the lists one column short).
# The zoom slider starts at that fitted value and stays adjustable.
func _cvw_fit_columns() -> bool:
	# Hidden tab pages keep a zero rect until first shown, so the fit
	# derives from the DIALOG width, which is valid for every page as
	# soon as the popup laid out.
	if _cvw_dlg == null or not is_instance_valid(_cvw_dlg) \
			or _cvw_dlg.rect_size.x < 300.0:
		return false
	# Dialog minus the options column, panel margins and the list's
	# scrollbar; split four ways minus the column separation.
	var avail = _cvw_dlg.rect_size.x - 250.0 * _ui_scale() - 50.0
	var per_col = avail / 4.0 - 8.0
	if per_col < 40.0:
		return true
	for key in _cvw_lists:
		if key == "wall":
			# Walls are full-width strips, one per row by design.
			continue
		var il = _cvw_lists.get(key)
		if il == null or not is_instance_valid(il) or not _cvw_base_icon.has(key):
			continue
		var base = _cvw_base_icon[key]
		if base.x <= 0.0:
			continue
		# Snapped DOWN to the slider's 0.05 grid: the slider rounds an
		# arbitrary value to the NEAREST step, and one step too wide is
		# exactly one column short.
		var fit = clamp(per_col / base.x, 0.3, 1.0)
		fit = floor(fit / 0.05) * 0.05
		# The width calibration below reads the PRE-drop value: the max
		# is tuned and must not shift with the default.
		var fit_cal = fit
		# Same unmodelled per-column separation as the max: one step
		# below the theoretical fit is the real four-column threshold.
		fit -= 0.05
		var zs = _cvw_zoom_sliders.get(key)
		if zs != null and is_instance_valid(zs):
			# The MAX also snaps to tight packing: the stock 1.95 left
			# a nearly-column-wide dead strip on some pages. The width
			# is re-derived from the four-column fit itself (which is
			# known to be right) instead of the rough dialog estimate,
			# whose optimism left the max several steps too high.
			var avail_c = 4.0 * (base.x * fit_cal + 10.0)
			# CEIL, not floor: with one oversized column the tight value
			# exploded past 1.95 and the clamp silently kept the stock
			# max. The max is the largest zoom whose column count still
			# packs the width with no dead strip.
			var n_max = int(max(1.0, ceil(avail_c / (base.x * 1.95 + 10.0))))
			var tight = (avail_c / float(n_max) - 10.0) / base.x
			# One extra step down: the per-column separation the list
			# adds on top of fixed_column_width isn't in the model.
			tight = floor(tight / 0.05) * 0.05 - 0.05
			zs.max_value = clamp(tight, fit + 0.05, 1.95)
			if abs(zs.value - fit) > 0.02:
				# Drives _on_cvw_zoom through the slider so UI and list
				# agree.
				zs.value = fit
		else:
			_on_cvw_zoom(fit, key)
	return true


func _on_cvw_zoom(v: float, key: String) -> void:
	var il = _cvw_lists.get(key)
	if il == null or not _cvw_base_icon.has(key):
		return
	il.fixed_icon_size = _cvw_base_icon[key] * v
	if key == "wall":
		# The size column stays in frame at ANY zoom: the box height
		# follows the slider, the width is capped to the visible list
		# width, and each strip's Atlas region is recropped to the
		# box's exact aspect - mirrored continuation, clipped, never
		# stretched.
		var avail = 200.0
		if il.rect_size.x > 40.0:
			avail = max(120.0, il.rect_size.x - 60.0)
		var hbox = _cvw_base_icon[key].y * v
		il.fixed_icon_size = Vector2(avail, hbox)
		il.fixed_column_width = int(avail + 45)
		var snapw = _cvw_snaps.get("wall")
		if snapw != null:
			for oi2 in _cvw_wall_strips:
				if oi2 >= snapw.size():
					continue
				var at2 = snapw[oi2]["icon"]
				if at2 == null or not at2 is AtlasTexture:
					continue
				var sw = float(_cvw_wall_strips[oi2][0])
				var sh = float(_cvw_wall_strips[oi2][1])
				at2.region = Rect2(0, 0, min(sw, sh * avail / max(1.0, hbox)), sh)
	else:
		il.fixed_column_width = int(il.fixed_icon_size.x + 10)
	# Rebuild the items: ItemList keeps stale item rects after a fixed
	# icon size change and thumbnails overlap otherwise. The refill also
	# restores the current selection by original index - the WHOLE set
	# on multi-select lists, not just the last pick (the refill's
	# select(0) default is cleared first so no phantom stays selected).
	var keep = _cvw_sel_origs(il)
	var q = ""
	if _cvw_search_edits.has(key) and is_instance_valid(_cvw_search_edits[key]):
		q = _cvw_search_edits[key].text
	_on_cvw_search(q, key)
	if not keep.empty():
		il.unselect_all()
		for i in range(il.get_item_count()):
			if int(il.get_item_metadata(i)) in keep:
				il.select(i, false)


# Original indices of EVERY selected item (multi-select lists: doors,
# windows, pillars, floors keep their whole pick set).
func _cvw_sel_origs(il) -> Array:
	var out = []
	if il == null or not is_instance_valid(il):
		return out
	for i in il.get_selected_items():
		var md = il.get_item_metadata(i)
		if md != null:
			out.append(int(md))
	return out


func _cvw_sel_orig(il) -> int:
	if il.get_selected_items().empty():
		return -1
	var idx = int(il.get_selected_items()[0])
	var meta = il.get_item_metadata(idx)
	if meta != null and typeof(meta) == TYPE_INT:
		return int(meta)
	return idx


func _cvw_item_tex(key: String, il, idx: int):
	if key == "pillar":
		# The pillar clone resolves by itself: Selected seeks by the
		# CURRENT selected icon, index-free, so search filters are safe.
		var psrc = _cvw_srcs.get(key)
		if psrc != null and is_instance_valid(psrc):
			var pt = psrc.Selected
			if pt != null:
				return pt
	var src = _cvw_srcs.get(key)
	if src != null and is_instance_valid(src) and idx < src.get_item_count() \
			and src.has_method("ShowSet"):
		# Select on the SOURCE GridMenu and read its Selected property:
		# Library.Seek resolves the real asset, including custom pack OS
		# paths that load() cannot reach. select() emits no signal, the
		# owning tool never notices; previous selection restored after.
		# Guarded to genuine GridMenus (ShowSet) and read through get():
		# poking a C# property on any other list is a crash, not an
		# error.
		var prev = src.get_selected_items()
		src.select(idx)
		var t = src.get("Selected")
		if prev.size() > 0:
			src.select(int(prev[0]))
		else:
			src.unselect_all()
		if t != null:
			return t
	printerr("[SketchConv] real texture unresolved for ", key, " item ", idx)
	return il.get_item_icon(idx)


func _cvw_show_page() -> void:
	_on_cvw_wall_for_px()
	for i in range(_cvw_pages.size()):
		_cvw_pages[i].visible = i == _cvw_page
	var autos = {1: ["door", "door"], 2: ["win", "window"], 3: ["pillar", "pillar"]}
	if autos.has(_cvw_page):
		var ak = autos[_cvw_page][0]
		var aq = autos[_cvw_page][1]
		if _cvw_search_edits.has(ak):
			var pe = _cvw_search_edits[ak]
			if is_instance_valid(pe) and pe.text == "":
				pe.text = aq
				_on_cvw_search(aq, ak)
	for ti in range(_cvw_tab_btns.size()):
		if is_instance_valid(_cvw_tab_btns[ti]):
			_cvw_tab_btns[ti].pressed = ti == _cvw_page
	if _cvw_btn != null:
		_cvw_btn.text = "Next"
		_cvw_btn.visible = _cvw_page < _cvw_pages.size() - 1
	if _cvw_go_btn != null and is_instance_valid(_cvw_go_btn):
		_cvw_go_btn.visible = _cvw_page == _cvw_pages.size() - 1
	if _cvw_area_btn != null and is_instance_valid(_cvw_area_btn):
		_cvw_area_btn.visible = false
	if _cvw_page == _cvw_pages.size() - 1:
		_cvw_fill_summary()
	if _cvw_back != null:
		_cvw_back.visible = true
		_cvw_back.disabled = _cvw_page == 0


func _on_cvw_next() -> void:
	# Strictly linear, grayed tabs included: Walls -> Pillars -> Doors
	# -> Windows -> Summary.
	if _cvw_page < _cvw_pages.size() - 1:
		_cvw_page += 1
		_cvw_show_page()


func _on_cvw_back() -> void:
	if _cvw_page > 0:
		_cvw_page -= 1
		_cvw_show_page()


# Reapplies the last conversion's selections to the freshly built
# wizard lists: walls/doors/windows by remembered TOOLTIP (stable
# across sessions), pillars by tooltip multi, floors through the
# persisted kind:index pairs mapped back to list rows. Deferred from
# the build so the lists are fully populated (metadata = orig index).
func _cvw_preselect_last() -> void:
	var cf = ConfigFile.new()
	if cf.load(_cvw_last_path()) != OK:
		return
	for pr in [["wall", "wall_tip"], ["door", "door_tip"], ["win", "win_tip"]]:
		var tip = String(cf.get_value("last", pr[1], ""))
		if tip == "":
			continue
		var oi = _cvw_orig_by_tip(pr[0], tip)
		var il = _cvw_lists.get(pr[0])
		if oi < 0 or il == null or not is_instance_valid(il):
			continue
		for ii in range(il.get_item_count()):
			var md = il.get_item_metadata(ii)
			if md != null and int(md) == oi:
				il.select(ii)
				break
	var pil = _cvw_lists.get("pillar")
	if pil != null and is_instance_valid(pil):
		for pt in cf.get_value("last", "pillar_tips", []):
			var po = _cvw_orig_by_tip("pillar", String(pt))
			if po < 0:
				continue
			for ii2 in range(pil.get_item_count()):
				var md2 = pil.get_item_metadata(ii2)
				if md2 != null and int(md2) == po:
					pil.select(ii2, false)
					break
	var fil = _cvw_lists.get("floor")
	if fil != null and is_instance_valid(fil):
		for pk in _cvw_parse_floor_picks(cf.get_value("last", "floor_picks", [])):
			var target = -1
			for mi in range(_cvw_floor_map.size()):
				if String(_cvw_floor_map[mi][0]) == String(pk[0]) \
						and int(_cvw_floor_map[mi][1]) == int(pk[1]):
					target = mi
					break
			if target < 0:
				continue
			for ii3 in range(fil.get_item_count()):
				var md3 = fil.get_item_metadata(ii3)
				if md3 != null and int(md3) == target:
					fil.select(ii3, false)
					break


func _cvw_parse_floor_picks(raw) -> Array:
	var out = []
	if raw is Array:
		for e in raw:
			var parts = String(e).split(":")
			if parts.size() == 2:
				out.append([parts[0], int(parts[1])])
	return out


# Selected floors as [kind, tool index] pairs through the map.
func _cvw_floor_picks() -> Array:
	var out = []
	var il = _cvw_lists.get("floor")
	if il == null or not is_instance_valid(il):
		return out
	for si in il.get_selected_items():
		var oi = _cvw_sel_orig_at(il, int(si))
		if oi >= 0 and oi < _cvw_floor_map.size():
			out.append(_cvw_floor_map[oi])
	return out


func _cvw_sel_tex(key: String, null_first: bool):
	var il = _cvw_lists.get(key)
	if il == null or il.get_selected_items().empty():
		return null
	var idx = _cvw_sel_orig(il)
	if idx < 0:
		return null
	if null_first and idx == 0:
		# First portal entry is the texture-less X portal.
		return null
	return _cvw_item_tex(key, il, idx)


func _cvw_capture() -> void:
	var wall_il = _cvw_lists["wall"]
	var widx = int(max(0, _cvw_sel_orig(wall_il)))
	_cvw = {
		"wall_tex": _cvw_item_tex("wall", wall_il, widx),
		"wall_col": _cvw_snaps["wall"][widx]["mod"] if _cvw_snaps.has("wall") and widx < _cvw_snaps["wall"].size() else Color(1, 1, 1),
		"shadow": bool(_cvw_checks["shadow"].pressed),
		"bevel": bool(_cvw_checks["bevel"].pressed),
		"pillars": bool(_cvw_checks["pillars"].pressed),
		"pillar_tex": _cvw_sel_tex("pillar", false),
		"pillar_texs": _cvw_pillar_multi(),
		"pillar_rand": bool(_cvw_checks["pillar_rand"].pressed) if _cvw_checks.has("pillar_rand") else false,
		"pillar_scale": _cvw_pillar_scale,
		"use_floor": bool(_cvw_checks["use_floor"].pressed) if _cvw_checks.has("use_floor") else false,
		"floor_picks": _cvw_floor_picks(),
		"soft_walls": bool(_cvw_checks["soft_walls"].pressed) if _cvw_checks.has("soft_walls") else false,
		"soft_building": bool(_cvw_checks["soft_building"].pressed) if _cvw_checks.has("soft_building") else false,
		"soft_pillars": bool(_cvw_checks["soft_pillars"].pressed) if _cvw_checks.has("soft_pillars") else false,
		"win_tex": _cvw_sel_tex("win", true),
		"door_tex": _cvw_sel_tex("door", true),
		"win_texs": _cvw_portal_multi("win"),
		"door_texs": _cvw_portal_multi("door"),
		"use_doors": _cvw_checks["use_doors"].pressed if _cvw_checks.has("use_doors") else true,
		"use_wins": _cvw_checks["use_wins"].pressed if _cvw_checks.has("use_wins") else true
	}
	_cvw_save_last()


func _cvw_confirm() -> void:
	_cvw_capture()
	_cvw_dlg.hide()
	_cv_start_vectorize()


func _on_cvw_go() -> void:
	if _cvw_area_toggle != null and is_instance_valid(_cvw_area_toggle) \
			and _cvw_area_toggle.pressed:
		_on_cvw_area()
	else:
		_cvw_confirm()


func _on_cvw_area() -> void:
	# Same settings capture, but the conversion waits for the rectangle:
	# the next plan-mode drag delimits it, crosshair cursor meanwhile.
	# The drag only exists inside the sketch tool in Plan mode: force
	# both, whatever tool or mode the wizard was opened from.
	_cvw_capture()
	_cvw_dlg.hide()
	if not _tool_active:
		Global.Editor.Toolset.Quickswitch(TOOL_ID)
	if _mode != MODE_PLAN:
		_change_mode(MODE_PLAN)
	_cv_area_pick = true
	Input.set_default_cursor_shape(Input.CURSOR_CROSS)


func _cv_wait_show() -> void:
	if _cv_wait_dlg == null or not is_instance_valid(_cv_wait_dlg):
		var pp = PopupPanel.new()
		var mc = MarginContainer.new()
		mc.set("custom_constants/margin_left", 24)
		mc.set("custom_constants/margin_right", 24)
		mc.set("custom_constants/margin_top", 16)
		mc.set("custom_constants/margin_bottom", 16)
		var wl = Label.new()
		wl.text = "Converting sketch, please wait..."
		mc.add_child(wl)
		pp.add_child(mc)
		Global.Editor.add_child(pp)
		_owned.append(pp)
		_cv_wait_dlg = pp
	_cv_wait_countdown = -1
	_cv_wait_dlg.popup_centered()


func _cv_start_vectorize() -> void:
	_cv_wait_show()
	if _cv_thread != null:
		return
	var full = _readback_a()
	if full == null:
		return
	printerr("[SketchConv] vectorizing sketch raster...")
	var clip = null
	if _cv_area != null:
		clip = Rect2(_cv_area.position * _tex_scale, _cv_area.size * _tex_scale)
		_cv_area = null
	_cv_thread = Thread.new()
	_cv_thread.start(self, "_cv_worker", {
		"data": full.get_data(), "w": full.get_width(), "h": full.get_height(),
		"ts": _tex_scale, "clip": clip})


func _cv_poll() -> void:
	if _cv_thread == null or _cv_thread.is_alive():
		return
	var res = _cv_thread.wait_to_finish()
	_cv_thread = null
	if res == null:
		printerr("[SketchConv] vectorization returned nothing")
		_cv_wait_countdown = 1
		return
	printerr("[SketchConv] vectorized: ", res["pool"].size(), " segments, ",
		res["holes"].size(), " holes")
	_cv_apply(res["pool"], res["holes"])
	# Keep the wait popup up a moment longer: the Soft Shadows feeding
	# settles over the next frames.
	_cv_wait_countdown = 45


# Thread worker. Classes: 0 empty, 1 wall, 2 window, 3 door.
func _cv_worker(args: Dictionary):
	var data: PoolByteArray = args["data"]
	var w = int(args["w"])
	var h = int(args["h"])
	var ts = float(args["ts"])
	var grid = PoolByteArray()
	grid.resize(w * h)
	var win8 = [int(WINDOW_COLOR.r * 255.0), int(WINDOW_COLOR.g * 255.0), int(WINDOW_COLOR.b * 255.0)]
	var door8 = [int(DOOR_COLOR.r * 255.0), int(DOOR_COLOR.g * 255.0), int(DOOR_COLOR.b * 255.0)]
	var clip = args.get("clip", null)
	var cx0 = 0
	var cy0 = 0
	var cx1 = w
	var cy1 = h
	if clip != null:
		cx0 = int(max(0, floor(clip.position.x)))
		cy0 = int(max(0, floor(clip.position.y)))
		cx1 = int(min(w, ceil(clip.position.x + clip.size.x)))
		cy1 = int(min(h, ceil(clip.position.y + clip.size.y)))
	var n_solid = 0
	var px = 0
	var py = 0
	var bx0 = w
	var by0 = h
	var bx1 = -1
	var by1 = -1
	for i in range(w * h):
		var o = i * 4
		var outside = clip != null and (px < cx0 or px >= cx1 or py < cy0 or py >= cy1)
		px += 1
		if px == w:
			px = 0
			py += 1
		if outside or data[o + 3] < 128:
			grid[i] = 0
			continue
		var dw = abs(data[o] - win8[0]) + abs(data[o + 1] - win8[1]) + abs(data[o + 2] - win8[2])
		var dd = abs(data[o] - door8[0]) + abs(data[o + 1] - door8[1]) + abs(data[o + 2] - door8[2])
		if dw < 15:
			grid[i] = 2
		elif dd < 15:
			grid[i] = 3
		elif data[o] + data[o + 1] + data[o + 2] < 15:
			# EXACT kind colors only (a hair of tolerance for
			# antialiased cores): pure black converts to walls, the
			# window / door swatch colors to portals, any OTHER blue,
			# brown or dark shade is annotation and stays out.
			grid[i] = 1
		else:
			grid[i] = 0
			continue
		n_solid += 1
		var sy = i / w
		var sx = i - sy * w
		if sx < bx0:
			bx0 = sx
		if sx > bx1:
			bx1 = sx
		if sy < by0:
			by0 = sy
		if sy > by1:
			by1 = sy
	if n_solid == 0:
		printerr("[SketchConv] no solid pixels found (format issue?)")
		return {"pool": [], "holes": []}
	printerr("[SketchConv] solid pixels: ", n_solid)
	# Every pass below (BFS, flood, Zhang-Suen thinning, deblock,
	# prune, trace) is O(grid) and some are ITERATIVE: on a large map
	# with a small sketch they burned the whole canvas. The grid and
	# its color data are cropped to the solid bounding box (a margin
	# keeps the depth-limited BFS semantics: outside the box is
	# genuinely empty, exactly like the real canvas edges). The trace
	# output is translated back at the end.
	var ox = 0
	var oy = 0
	var marg = int(max(6.0, ceil(70.0 * ts))) + 4
	bx0 = int(max(0, bx0 - marg))
	by0 = int(max(0, by0 - marg))
	bx1 = int(min(w - 1, bx1 + marg))
	by1 = int(min(h - 1, by1 + marg))
	var bw = bx1 - bx0 + 1
	var bh = by1 - by0 + 1
	if bw > 0 and bh > 0 and (bw < w or bh < h):
		var g2 = PoolByteArray()
		var d2 = PoolByteArray()
		for yy in range(bh):
			var sidx = (yy + by0) * w + bx0
			g2.append_array(grid.subarray(sidx, sidx + bw - 1))
			d2.append_array(data.subarray(sidx * 4, (sidx + bw) * 4 - 1))
		grid = g2
		data = d2
		ox = bx0
		oy = by0
		w = bw
		h = bh
		printerr("[SketchConv] cropped to content: ", bw, "x", bh)
	# FILLED SHAPES are not walls: a solid blob's Zhang-Suen skeleton is
	# its medial axis, which converted into star-shaped junk walls.
	# Depth-limited BFS from the empty pixels finds solid cells deeper
	# than any stroke half-width; a color flood from those seeds then
	# eats the whole same-colored fill (a Both shape's outline survives:
	# different color, and pure strokes are never deep enough to seed).
	var fill_thr = int(max(6.0, ceil(70.0 * ts)))
	var dist = PoolIntArray()
	dist.resize(w * h)
	for i in range(w * h):
		dist[i] = -1
	var q = PoolIntArray()
	var qn = 0
	for i in range(w * h):
		if grid[i] == 0:
			dist[i] = 0
	q.resize(w * h)
	for i in range(w * h):
		if dist[i] == 0:
			q[qn] = i
			qn += 1
	var qh = 0
	while qh < qn:
		var cur = q[qh]
		qh += 1
		var dcur = dist[cur]
		if dcur > fill_thr:
			continue
		var cyq = cur / w
		var cxq = cur - cyq * w
		for dq in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
			var nxq = cxq + dq[0]
			var nyq = cyq + dq[1]
			if nxq < 0 or nxq >= w or nyq < 0 or nyq >= h:
				continue
			var oi = nyq * w + nxq
			if dist[oi] >= 0:
				continue
			dist[oi] = dcur + 1
			if qn < w * h:
				q[qn] = oi
				qn += 1
	var removed_fill = 0
	var fq = PoolIntArray()
	fq.resize(w * h)
	var fqn = 0
	for i in range(w * h):
		if grid[i] != 0 and (dist[i] < 0 or dist[i] > fill_thr):
			fq[fqn] = i
			fqn += 1
	if fqn > 0:
		var kill = PoolByteArray()
		kill.resize(w * h)
		for i in range(w * h):
			kill[i] = 0
		for k in range(fqn):
			kill[fq[k]] = 1
		var fh2 = 0
		while fh2 < fqn:
			var cur2 = fq[fh2]
			fh2 += 1
			var o2 = cur2 * 4
			var cy2 = cur2 / w
			var cx2 = cur2 - cy2 * w
			for dq2 in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx2 = cx2 + dq2[0]
				var ny2 = cy2 + dq2[1]
				if nx2 < 0 or nx2 >= w or ny2 < 0 or ny2 >= h:
					continue
				var oi2 = ny2 * w + nx2
				if kill[oi2] != 0 or grid[oi2] == 0:
					continue
				var oo = oi2 * 4
				var dc = abs(data[o2] - data[oo]) + abs(data[o2 + 1] - data[oo + 1]) \
						+ abs(data[o2 + 2] - data[oo + 2])
				if dc > 120:
					continue
				kill[oi2] = 1
				if fqn < w * h:
					fq[fqn] = oi2
					fqn += 1
		for i in range(w * h):
			if kill[i] != 0 and grid[i] != 0:
				grid[i] = 0
				removed_fill += 1
		printerr("[SketchConv] filled shapes ignored: ", removed_fill, " px")
	# PoolByteArray is copy-on-write across calls: the thinned grid must
	# be RETURNED, an in-place mutation only edits the callee's copy.
	grid = _cv_thin(grid, w, h)
	grid = _cv_deblock(grid, w, h)
	grid = _cv_prune(grid, w, h)
	_cv_debug_dump_grid(grid, w, h)
	var res = _cv_trace(grid, w, h, ts)
	if ox != 0 or oy != 0:
		var offw = Vector2(ox, oy) / ts
		for sg in res["pool"]:
			sg[0] += offw
			sg[1] += offw
		for hh in res["holes"]:
			hh[0] += offw
			hh[1] += offw
	return res


# Zhang-Suen thinning; classes survive on the skeleton pixels.
func _cv_thin(grid: PoolByteArray, w: int, h: int) -> PoolByteArray:
	var offs = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
	for _pass in range(64):
		var removed = 0
		for sub in range(2):
			var kill = []
			for y in range(1, h - 1):
				var row = y * w
				for x in range(1, w - 1):
					var i = row + x
					if grid[i] == 0:
						continue
					var nb = []
					for k in range(8):
						nb.append(1 if grid[i + offs[k]] != 0 else 0)
					var bsum = 0
					for k in range(8):
						bsum += nb[k]
					if bsum < 2 or bsum > 6:
						continue
					var trans = 0
					for k in range(8):
						if nb[k] == 0 and nb[(k + 1) % 8] == 1:
							trans += 1
					if trans != 1:
						continue
					if sub == 0:
						if nb[0] * nb[2] * nb[4] != 0 or nb[2] * nb[4] * nb[6] != 0:
							continue
					else:
						if nb[0] * nb[2] * nb[6] != 0 or nb[0] * nb[4] * nb[6] != 0:
							continue
					kill.append(i)
			for i in kill:
				grid[i] = 0
			removed += kill.size()
		if removed == 0:
			break
	return grid


# Effective degree of a skeleton pixel = number of CONTIGUOUS clusters
# among its 8 neighbours (circular order). Staircase corners on curves
# have 3 raw neighbours but 2 clusters: line points, not junctions.
func _cv_deg(grid: PoolByteArray, i: int, offs_c: Array) -> int:
	var prev_on = grid[i + offs_c[7]] != 0
	var clusters = 0
	for k in range(8):
		var on = grid[i + offs_c[k]] != 0
		if on and not prev_on:
			clusters += 1
		prev_on = on
	return clusters


# Removes ONE redundant pixel from every full 2x2 block left by
# Zhang-Suen on diagonal staircases (their corner fragments the tracer
# with micro-cycles). The removable pixel is one with NO neighbour
# outside the block: deleting it cannot cut the line. Removing a fixed
# corner instead broke every NW-SE diagonal.
func _cv_deblock(grid: PoolByteArray, w: int, h: int) -> PoolByteArray:
	var offs = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
	for y in range(1, h - 2):
		var row = y * w
		for x in range(1, w - 2):
			var i = row + x
			if grid[i] == 0 or grid[i + 1] == 0 or grid[i + w] == 0 or grid[i + w + 1] == 0:
				continue
			var block = [i, i + 1, i + w, i + w + 1]
			var removed = false
			for b in block:
				var outside = false
				for k in range(8):
					var nb = b + offs[k]
					if grid[nb] != 0 and not (nb in block):
						outside = true
						break
				if not outside:
					grid[b] = 0
					removed = true
					break
			if removed:
				continue
			# 2x2 blocks whose four pixels all have outside neighbours
			# survived here and their pixels traced as junctions - the
			# staircase double-steps that shredded every drawn ellipse
			# into hundreds of fragments. One pixel can still go when its
			# remaining neighbours stay one 8-connected group without it.
			for b2 in block:
				var sav = grid[b2]
				grid[b2] = 0
				if _cv_removal_safe(grid, w, b2, offs):
					break
				grid[b2] = sav
	return grid


# True when the ON neighbours of the (already cleared) pixel b form a
# single 8-connected component among themselves: clearing b then cannot
# break the line locally.
func _cv_removal_safe(grid: PoolByteArray, w: int, b: int, offs: Array) -> bool:
	var nbs = []
	for k in range(8):
		if grid[b + offs[k]] != 0:
			nbs.append(b + offs[k])
	if nbs.size() < 2:
		return true
	var comp = [nbs[0]]
	var grew = true
	while grew:
		grew = false
		for p in nbs:
			if p in comp:
				continue
			var px = p % w
			var py = p / w
			for q in comp:
				if abs(px - (q % w)) <= 1 and abs(py - (q / w)) <= 1:
					comp.append(p)
					grew = true
					break
	return comp.size() == nbs.size()


# Deletes short spur branches (endpoint chains ending at a junction):
# thinning artifacts that fragment smooth curves into stubs.
func _cv_prune(grid: PoolByteArray, w: int, h: int) -> PoolByteArray:
	var offs = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
	for _round in range(3):
		var kill = []
		for y in range(1, h - 1):
			var row = y * w
			for x in range(1, w - 1):
				var i = row + x
				if grid[i] == 0:
					continue
				if _cv_deg(grid, i, offs) != 1:
					continue
				# Walk the chain from this endpoint.
				var chain = [i]
				var prev = i
				var cur = -1
				for k in range(8):
					if grid[i + offs[k]] != 0:
						cur = i + offs[k]
						break
				var hit_junction = false
				while cur >= 0 and chain.size() <= 14:
					var dg2 = _cv_deg(grid, cur, offs)
					if dg2 >= 3:
						hit_junction = true
						break
					var nxt = -1
					for k in [0, 2, 4, 6, 1, 3, 5, 7]:
						var cnd = cur + offs[k]
						if grid[cnd] != 0 and cnd != prev and not chain.has(cnd):
							nxt = cnd
							break
					chain.append(cur)
					if dg2 <= 1 or nxt < 0:
						break
					prev = cur
					cur = nxt
				if hit_junction and chain.size() <= 14:
					for c in chain:
						kill.append(c)
		if kill.empty():
			break
		for i in kill:
			grid[i] = 0
	return grid


# A diagonal edge is redundant when either shared orthogonal pixel is
# on (the L path exists): on staircase corners both the two orthogonal
# steps AND the diagonal shortcut connect the same pixels, and the
# leftover shortcut edges spawned hundreds of 3-pixel parasite paths
# plus end-of-path backtrack hooks. k indexes offs (odd = diagonal).
func _cv_diag_redundant(grid: PoolByteArray, w: int, p: int, k: int) -> bool:
	if k % 2 == 0:
		return false
	var dx = 1 if (k == 1 or k == 3) else -1
	var dy = -1 if (k == 1 or k == 7) else 1
	return grid[p + dx] != 0 or grid[p + dy * w] != 0


# Skeleton -> polylines split by class runs -> RDP -> lattice snap.
func _cv_trace(grid: PoolByteArray, w: int, h: int, ts: float) -> Dictionary:
	var offs = [-w, -w + 1, 1, w + 1, w, w - 1, -1, -w - 1]
	var deg = {}
	for y in range(1, h - 1):
		var row = y * w
		for x in range(1, w - 1):
			var i = row + x
			if grid[i] == 0:
				continue
			deg[i] = _cv_deg(grid, i, offs)
	var visited = {}
	var paths = []
	# Walks start at endpoints and junctions, then leftover loops.
	var starts = []
	for i in deg:
		if deg[i] != 2:
			starts.append(i)
	for phase in range(2):
		var src = starts
		if phase == 1:
			src = deg.keys()
		for st in src:
			if grid[st] == 0:
				continue
			for k0 in range(8):
				var n0 = st + offs[k0]
				if grid[n0] == 0 or visited.has(str(st) + "_" + str(n0)):
					continue
				if _cv_diag_redundant(grid, w, st, k0):
					continue
				var path = [st]
				var cur = n0
				var prev = st
				visited[str(st) + "_" + str(n0)] = true
				visited[str(n0) + "_" + str(st)] = true
				while true:
					path.append(cur)
					if deg.get(cur, 0) != 2:
						break
					# Orthogonal continuation first: skips the redundant
					# diagonal shortcut at staircase corners.
					var nxt = -1
					for k in [0, 2, 4, 6, 1, 3, 5, 7]:
						var cnd = cur + offs[k]
						if cnd != prev and grid[cnd] != 0 \
								and not visited.has(str(cur) + "_" + str(cnd)) \
								and not _cv_diag_redundant(grid, w, cur, k):
							nxt = cnd
							break
					if nxt < 0:
						break
					visited[str(cur) + "_" + str(nxt)] = true
					visited[str(nxt) + "_" + str(cur)] = true
					prev = cur
					cur = nxt
				if path.size() >= 3:
					paths.append(path)
	# Split paths into class runs, then simplify each run.
	var pool = []
	var holes = []
	for path in paths:
		var runs = []
		var run = [path[0]]
		var rc = int(grid[path[0]])
		for pi in range(1, path.size()):
			var c = int(grid[path[pi]])
			if c == rc:
				run.append(path[pi])
			else:
				runs.append([rc, run])
				rc = c
				run = [path[pi - 1], path[pi]]
		runs.append([rc, run])
		for r in runs:
			if r[1].size() < 3 and int(r[0]) == 1:
				continue
			var pts = []
			for i in r[1]:
				pts.append(Vector2((i % w) + 0.5, int(i / w) + 0.5) / ts)
			# Epsilon rides the PIXEL SIZE: 1.2 texture px in world
			# units (2.2 world floor). Below the quantization noise
			# (the earlier 3-world cap), circles kept ~35 px jittery
			# chords whose +-0.3 rad angular noise shredded the
			# smooth-turn runs into 300 px crumbs; above it (the
			# original 2.2/ts), they decimated into coarse polygons.
			var simp = _cv_rdp(pts, max(2.2, 1.2 / ts))
			for si in range(simp.size() - 1):
				if simp[si].distance_to(simp[si + 1]) < 2.0:
					continue
				pool.append([simp[si], simp[si + 1]])
				if int(r[0]) == 2 or int(r[0]) == 3:
					holes.append([simp[si], simp[si + 1], int(r[0])])
	printerr("[SketchConv] trace: ", paths.size(), " paths -> ",
		pool.size(), " segments, ", holes.size(), " holes")
	return {"pool": pool, "holes": holes}


# Debug: skeleton as a PNG (white=wall, blue=window, brown=door).
func _cv_debug_dump_grid(grid: PoolByteArray, w: int, h: int) -> void:
	var img = Image.new()
	img.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 1))
	img.lock()
	for y in range(h):
		for x in range(w):
			var c = grid[y * w + x]
			if c == 1:
				img.set_pixel(x, y, Color(0.1, 0.1, 0.1, 1))
			elif c == 2:
				img.set_pixel(x, y, Color(0.1, 0.3, 0.9, 1))
			elif c == 3:
				img.set_pixel(x, y, DOOR_COLOR)
	img.unlock()
	var d = Directory.new()
	d.make_dir_recursive("user://Sketch_Tool")
	img.save_png("user://Sketch_Tool/debug_skeleton.png")


# Debug: final chains, one color per chain, drawn at texture scale.
func _cv_debug_dump_chains(chains: Array) -> void:
	var mx = Vector2(64, 64)
	for ch in chains:
		for pt in ch["pts"]:
			mx.x = max(mx.x, pt.x * _tex_scale + 4.0)
			mx.y = max(mx.y, pt.y * _tex_scale + 4.0)
	var img = Image.new()
	img.create(int(mx.x), int(mx.y), false, Image.FORMAT_RGBA8)
	img.lock()
	for ci in range(chains.size()):
		var col = Color.from_hsv(fmod(ci * 0.37, 1.0), 0.9, 1.0)
		var pts = chains[ci]["pts"]
		var nseg = pts.size() - 1
		if bool(chains[ci]["loop"]):
			nseg = pts.size()
		for k in range(nseg):
			var a = pts[k] * _tex_scale
			var b = pts[(k + 1) % pts.size()] * _tex_scale
			var n = int(max(2, a.distance_to(b)))
			for m in range(n + 1):
				var q = a.linear_interpolate(b, float(m) / float(n))
				if q.x >= 0 and q.y >= 0 and q.x < img.get_width() and q.y < img.get_height():
					img.set_pixel(int(q.x), int(q.y), col)
	img.unlock()
	var d = Directory.new()
	d.make_dir_recursive("user://Sketch_Tool")
	img.save_png("user://Sketch_Tool/debug_chains.png")


func _cv_rdp(pts: Array, eps: float) -> Array:
	if pts.size() <= 2:
		return pts
	var dmax = 0.0
	var idx = 0
	var a = pts[0]
	var b = pts[pts.size() - 1]
	for i in range(1, pts.size() - 1):
		var d = 0.0
		if a.distance_to(b) < 0.5:
			d = pts[i].distance_to(a)
		else:
			d = abs((b - a).normalized().cross(pts[i] - a))
		if d > dmax:
			dmax = d
			idx = i
	if dmax <= eps:
		return [a, b]
	var left = _cv_rdp(pts.slice(0, idx), eps)
	var right = _cv_rdp(pts.slice(idx, pts.size() - 1), eps)
	left.pop_back()
	return left + right


# True when v is within ~9 degrees of an axis or diagonal direction.
func _cv_axisish(v: Vector2) -> bool:
	if v.length() < 0.5:
		return true
	var a = fmod(abs(v.angle()), PI * 0.25)
	return a < 0.16 or a > PI * 0.25 - 0.16


func _cv_lattice_snap(p: Vector2) -> Vector2:
	var half = CELL * 0.5
	var sn = Vector2(round(p.x / half) * half, round(p.y / half) * half)
	if sn.distance_to(p) <= CELL * 0.18:
		return sn
	return p


class PlanConvertRecord:
	extends Reference

	var level_id = -1
	var walls_data = []
	var wall_ids = []
	var wall_refs = []
	var walls_node_ref = null
	var props_data = []
	var prop_refs = []
	var objects_node_ref = null
	var fs_portals = []            # [texture, position, radius, rotation]
	var fs_refs = []
	var level_node_ref = null

	func _impl_show_sketch(v: bool) -> void:
		if Engine.has_meta("SketchTool_active_impl"):
			var im = Engine.get_meta("SketchTool_active_impl")
			if im != null and is_instance_valid(im) and im.has_method("set_sketch_shown"):
				im.set_sketch_shown(v)

	# Class-local copy of the freestanding fishing (the record must not
	# depend on a live impl): a Node2D with WallID == -1 on the spot.
	func _impl_fish_freestanding(lvl, pos: Vector2):
		var stack = [lvl]
		var depth = {lvl.get_instance_id(): 0}
		var best = null
		while stack.size() > 0:
			var n = stack.pop_back()
			var d = int(depth.get(n.get_instance_id(), 0))
			for ch in n.get_children():
				if d < 2:
					depth[ch.get_instance_id()] = d + 1
					stack.append(ch)
				var wid = ch.get("WallID")
				if wid == null or int(wid) != -1:
					continue
				if ch.get("Radius") == null or not ch is Node2D:
					continue
				if ch.global_position.distance_to(pos) <= 8.0:
					best = ch
		return best

	func undo():
		_impl_show_sketch(true)
		for fr in fs_refs:
			if fr != null:
				var fn = fr.get_ref()
				if fn != null and is_instance_valid(fn) and not fn.is_queued_for_deletion():
					fn.queue_free()
		for pr in prop_refs:
			if pr != null:
				var pn = pr.get_ref()
				if pn != null and is_instance_valid(pn) and not pn.is_queued_for_deletion():
					pn.queue_free()
		for i in range(wall_refs.size()):
			var done = false
			if wall_refs[i] != null:
				var n = wall_refs[i].get_ref()
				if n != null and is_instance_valid(n) and not n.is_queued_for_deletion():
					# queue_free is the clean primary: Wall._ExitTree does
					# the whole registry cleanup itself (portals included).
					n.queue_free()
					done = true
			if not done and i < wall_ids.size():
				if not Global.World.DeleteNodeByID(int(wall_ids[i])):
					printerr("[SketchConv] undo: wall unreachable: ", wall_ids[i])

	func redo():
		_impl_show_sketch(false)
		# The Walls node comes from a weakref captured at conversion time:
		# Global.* lookups inside this Reference proved crash-prone, the
		# weakref discipline is the one thing that has always worked.
		var wnode = null
		if walls_node_ref != null:
			wnode = walls_node_ref.get_ref()
		if wnode == null or not is_instance_valid(wnode):
			printerr("[SketchConv] redo: walls node gone, aborting")
			return
		prop_refs = []
		if objects_node_ref != null:
			var onode = objects_node_ref.get_ref()
			if onode != null and is_instance_valid(onode):
				for pd in props_data:
					onode.LoadObject(pd)
					var pkids = onode.get_children()
					if pkids.size() > 0:
						prop_refs.append(weakref(pkids[pkids.size() - 1]))
					else:
						prop_refs.append(null)
		fs_refs = []
		if level_node_ref != null:
			var lnode = level_node_ref.get_ref()
			if lnode != null and is_instance_valid(lnode):
				for fp in fs_portals:
					lnode.call("CreateFreestandingPortal", fp[0], fp[1], false, fp[2], fp[3])
					var fnode = _impl_fish_freestanding(lnode, fp[1])
					if fnode != null:
						if not fnode.has_meta("node_id"):
							Global.World.AssignNodeID(fnode)
						fnode.z_index = FS_ABOVE_WALLS_Z
						fnode.raise()
						fs_refs.append(weakref(fnode))
		wall_refs = []
		for d in walls_data:
			var prev_last = null
			var kids0 = wnode.get_children()
			if kids0.size() > 0:
				prev_last = kids0[kids0.size() - 1]
			wnode.LoadWall(d)
			var kids = wnode.get_children()
			var neww = null
			if kids.size() > 0 and kids[kids.size() - 1] != prev_last:
				neww = kids[kids.size() - 1]
			if neww != null:
				wall_refs.append(weakref(neww))
			else:
				printerr("[SketchConv] redo: wall did not load (duplicate id?)")
				wall_refs.append(null)


# Converts everything drawn on the sketch (any subtool) into native DD
# walls and portals: the raster is vectorized on a background thread,
# door/window colored strokes become portal holes, every other opaque
# color is a wall. Walls run THROUGH the openings, portals sit on top.
func _plan_convert_to_dd() -> void:
	if _canvas_empty():
		_float_toast("Canvas is empty, conversion aborted.")
		return
	if _stroke != null or _plan_pending != null or _plan_render != null:
		return
	_cvw_open()


func _cv_apply(pool: Array, holes: Array) -> void:
	if pool.empty():
		printerr("[SketchConv] nothing to convert")
		# The canvas held content but none of it was wall-black (or a
		# recognized window/door color): tell the user why nothing came
		# out instead of failing silently.
		_float_toast("No wall-colored (black) strokes found, nothing to convert.")
		return
	# 1b. Perimeter first: each connected component's outer boundary
	# becomes ONE closed wall (walk of the outer face), so the whole
	# building outline is a single loop instead of a patchwork of
	# fragments - fewer junctions, and every interior wall naturally
	# layers UNDER it through the stem/bar constraints.
	var perim = _cv_extract_perimeters(pool)
	var pre_loops = perim["loops"]
	pool = perim["rest"]
	printerr("[SketchConv] perimeters: ", pre_loops.size(), " loop(s), ",
		pool.size(), " interior segments left")
	# 2. Chain segments into polylines: at junctions the most collinear
	# continuation wins, branches become their own chains.
	var by_pt = {}
	for i in range(pool.size()):
		for e in range(2):
			var k = _cv_key(pool[i][e])
			if not by_pt.has(k):
				by_pt[k] = []
			by_pt[k].append(i)
	var used = {}
	var chains = []
	for i in range(pool.size()):
		if used.has(i):
			continue
		used[i] = true
		var pts = [pool[i][0], pool[i][1]]
		var loop = false
		for e in range(2):
			while true:
				var tail = pts[pts.size() - 1]
				var dirn = (tail - pts[pts.size() - 2]).normalized()
				var cands = by_pt.get(_cv_key(tail), [])
				var best = -1
				var best_dot = -2.0
				for j in cands:
					if used.has(j):
						continue
					var oth = pool[j][1]
					if _cv_key(pool[j][1]) == _cv_key(tail):
						oth = pool[j][0]
					var d2 = (oth - tail).normalized().dot(dirn)
					if d2 > best_dot:
						best_dot = d2
						best = j
				if best < 0:
					break
				# True-T rule: at a junction (3+ incident segments) a
				# chain only continues nearly straight. A branch stops
				# here and becomes its own chain, so the bar of a T stays
				# one continuous wall instead of an L stealing one arm
				# (the leftover arm then started offset: fake Ts).
				if cands.size() >= 3 and best_dot < 0.5:
					break
				used[best] = true
				var nxt = pool[best][1]
				if _cv_key(pool[best][1]) == _cv_key(tail):
					nxt = pool[best][0]
				pts.append(nxt)
				if _cv_key(nxt) == _cv_key(pts[0]):
					loop = true
					pts.remove(pts.size() - 1)
					break
			if loop:
				break
			pts.invert()
		# Direction-aware lattice snap on the CHAINED polyline: snapping
		# per traced path desynced shared junction endpoints and broke
		# chains into fragments. Curve points (non lattice-aligned
		# neighbours) stay untouched.
		for si2 in range(pts.size()):
			var d_in = null
			var d_out = null
			if si2 > 0 or loop:
				d_in = pts[si2] - pts[(si2 - 1 + pts.size()) % pts.size()]
			if si2 < pts.size() - 1 or loop:
				d_out = pts[(si2 + 1) % pts.size()] - pts[si2]
			var ok_in = d_in == null or _cv_axisish(d_in)
			var ok_out = d_out == null or _cv_axisish(d_out)
			# Curve vertices near the extremes of an ellipse have BOTH
			# neighbours axis-ish: snapping them planted spikes and dents
			# on every drawn oval. Snap only straight-run points and real
			# corners, and cap the corner displacement by the local chord.
			var turn_s = 0.0
			if d_in != null and d_out != null:
				turn_s = abs(d_in.normalized().angle_to(d_out.normalized()))
			if ok_in and ok_out and (turn_s < 0.05 or turn_s > 0.6):
				var sn_s = _cv_lattice_snap(pts[si2])
				var lim_s = 1e9
				if d_in != null:
					lim_s = min(lim_s, d_in.length() * 0.25)
				if d_out != null:
					lim_s = min(lim_s, d_out.length() * 0.25)
				if turn_s < 0.05 or sn_s.distance_to(pts[si2]) <= lim_s:
					pts[si2] = sn_s
		# Collinear middle points collapse (arc chords survive: angled).
		var simp = [pts[0]]
		for k2 in range(1, pts.size() - 1):
			var v1 = (pts[k2] - simp[simp.size() - 1]).normalized()
			var v2 = (pts[k2 + 1] - pts[k2]).normalized()
			if abs(v1.cross(v2)) > 0.02 or v1.dot(v2) < 0.9:
				simp.append(pts[k2])
		simp.append(pts[pts.size() - 1])
		chains.append({"pts": simp, "loop": loop})
	# The perimeter loops join the pack here, snapped and simplified the
	# same way as the open chains (modulo the loop): every later pass
	# treats them like any other closed chain.
	for pl2 in pre_loops:
		var lp = pl2["pts"]
		var nlp = lp.size()
		for si3 in range(nlp):
			var di3 = lp[si3] - lp[(si3 - 1 + nlp) % nlp]
			var do3 = lp[(si3 + 1) % nlp] - lp[si3]
			var turn3 = abs(di3.normalized().angle_to(do3.normalized()))
			if _cv_axisish(di3) and _cv_axisish(do3) and (turn3 < 0.05 or turn3 > 0.6):
				var sn3 = _cv_lattice_snap(lp[si3])
				var lim3 = min(di3.length(), do3.length()) * 0.25
				if turn3 < 0.05 or sn3.distance_to(lp[si3]) <= lim3:
					lp[si3] = sn3
		var out3 = []
		for k3 in range(nlp):
			var v1b = (lp[k3] - lp[(k3 - 1 + nlp) % nlp]).normalized()
			var v2b = (lp[(k3 + 1) % nlp] - lp[k3]).normalized()
			if abs(v1b.cross(v2b)) > 0.02 or v1b.dot(v2b) < 0.9:
				out3.append(lp[k3])
		if out3.size() >= 3:
			chains.append({"pts": out3, "loop": true})
	# Overlap-drop FIRST: parasites hugging the main wall squat the
	# junctions and hijack the fusion (a half circle fuses with the
	# parasite instead of the other half). Then fuse, then sweep again.
	# All tolerances live in TEXTURE pixels (artifacts scale with 1/ts).
	var tol = 1.0 / _tex_scale
	chains = _cv_drop_overlaps(chains, 7.0 * tol)
	chains = _cv_fuse_chains(chains, 8.0 * tol)
	chains = _cv_drop_overlaps(chains, 7.0 * tol)
	# A chain whose endpoint lands on its own body closes a loop there:
	# split it into that loop plus the leftover open chain. A single
	# Wall cannot be layered against itself, split parts can, and the
	# T machinery below then treats them like any other junction.
	chains = _cv_split_self_touch(chains)
	# Weld open endpoints onto the chain they nearly touch: closes the
	# pixel gaps the vectorizer leaves at T junctions.
	_cv_weld_junctions(chains)
	# Kill duplicated consecutive points and degenerate loops BEFORE
	# AddWall: zero-length wall segments reached the native mesh build
	# and crashed it at random right after conversion.
	chains = _cv_clean_chains(chains)
	# Window/door holes punched on 45-degree corners leave short skeleton
	# stubs dangling at the junction: they trace as tiny hooked chains
	# (the colored ticks in debug_chains.png). Drop dwarf open chains
	# that hang onto another chain.
	# Chain joining BEFORE the spur prune: curve tracing splits the
	# bastions into short arc bits at pseudo-junctions, and pruning
	# first deleted them as dwarf spurs - leaving 100-225 px holes no
	# later pass could resurrect. Stitched to their neighbours first,
	# they are not spurs anymore.
	chains = _cv_join_chains(chains, 110.0)
	chains = _cv_prune_spurs(chains, 20.0 * tol)
	chains = _cv_circle_pass(chains)
	# Drawn ovals: closed all-convex loops with no sharp corner and no
	# long straight side are refit as exact ellipses (circles already
	# went to the circle pass). Rectilinear rooms never qualify: right
	# angles trip the sharp gate, chamfered and octagonal rooms trip
	# the straight-side chord cap or the radial rms cap.
	chains = _cv_ellipse_pass(chains)
	# Attached bastions: arc PORTIONS living inside mixed chains
	# (curves plus straight runs in one polyline) that the whole-chain
	# circle fit cannot see. Curvature segmentation, span-only rebuild.
	chains = _cv_smooth_chain_arcs(chains)
	# Generic curve smoothing: ellipses and other non-circular curves
	# escape the circle fits, and their long trace chords read as
	# faceted polygons. Chaikin subdivision on the runs of THREE OR
	# MORE consecutive moderately-turning vertices - right angles and
	# chamfers are ISOLATED turns between straights and never qualify.
	chains = _cv_smooth_curvy_runs(chains)
	# Axis straightening: the near-horizontal/vertical runs sit on
	# jittered trace points, and a few px of drift over a ten-cell
	# wall reads as a visible skew once textured. Flatten them onto
	# their median coordinate (lattice-snapped when close); diagonals
	# and arcs are left strictly alone.
	chains = _cv_axis_straighten(chains)
	# The straightener lattice-snaps near-axial runs and PEELS wall
	# endpoints off the arc ends they sat on (1.5-2.5 px, enough for
	# DD to render loose ends): re-weld them last.
	_cv_weld_arc_ends(chains)
	# Two DISTINCT walls meeting end-to-end render their butt caps as
	# a visible seam: chains sharing an endpoint merge into ONE wall
	# (tight tolerance: only genuinely welded joints qualify), and a
	# merged chain whose own ends meet closes into a loop - the arc
	# plus its room perimeter become one continuous ring wall.
	chains = _cv_join_chains(chains, 2.0)
	for chx in chains:
		if bool(chx["loop"]) or chx["pts"].size() < 4:
			continue
		var cpx = chx["pts"]
		if cpx[0].distance_to(cpx[cpx.size() - 1]) <= 2.0:
			cpx.remove(cpx.size() - 1)
			chx["pts"] = cpx
			chx["loop"] = true
	_cv_debug_dump_chains(chains)
	printerr("[SketchConv] chains: ", chains.size())
	# 3. Create the DD walls with the Wall tool's current asset.
	var wtex = null
	var wcol = Color(1, 1, 1)
	var wshadow = true
	var wjoint = 1
	if _cvw != null:
		wtex = _cvw.get("wall_tex")
		wcol = _cvw.get("wall_col", Color(1, 1, 1))
		wshadow = bool(_cvw.get("shadow", true))
		if not bool(_cvw.get("bevel", true)):
			wjoint = 0
	if wtex == null:
		var wtool = Global.Editor.Tools.get("WallTool")
		if wtool != null:
			wtex = wtool.Texture
			if wtex != null:
				wcol = wtool.Color
			else:
				var gm = _cvw_find_wall_list()
				if gm != null:
					wtex = gm.get_item_icon(0)
	if wcol.a < 0.05:
		wcol = Color(1, 1, 1)
	if wtex == null:
		# AddWall with a null texture dies inside DD's native wall
		# builder: abort cleanly instead.
		printerr("[SketchConv] no wall texture resolved; open the Wall tool once, pick a wall, and retry")
		return
	# Snap the holes first: the corner cuts below need their final
	# geometry before the walls exist.
	for hi0 in range(holes.size()):
		var hv0 = holes[hi0][1] - holes[hi0][0]
		if _cv_axisish(hv0):
			holes[hi0][0] = _cv_lattice_snap(holes[hi0][0])
			holes[hi0][1] = _cv_lattice_snap(holes[hi0][1])
	# Corner rule, at the CHAIN level: an opening touching a corner (or
	# an end) of its carrying chain REALLY CUTS the chain - the wall is
	# built already split, no invisible portal involved (stacked
	# invisible portals stole clicks and hover-highlighted). One
	# freestanding textured portal per such opening, queued for after
	# the wall build.
	var fs_queue = []
	var holes_cut = {}
	chains = _cv_cut_corner_openings(chains, holes, fs_queue, holes_cut)
	var made = []
	for ch2 in chains:
		var pv = PoolVector2Array(ch2["pts"])
		var wall = Global.World.Level.Walls.AddWall(pv, wtex, wcol, bool(ch2["loop"]), wshadow, 1, wjoint, true)
		if wall == null:
			printerr("[SketchConv] AddWall returned null!")
			continue
		made.append({"wall": wall, "pts": ch2["pts"], "loop": bool(ch2["loop"])})
	# 4. Portals on the holes. Multi-cell openings become that many
	# 1-cell portals side by side; corner openings were consumed by the
	# chain cuts above.
	var chunks = []
	var n_portals = 0
	var made_fs = []
	for hi2 in range(holes.size()):
		var sg = holes[hi2]
		if holes_cut.has(hi2):
			continue
		var cls = 3
		if sg.size() > 2:
			cls = int(sg[2])
		# Doors/Windows toggled off in the wizard: skip those openings
		# entirely (the wall simply runs through).
		if _cvw != null:
			if cls == 2 and not bool(_cvw.get("use_wins", true)):
				continue
			if cls != 2 and not bool(_cvw.get("use_doors", true)):
				continue
		# Chunk width follows the chosen portal texture (X portal = 1 cell).
		var unit = CELL
		var ptex = _cvw_portal_tex(cls)
		if ptex != null:
			unit = max(32.0, float(ptex.get_width()))
		var hlen = sg[0].distance_to(sg[1])
		if hlen < unit * 0.45:
			# Class-bleed stub at a corner, not a real opening: skipping
			# it kills the rogue perpendicular portal.
			continue
		var n_ch = int(max(1, round(hlen / unit)))
		if ptex != null:
			# Textured portals: EXACT texture-width spacing, group
			# centered on the hole - side-by-side frames touch with no
			# pixel gap.
			var hdir = (sg[1] - sg[0]).normalized()
			var off0 = (hlen - float(n_ch) * unit) * 0.5
			for k3 in range(n_ch):
				var p0 = sg[0] + hdir * (off0 + unit * float(k3))
				chunks.append([p0, p0 + hdir * unit, cls])
		else:
			var hv = (sg[1] - sg[0]) / float(n_ch)
			for k3 in range(n_ch):
				chunks.append([sg[0] + hv * float(k3), sg[0] + hv * float(k3 + 1), cls])
	for sg in chunks:
		if true:
			var c = (sg[0] + sg[1]) * 0.5
			var cls2 = 3
			if sg.size() > 2:
				cls2 = int(sg[2])
			var ptex2 = _cvw_portal_tex(cls2)
			var rad = sg[0].distance_to(sg[1]) * 0.5
			if ptex2 != null:
				rad = float(ptex2.get_width()) * 0.5
			var placed = false
			# Best-ALIGNED carrying segment among the nearby ones:
			# first-hit could land on a chamfer or a perpendicular
			# chain at a junction and tilt the portal 45 degrees.
			var hdir2 = (sg[1] - sg[0]).normalized()
			var bestc = null
			var bestc_score = -1.0
			for mi5 in range(made.size()):
				var pts5 = made[mi5]["pts"]
				var n_seg5 = pts5.size() - 1
				if bool(made[mi5]["loop"]):
					n_seg5 = pts5.size()
				for si5 in range(n_seg5):
					var q5 = Geometry.get_closest_point_to_segment_2d(c, pts5[si5], pts5[(si5 + 1) % pts5.size()])
					var d5 = q5.distance_to(c)
					if d5 > 14.0:
						continue
					var al5 = abs((pts5[(si5 + 1) % pts5.size()] - pts5[si5]).normalized().dot(hdir2))
					var sc5 = al5 * 100.0 - d5
					if sc5 > bestc_score:
						bestc_score = sc5
						bestc = [mi5, si5, q5]
			if bestc != null:
				var m = made[bestc[0]]
				var pts2 = m["pts"]
				var si = bestc[1]
				var q = bestc[2]
				var pa = pts2[si]
				var pb = pts2[(si + 1) % pts2.size()]
				if true:
					if true:
						# The portal direction must follow the CARRYING
						# segment: chains can traverse the payload's hole
						# backwards (bidirectional build + invert), and a
						# reversed Begin/End makes RemakeLines cut nothing,
						# so the wall draws straight over the portal.
						var wdir = (pb - pa).normalized()
						# Clamp the center so the portal stays fully on the
						# segment: class bleed toward a corner apex shifted
						# holes and made portals overhang the wall end.
						var seg_len = pa.distance_to(pb)
						var raw_tc = (q - pa).dot(wdir)
						var tc = raw_tc
						if seg_len >= rad * 2.0:
							tc = clamp(tc, rad, seg_len - rad)
						else:
							tc = seg_len * 0.5
						var cc = pa + wdir * tc
						var portal = m["wall"].AddPortal(ptex2, false, cc, wdir, si, rad, false)
						if portal != null:
							# AddPortal never assigns the node id (the
							# prefab's own flow does it elsewhere): without
							# it, Portal.Save() inside Wall.Save() crashes.
							if not portal.has_meta("node_id"):
								Global.World.AssignNodeID(portal)
							n_portals += 1
						placed = true
			if not placed:
				# No carrying wall (awkward layouts): place the portal
				# FREESTANDING instead of dropping it. Nothing sits under
				# it, so the wall-under-portal concern does not apply.
				var lvl = Global.World.Level
				if lvl != null and ptex2 != null:
					var wdir3 = (sg[1] - sg[0]).normalized()
					lvl.call("CreateFreestandingPortal", ptex2, c, false, rad, wdir3.angle())
					var fsp = _cv_fish_freestanding(lvl, c)
					if fsp != null:
						if not fsp.has_meta("node_id"):
							Global.World.AssignNodeID(fsp)
						fsp.z_index = FS_ABOVE_WALLS_Z
						fsp.raise()
						made_fs.append([fsp, ptex2, c, rad, wdir3.angle()])
						n_portals += 1
					else:
						_dbg("convert: freestanding portal creation failed at " + str(c))
				else:
					_dbg("convert: no wall found for a portal at " + str(c))
	# The freestanding portals queued by the corner cuts.
	for fq in fs_queue:
		var ptexq = _cvw_portal_tex(int(fq[0]))
		var lvlq = Global.World.Level
		if ptexq == null or lvlq == null:
			continue
		var radq = float(ptexq.get_width()) * 0.5
		lvlq.call("CreateFreestandingPortal", ptexq, fq[1], false, radq, fq[2].angle())
		var fspq = _cv_fish_freestanding(lvlq, fq[1])
		if fspq != null:
			printerr("[SketchConv] corner portal -> freestanding at ", fq[1])
			if not fspq.has_meta("node_id"):
				Global.World.AssignNodeID(fspq)
			fspq.z_index = FS_ABOVE_WALLS_Z
			fspq.raise()
			made_fs.append([fspq, ptexq, fq[1], radq, fq[2].angle()])
			n_portals += 1
		else:
			printerr("[SketchConv] freestanding created but not found near ", fq[1])
	# 5. Junction analysis. Bar-above-stem ordering ALWAYS runs (it used
	# to hide inside the pillars toggle); pillar props only when asked.
	var made_props = []
	var pillars_on = _cvw != null and bool(_cvw.get("pillars", false)) \
			and (_cvw.get("pillar_tex") != null or _cvw.get("pillar_texs", []).size() > 0)
	var seen = {}
	var seen_pts = []
	var zcons = []
	# T junctions: endpoints of open chains meeting another chain. The BAR
	# of the T renders above the stem, but only genuine bars order
	# anything: a chain the stem hits mid-body, or - when several
	# endpoints meet on one spot (bar drawn in two strokes) - the pair of
	# arms running straight through the junction. Plain corners add NO
	# constraint: they used to add symmetric pairs (each end touching the
	# other's last segment), and those cycles kept the settle loop
	# churning move_childs until unrelated, perfectly satisfiable
	# stem/bar pairs came out in the wrong order.
	var zseen = {}
	for mi in range(made.size()):
		if bool(made[mi]["loop"]):
			continue
		var mpts = made[mi]["pts"]
		for ei in [0, mpts.size() - 1]:
			var ep = mpts[ei]
			# Direction leaving the junction into this chain.
			var d_self = Vector2()
			if mpts.size() >= 2:
				if ei == 0:
					d_self = (mpts[1] - mpts[0]).normalized()
				else:
					d_self = (mpts[mpts.size() - 2] - mpts[mpts.size() - 1]).normalized()
			var junction = false
			var body_bars = []
			var end_arms = []
			for mj in range(made.size()):
				if mj == mi:
					continue
				var jp = made[mj]["pts"]
				var jloop = bool(made[mj]["loop"])
				var nsg = jp.size() - 1
				if jloop:
					nsg = jp.size()
				var hit = false
				var hit_q = Vector2()
				for k4 in range(nsg):
					var q4 = Geometry.get_closest_point_to_segment_2d(ep, jp[k4], jp[(k4 + 1) % jp.size()])
					if q4.distance_to(ep) <= 10.0:
						hit = true
						hit_q = q4
						break
				if not hit:
					continue
				junction = true
				var wb = made[mj].get("wall")
				if wb == null:
					continue
				if not jloop and jp.size() >= 2 \
						and (hit_q.distance_to(jp[0]) <= 12.0 \
						or hit_q.distance_to(jp[jp.size() - 1]) <= 12.0):
					# Endpoint-to-endpoint meeting: note the arm's direction
					# leaving the junction, resolved below.
					var dj = Vector2()
					if hit_q.distance_to(jp[0]) <= 12.0:
						dj = (jp[1] - jp[0]).normalized()
					else:
						dj = (jp[jp.size() - 2] - jp[jp.size() - 1]).normalized()
					end_arms.append([wb, dj])
				else:
					# The stem lands on mj's BODY: mj is a bar outright.
					body_bars.append(wb)
			var wa = made[mi].get("wall")
			if wa != null:
				for bb in body_bars:
					_cv_zcon_add(zcons, zseen, wa, bb)
				# Among coinciding endpoints, the two arms running straight
				# through each other form the bar; if this chain is itself
				# part of such a pair, it is a bar arm, not a stem.
				var self_straight = false
				for ar in end_arms:
					if ar[1].dot(d_self) < -0.6:
						self_straight = true
				if not self_straight:
					for ai in range(end_arms.size()):
						for aj in range(end_arms.size()):
							if ai == aj:
								continue
							if end_arms[ai][1].dot(end_arms[aj][1]) < -0.6:
								_cv_zcon_add(zcons, zseen, wa, end_arms[ai][0])
								break
			if junction and pillars_on and not _cv_junction_seen(seen, seen_pts, ep):
				var eprop = _cv_make_pillar(ep)
				if eprop != null:
					made_props.append(eprop)
	# Layering by topological rank. The iterative move_child settle
	# churned when two long walls touch at TWO junctions ([A above B]
	# here, [B above A] there - unsatisfiable per-wall), and the churn
	# scrambled perfectly satisfiable pairs (93 moves for 20
	# constraints). Ranks are computed once - bar outranks stem,
	# saturating at the cap so a cycle degrades locally - then applied
	# once.
	printerr("[SketchConv] z constraints: ", zcons.size())
	var zrank = {}
	for _zp in range(24):
		var zchanged = false
		for zc in zcons:
			var sa = zc[0]
			var sb = zc[1]
			if sa == null or sb == null or not is_instance_valid(sa) \
					or not is_instance_valid(sb):
				continue
			var ra = int(zrank.get(sa.get_instance_id(), 0))
			var rb = int(zrank.get(sb.get_instance_id(), 0))
			if rb <= ra and rb < 24:
				zrank[sb.get_instance_id()] = ra + 1
				if not zrank.has(sa.get_instance_id()):
					zrank[sa.get_instance_id()] = 0
				zchanged = true
		if not zchanged:
			break
	# Apply the ranks to BOTH orders: the child order is what DD saves,
	# z_index is what Godot renders (and always wins). Ranked walls are
	# raised to the top of the container in ascending rank order, so the
	# highest rank ends topmost. DD does not persist z_index: after a
	# map reload the child order alone carries the layering.
	for zr in range(0, 25):
		for m2 in made:
			var w2 = m2.get("wall")
			if w2 == null or not is_instance_valid(w2):
				continue
			if int(zrank.get(w2.get_instance_id(), -1)) != zr:
				continue
			w2.z_index = zr
			var par2 = w2.get_parent()
			if par2 != null:
				par2.move_child(w2, par2.get_child_count() - 1)
	printerr("[SketchConv] z ranks applied to ", zrank.size(), " walls")
	if pillars_on:
		# X crossings between chains, plus SELF-crossings (a wall
		# crossing itself: non-adjacent segment pairs of one chain).
		# _cv_seg_meet instead of the bare crossing test: junctions
		# sitting exactly on a lattice-snapped vertex were invisible to
		# segment_intersects_segment_2d, so same-wall crossings lost
		# their pillar.
		for mi2 in range(made.size()):
			var pa4 = made[mi2]["pts"]
			var na4 = pa4.size() - 1
			if bool(made[mi2]["loop"]):
				na4 = pa4.size()
			for ka2 in range(na4):
				for kb2 in range(ka2 + 2, na4):
					if bool(made[mi2]["loop"]) and ka2 == 0 and kb2 == na4 - 1:
						continue
					# Consecutive-but-one pairs flank one shared chord:
					# on curves they run close without crossing, so only
					# a hard contact counts for them.
					var eps_x = 6.0
					if kb2 == ka2 + 2:
						eps_x = 1.5
					var xps = _cv_seg_meet(
						pa4[ka2], pa4[(ka2 + 1) % pa4.size()],
						pa4[kb2], pa4[(kb2 + 1) % pa4.size()], eps_x)
					if xps == null or _cv_junction_seen(seen, seen_pts, xps):
						continue
					var sprop = _cv_make_pillar(xps)
					if sprop != null:
						made_props.append(sprop)
			for mj2 in range(mi2 + 1, made.size()):
				var pb4 = made[mj2]["pts"]
				var nb4 = pb4.size() - 1
				if bool(made[mj2]["loop"]):
					nb4 = pb4.size()
				for ka in range(na4):
					for kb in range(nb4):
						var xp = _cv_seg_meet(
							pa4[ka], pa4[(ka + 1) % pa4.size()],
							pb4[kb], pb4[(kb + 1) % pb4.size()], 6.0)
						if xp == null or _cv_junction_seen(seen, seen_pts, xp):
							continue
						var xprop = _cv_make_pillar(xp)
						if xprop != null:
							made_props.append(xprop)
		for m2 in made:
			var pts3 = m2["pts"]
			for vi in range(pts3.size()):
				if not bool(m2["loop"]) and (vi == 0 or vi == pts3.size() - 1):
					continue
				# No pillar on curve sampling points: a circle's chords
				# turn gently and stay short. Real corners (sharp angle)
				# and curve-straight junctions (one long, one short
				# neighbour) keep theirs.
				var vprev = pts3[(vi - 1 + pts3.size()) % pts3.size()]
				var vnext = pts3[(vi + 1) % pts3.size()]
				var d_in = (pts3[vi] - vprev).normalized()
				var d_out = (vnext - pts3[vi]).normalized()
				var turn = acos(clamp(d_in.dot(d_out), -1.0, 1.0))
				var long_in = vprev.distance_to(pts3[vi]) >= CELL * 0.85
				var long_out = pts3[vi].distance_to(vnext) >= CELL * 0.85
				if turn < 0.6 and not (long_in != long_out):
					continue
				if _cv_junction_seen(seen, seen_pts, pts3[vi]):
					continue
				var prop = _cv_make_pillar(pts3[vi])
				if prop != null:
					made_props.append(prop)
	# 6. One undo record for the whole conversion.
	var rec = PlanConvertRecord.new()
	rec.level_id = int(Global.World.Level.ID)
	rec.walls_node_ref = weakref(Global.World.Level.Walls)
	rec.objects_node_ref = weakref(Global.World.Level.Objects)
	rec.level_node_ref = weakref(Global.World.Level)
	for fs in made_fs:
		rec.fs_portals.append([fs[1], fs[2], fs[3], fs[4]])
		rec.fs_refs.append(weakref(fs[0]))
	made_props = _cv_pillar_overlap_pass(made_props)
	for pr2 in made_props:
		rec.props_data.append(pr2.Save())
		rec.prop_refs.append(weakref(pr2))
	for m in made:
		var d = m["wall"].Save()
		rec.walls_data.append(d)
		rec.wall_refs.append(weakref(m["wall"]))
		# Fallback-only: the weakrefs are the real deletion path (the id
		# formats proved unreliable across the GDScript/Mono boundary).
		var nid = d["node_id"]
		var idi = 0
		if typeof(nid) == TYPE_INT or typeof(nid) == TYPE_REAL:
			idi = int(nid)
		else:
			var hs = String(nid)
			if not hs.begins_with("0x"):
				hs = "0x" + hs
			idi = hs.hex_to_int()
		rec.wall_ids.append(idi)
	_convert_records.append(rec)
	if _convert_records.size() > 64:
		_convert_records.pop_front()
	Global.Editor.History.CreateCustomRecord(rec)
	# Soft Shadows opt-ins: their own pipelines, their own defaults.
	if _cvw != null:
		if bool(_cvw.get("soft_walls", false)):
			var ssw2 = _softshadows_walls_inst()
			if ssw2 != null:
				for mw in made:
					if mw.has("wall") and mw["wall"] != null and is_instance_valid(mw["wall"]):
						ssw2._apply_wall_tool_shadow(mw["wall"])
						# Realistic mode: mutate the saved entry, rebuild.
						if mw["wall"].has_meta("node_id"):
							var wid = str(mw["wall"].get_meta("node_id"))
							if Global.ModMapData.has("DropShadow") \
									and Global.ModMapData["DropShadow"].has(wid):
								Global.ModMapData["DropShadow"][wid]["render_mode"] = "realistic"
								if ssw2.has_method("_refresh_wall_shadow"):
									ssw2._refresh_wall_shadow(mw["wall"])
		if bool(_cvw.get("soft_pillars", false)):
			var ssp2 = _softshadows_objects_inst()
			if ssp2 != null:
				# Their OnAssignNode pipeline only shadows placements made
				# with DD's placement tools active: drive create_shadow
				# directly with the mod's factory defaults instead.
				var ocfg0 = ssp2.get("FACTORY_DEFAULTS")
				for mp in made_props:
					if mp == null or not is_instance_valid(mp):
						continue
					var ocfg = {}
					if ocfg0 is Dictionary:
						ocfg = ocfg0.duplicate(true)
					ocfg["enabled"] = true
					ssp2.create_shadow(mp, ocfg)
					if ssp2.has_method("save_shadow_data"):
						ssp2.save_shadow_data(mp, ocfg)
		if bool(_cvw.get("soft_building", false)):
			var ssb2 = _softshadows_building_inst()
			if ssb2 != null and ssb2.has_method("_do_pick_building"):
				var cnt = Vector2()
				var np = 0
				for mw2 in made:
					for pt5 in mw2["pts"]:
						cnt += pt5
						np += 1
				if np > 0:
					ssb2._do_pick_building(cnt / float(np))
					if ssb2.has_method("_on_apply_pressed"):
						ssb2._on_apply_pressed()
	# The DD walls now carry the drawing: hide the sketch (checkbox OFF
	# through its normal handler so every side effect applies).
	_cv_make_floors(made, holes)
	if _chk_visible != null and is_instance_valid(_chk_visible):
		_chk_visible.pressed = false
	_on_visible_toggled(false)
	_dbg("convert: " + str(made.size()) + " walls, " + str(n_portals) + " portals")


# Floors, VECTOR edition (the paint-bucket way, after Moulk's
# region_geometry): every wall segment and door span becomes a thin
# barrier QUAD, the quads are subtracted from the bounding rectangle
# with Geometry.clip_polygons_2d, and each CCW piece that does not
# touch the outer rectangle is one ROOM - exact along diagonals and
# tower arcs, where the old half-cell raster could only staircase.
# Each room then draws one floor picked at random among the wizard's
# Floor selection; patterns go through the Pattern tool's native
# selection + PatternShapes.DrawPolygon, tilesets through
# FloorShapeTool.SmartTileId + FloorShapes.DrawPolygon.
func _cv_make_floors(made: Array, holes: Array) -> void:
	if _cvw == null or not bool(_cvw.get("use_floor", false)):
		return
	var picks = _cvw.get("floor_picks", [])
	if picks.empty():
		printerr("[SketchConv] floor requested but nothing selected")
		return
	var rooms = _cv_floor_rooms(made, holes)
	if rooms.empty():
		printerr("[SketchConv] floor: no enclosed rooms found")
		return
	var level = Global.World.get("Level")
	if level == null:
		return
	var pat_tool = Global.Editor.Tools.get("PatternShapeTool")
	var flo_tool = Global.Editor.Tools.get("FloorShapeTool")
	var ps_node = level.get("PatternShapes")
	var fs_node = level.get("FloorShapes")
	var pat_menu = null
	if pat_tool != null:
		var ctl = pat_tool.get("Controls")
		if ctl != null and ctl.has("Texture"):
			pat_menu = ctl["Texture"]
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var made_n = 0
	for room in rooms:
		var pk = picks[rng.randi_range(0, picks.size() - 1)]
		if String(pk[0]) == "pat":
			if pat_tool == null or ps_node == null or pat_menu == null:
				continue
			var idx = int(pk[1])
			if idx >= pat_menu.get_item_count():
				continue
			# The REAL selection path: GridMenu.OnItemSelected is the
			# public C# entry that resolves the full-res texture from
			# the Library and fires the tool's own wiring - Texture
			# plus default Color.
			pat_menu.select(idx)
			pat_menu.call("OnItemSelected", idx)
			var got_tex = pat_tool.get("Texture")
			if got_tex == null:
				continue
			ps_node.DrawPolygon(room, false)
			made_n += 1
		else:
			if flo_tool == null or fs_node == null:
				continue
			# Tile id through the NATIVE list selection: the panel
			# binds the ItemList to the SmartTileId property.
			var tid = int(pk[1])
			var tlist = null
			var ctlf = flo_tool.get("Controls")
			if ctlf != null and ctlf.has("SmartTileId"):
				tlist = ctlf["SmartTileId"]
			if tlist != null and tid < tlist.get_item_count():
				tlist.select(tid)
				tlist.emit_signal("item_selected", tid)
			if fs_node.has_method("DrawPolygon"):
				fs_node.DrawPolygon(room, false)
				made_n += 1
			else:
				var rb = Rect2(room[0], Vector2())
				for p in room:
					rb = rb.expand(p)
				fs_node.DrawRect(rb, false)
				made_n += 1
	Global.Editor.Toolset.Quickswitch(TOOL_ID)
	printerr("[SketchConv] floors drawn: ", made_n, " room(s)")


# Room polygons from the wall geometry itself. Every wall segment and
# door span becomes a thin quad (ends extended so joints overlap), and
# the quads are UNIONED into wall-network blobs carrying their holes:
# the HOLES of the final union are exactly the enclosed rooms, precise
# along diagonals and tower arcs. (The earlier subtract-from-bounds
# version dropped Clipper's CW rings, so a closed wall ring never
# actually pierced the plane and no room ever separated: rooms panned
# out empty.) Each hole is re-inflated by the barrier half width so the
# floor edge lands ON the wall axis.
const FLOOR_BARRIER_HW = 6.0

func _cv_floor_rooms(made: Array, holes: Array) -> Array:
	var segs = []
	for m in made:
		var pts = m["pts"]
		var nseg = pts.size() - 1
		if bool(m["loop"]):
			nseg = pts.size()
		for k in range(nseg):
			segs.append([pts[k], pts[(k + 1) % pts.size()]])
	# Doorways are barriers too: corner-cut doors removed their wall
	# span, and without the plug two rooms merge through the door.
	for hv in holes:
		segs.append([hv[0], hv[1]])
	if segs.empty():
		return []
	var hw = FLOOR_BARRIER_HW
	# blob: {"o": outer CCW, "h": [hole CCW], "bb": Rect2}
	var blobs = []
	for sg in segs:
		var a = sg[0]
		var b = sg[1]
		if a.distance_to(b) < 0.5:
			continue
		var dir = (b - a).normalized()
		var nrm = Vector2(-dir.y, dir.x) * hw
		var a2 = a - dir * hw
		var b2 = b + dir * hw
		var cur_o = PoolVector2Array([a2 + nrm, b2 + nrm, b2 - nrm, a2 - nrm])
		var cur_h = []
		var cur_bb = Rect2(cur_o[0], Vector2())
		for qp in cur_o:
			cur_bb = cur_bb.expand(qp)
		# Merge into every blob it touches, transitively: a quad can
		# bridge two separate sub-networks.
		var again = true
		while again:
			again = false
			for bi in range(blobs.size()):
				if not blobs[bi]["bb"].intersects(cur_bb):
					continue
				if Geometry.intersect_polygons_2d(blobs[bi]["o"], cur_o).size() == 0:
					continue
				var res = Geometry.merge_polygons_2d(blobs[bi]["o"], cur_o)
				var new_o = null
				var rings = []
				for rp in res:
					if Geometry.is_polygon_clockwise(rp):
						rings.append(_merge_ccw(rp))
					elif new_o == null:
						new_o = rp
				if new_o == null:
					continue
				# Holes survive minus whatever the other side's solid
				# covers; rings closed by THIS merge are new holes.
				var nh = []
				for h0 in blobs[bi]["h"]:
					for hp in Geometry.clip_polygons_2d(h0, cur_o):
						if not Geometry.is_polygon_clockwise(hp) and hp.size() >= 3:
							nh.append(hp)
				for h1 in cur_h:
					for hp2 in Geometry.clip_polygons_2d(h1, blobs[bi]["o"]):
						if not Geometry.is_polygon_clockwise(hp2) and hp2.size() >= 3:
							nh.append(hp2)
				for rg in rings:
					nh.append(rg)
				cur_o = new_o
				cur_h = nh
				cur_bb = Rect2(cur_o[0], Vector2())
				for qp2 in cur_o:
					cur_bb = cur_bb.expand(qp2)
				blobs.remove(bi)
				again = true
				break
		blobs.append({"o": cur_o, "h": cur_h, "bb": cur_bb})
	var rooms = []
	for blob in blobs:
		for h in blob["h"]:
			if abs(_cv_poly_area(h)) < CELL * CELL * 0.4:
				continue
			# Re-inflate by the barrier half width: the floor edge
			# lands exactly on the wall axis.
			for gp in Geometry.offset_polygon_2d(h, hw + 1.0, Geometry.JOIN_MITER):
				if not Geometry.is_polygon_clockwise(gp) and gp.size() >= 3:
					rooms.append(gp)
	return rooms


func _cv_poly_area(p) -> float:
	var a = 0.0
	var n = p.size()
	for i in range(n):
		var q = p[i]
		var r = p[(i + 1) % n]
		a += q.x * r.y - r.x * q.y
	return a * 0.5


# Fuses open chains whose endpoints nearly coincide (junction leftovers
# that exact-key chaining missed), closing loops when both ends meet.
# Dwarf chains are skeleton artifacts (typically window holes punched
# on chamfered corners: short hooks and mini-loops), not walls. The
# earlier version only dropped dwarfs TOUCHING another chain and missed
# them all: the hole erasure leaves them free-hanging.
# ---------------------------------------------------------------------------
# Circle detection and rebuild.
# Kasa least-squares circle fit. Returns [center, radius, rms] or null.
func _cv_fit_circle(pts: Array):
	var n = pts.size()
	if n < 5:
		return null
	# Solve  x^2+y^2 + D x + E y + F = 0  in least squares.
	var sxx = 0.0
	var sxy = 0.0
	var syy = 0.0
	var sx = 0.0
	var sy = 0.0
	var sxz = 0.0
	var syz = 0.0
	var sz = 0.0
	for p in pts:
		var z = p.x * p.x + p.y * p.y
		sxx += p.x * p.x
		sxy += p.x * p.y
		syy += p.y * p.y
		sx += p.x
		sy += p.y
		sxz += p.x * z
		syz += p.y * z
		sz += z
	var nn = float(n)
	# Normal equations for [D, E, F].
	var a11 = sxx
	var a12 = sxy
	var a13 = sx
	var a22 = syy
	var a23 = sy
	var a33 = nn
	var b1 = -sxz
	var b2 = -syz
	var b3 = -sz
	var det = a11 * (a22 * a33 - a23 * a23) - a12 * (a12 * a33 - a23 * a13) \
		+ a13 * (a12 * a23 - a22 * a13)
	if abs(det) < 1e-6:
		return null
	var d1 = b1 * (a22 * a33 - a23 * a23) - a12 * (b2 * a33 - a23 * b3) \
		+ a13 * (b2 * a23 - a22 * b3)
	var d2 = a11 * (b2 * a33 - a23 * b3) - b1 * (a12 * a33 - a23 * a13) \
		+ a13 * (a12 * b3 - b2 * a13)
	var d3 = a11 * (a22 * b3 - b2 * a23) - a12 * (a12 * b3 - b2 * a13) \
		+ b1 * (a12 * a23 - a22 * a13)
	var dd = d1 / det
	var ee = d2 / det
	var ff = d3 / det
	var c = Vector2(-dd * 0.5, -ee * 0.5)
	var r2 = c.length_squared() - ff
	if r2 <= 4.0:
		return null
	var r = sqrt(r2)
	var rms = 0.0
	for p2 in pts:
		var e2 = p2.distance_to(c) - r
		rms += e2 * e2
	rms = sqrt(rms / nn)
	return [c, r, rms]


# Angular interval of a chain around center c: [a0, span] with span
# accumulated point to point (handles wrap and both windings).
func _cv_chain_arc_interval(pts: Array, c: Vector2) -> Array:
	var a0 = (pts[0] - c).angle()
	var acc = 0.0
	var prev = a0
	for i in range(1, pts.size()):
		var an = (pts[i] - c).angle()
		var dl = wrapf(an - prev, -PI, PI)
		acc += dl
		prev = an
	return [a0, acc]


# Stitches open chains whose ENDPOINTS face each other within tol
# (endpoint-to-endpoint - the weld pass only handles endpoint-to-body
# T contacts), then closes any chain whose own two ends meet.
# Flattens the axis-aligned runs of every chain: consecutive segments
# steeper than 5:1 toward the same axis, at least 100 px long and with
# a cross-spread under 14 px, get their constant coordinate set to the
# run's median (snapped to the half-cell lattice when within 16 px).
# A vertex shared by a horizontal and a vertical run receives both
# treatments and lands exactly on the corner.
# Chaikin corner-cutting (endpoint-preserving) on the curvy runs of
# non-arc chains: at least 3 consecutive vertices each turning between
# ~3 and ~49 degrees in any direction.
func _cv_smooth_curvy_runs(chains: Array) -> Array:
	var out = []
	for ch in chains:
		if bool(ch.get("arc", false)) or ch["pts"].size() < 5:
			out.append(ch)
			continue
		var pts = ch["pts"]
		var lp = bool(ch["loop"])
		if lp:
			# Start at the flattest vertex: runs never straddle the seam.
			var bi = 0
			var bt = 1e9
			for i in range(pts.size()):
				var pa = pts[(i - 1 + pts.size()) % pts.size()]
				var pb = pts[i]
				var pc2 = pts[(i + 1) % pts.size()]
				if pb.distance_to(pa) < 0.5 or pc2.distance_to(pb) < 0.5:
					continue
				var t = abs((pb - pa).normalized().angle_to((pc2 - pb).normalized()))
				if t < bt:
					bt = t
					bi = i
			var rot = []
			for i2 in range(pts.size()):
				rot.append(pts[(bi + i2) % pts.size()])
			pts = rot
		var n = pts.size()
		var curvy = []
		for t2 in range(n):
			if t2 == 0 or t2 == n - 1:
				curvy.append(false)
				continue
			var tv = abs((pts[t2] - pts[t2 - 1]).normalized() \
				.angle_to((pts[t2 + 1] - pts[t2]).normalized()))
			# Real curve chords are SHORT. Two chamfered corners at the
			# two ends of one long straight are consecutive VERTICES,
			# and without this gate they qualified as one "curvy run" -
			# the whole wing bottom then melted into a giant curve.
			var cin = pts[t2].distance_to(pts[t2 - 1])
			var cout = pts[t2 + 1].distance_to(pts[t2])
			curvy.append(tv > 0.05 and tv < 0.85 \
					and cin <= CELL * 1.7 and cout <= CELL * 1.7)
		var new_pts = []
		var cur = 0
		while cur < n:
			if not curvy[cur]:
				new_pts.append(pts[cur])
				cur += 1
				continue
			var t1 = cur
			while t1 < n and curvy[t1]:
				t1 += 1
			# Turning vertices cur..t1-1; needs >= 3 to be a curve.
			if t1 - cur < 3:
				while cur < t1:
					new_pts.append(pts[cur])
					cur += 1
				continue
			# Span from the vertex before to the vertex after, both
			# preserved exactly (junctions stay welded).
			var sa = int(max(0, cur - 1))
			var sb = int(min(n - 1, t1))
			var run = []
			for k in range(sa, sb + 1):
				run.append(pts[k])
			run = _cv_chaikin(run, 2)
			# new_pts already holds pts[sa] (the previous iteration
			# appended it): skip the duplicate.
			var start_k = 1 if new_pts.size() > 0 and new_pts[new_pts.size() - 1].distance_to(run[0]) < 0.5 else 0
			for k2 in range(start_k, run.size()):
				new_pts.append(run[k2])
			cur = sb + 1
		if new_pts.size() >= 2:
			out.append({"pts": new_pts, "loop": lp})
		else:
			out.append({"pts": pts, "loop": lp})
	return out


# Endpoint-preserving Chaikin subdivision.
func _cv_chaikin(pts: Array, iters: int) -> Array:
	var cur = pts
	for _it in range(iters):
		if cur.size() < 3:
			return cur
		var nxt = [cur[0]]
		for i in range(cur.size() - 1):
			nxt.append(cur[i] * 0.75 + cur[i + 1] * 0.25)
			nxt.append(cur[i] * 0.25 + cur[i + 1] * 0.75)
		nxt.append(cur[cur.size() - 1])
		cur = nxt
	return cur


func _cv_axis_straighten(chains: Array) -> Array:
	for ch in chains:
		if bool(ch.get("arc", false)):
			# Rebuilt circles and arcs: never flatten their caps (the
			# cardinal chords fooled every heuristic).
			continue
		var pts = ch["pts"]
		var n = pts.size()
		if n < 2:
			continue
		var nseg = n - 1
		if bool(ch["loop"]):
			nseg = n
		var i = 0
		while i < nseg:
			var ax = _cv_seg_axis(pts[(i + 1) % n] - pts[i])
			if ax < 0:
				i += 1
				continue
			var j = i
			var lenr = 0.0
			var maxseg = 0.0
			while j < nseg and _cv_seg_axis(pts[(j + 1) % n] - pts[j]) == ax:
				var sl = (pts[(j + 1) % n] - pts[j]).length()
				lenr += sl
				maxseg = max(maxseg, sl)
				j += 1
			# A run of uniformly SHORT chords is a sampled curve inside
			# a mixed chain (spliced bastion): leave it alone.
			if lenr >= 100.0 and (maxseg >= 70.0 or j - i <= 2):
				var vals = []
				for k in range(i, j + 1):
					var pk = pts[k % n]
					vals.append(pk.y if ax == 0 else pk.x)
				vals.sort()
				var med = float(vals[vals.size() / 2])
				var dev = max(abs(float(vals[0]) - med), abs(float(vals[vals.size() - 1]) - med))
				if dev <= 14.0:
					var snapped = round(med / (CELL * 0.5)) * (CELL * 0.5)
					if abs(snapped - med) <= 16.0:
						med = snapped
					for k2 in range(i, j + 1):
						var idx = k2 % n
						if ax == 0:
							pts[idx] = Vector2(pts[idx].x, med)
						else:
							pts[idx] = Vector2(med, pts[idx].y)
			i = int(max(j, i + 1))
	return chains


# 0 = horizontal (y constant), 1 = vertical, -1 = neither (diagonals,
# arc chords). 5:1 is about 11 degrees: chamfers never qualify.
func _cv_seg_axis(d: Vector2) -> int:
	if d.length() < 0.5:
		return -1
	if abs(d.x) >= abs(d.y) * 5.0:
		return 0
	if abs(d.y) >= abs(d.x) * 5.0:
		return 1
	return -1


func _cv_join_chains(chains: Array, tol: float) -> Array:
	var closed = []
	var open = []
	for ch in chains:
		if bool(ch["loop"]):
			closed.append(ch)
		else:
			open.append(ch)
	var n_join = 0
	var closest_miss = 1e9
	var guard = 0
	while guard < 200:
		guard += 1
		var bi = -1
		var bj = -1
		var bei = 0
		var bej = 0
		var bd = tol
		for i in range(open.size()):
			for j in range(i + 1, open.size()):
				for ei in [0, 1]:
					for ej in [0, 1]:
						var pi2 = open[i]["pts"][0] if ei == 0 else open[i]["pts"][open[i]["pts"].size() - 1]
						var pj = open[j]["pts"][0] if ej == 0 else open[j]["pts"][open[j]["pts"].size() - 1]
						var d = pi2.distance_to(pj)
						if d < bd:
							bd = d
							bi = i
							bj = j
							bei = ei
							bej = ej
		if bi < 0:
			break
		n_join += 1
		# Orient A to END at the meeting point, B to START there.
		var pa = open[bi]["pts"]
		var pb = open[bj]["pts"]
		if bei == 0:
			pa.invert()
		if bej == 1:
			pb.invert()
		# GEOMETRIC stitch: raw concatenation bent every rebuilt
		# corner into a bevel and left lateral jogs on straights.
		var skip_first = false
		if pa.size() >= 2 and pb.size() >= 2:
			var e1 = pa[pa.size() - 1]
			var d1 = (e1 - pa[pa.size() - 2]).normalized()
			var b0 = pb[0]
			var d2 = (pb[1] - b0).normalized()
			var end_a = (e1 - pa[pa.size() - 2]).length()
			var end_b = (pb[1] - b0).length()
			if d1.dot(d2) > 0.87:
				# Nearly collinear: ONE shared point, the one closest
				# to the half-cell lattice.
				var keep2 = e1 if _cv_off_lattice(e1) <= _cv_off_lattice(b0) + 0.5 else b0
				pa[pa.size() - 1] = keep2
				skip_first = true
			elif abs(d1.dot(d2)) <= 0.87 and end_a >= 60.0 and end_b >= 60.0:
				# The sharp-corner extension is for STRAIGHT runs only:
				# on curve fragments (short end chords) it planted
				# spikes off the ellipses - those get plain
				# concatenation, Chaikin rounds the bridge.
				# Crossing runs (a corner): extend both to their line
				# intersection, the single sharp vertex.
				var xp = Geometry.line_intersects_line_2d(e1, d1, b0, -d2)
				if xp != null and xp is Vector2 \
						and xp.distance_to(e1) <= 140.0 and xp.distance_to(b0) <= 140.0:
					pa[pa.size() - 1] = xp
					skip_first = true
		for k in range(pb.size()):
			if k == 0 and (skip_first or pb[0].distance_to(pa[pa.size() - 1]) < 2.0):
				continue
			pa.append(pb[k])
		var merged = {"pts": pa, "loop": false}
		var rest = []
		for x in range(open.size()):
			if x != bi and x != bj:
				rest.append(open[x])
		rest.append(merged)
		open = rest
	# Close the chains whose own ends meet.
	var out = closed
	for ch2 in open:
		var pts = ch2["pts"]
		var endgap = pts[0].distance_to(pts[pts.size() - 1])
		if pts.size() >= 4 and endgap <= tol and _cv_polyline_len(pts) > 200.0:
			if endgap < 2.0:
				pts.remove(pts.size() - 1)
			out.append({"pts": pts, "loop": true})
			printerr("[SketchConv] chain closed into a loop (", pts.size(), " pts)")
		else:
			if pts.size() >= 4 and _cv_polyline_len(pts) > 200.0 and endgap < 1e8:
				printerr("[SketchConv] open chain end gap: ", endgap)
			out.append(ch2)
	# TRUE remaining minimum endpoint gap (the earlier stat mixed in
	# intermediate candidates and lied).
	for i2 in range(open.size()):
		for j2 in range(i2 + 1, open.size()):
			for ei2 in [0, 1]:
				for ej2 in [0, 1]:
					var q1 = open[i2]["pts"][0] if ei2 == 0 else open[i2]["pts"][open[i2]["pts"].size() - 1]
					var q2 = open[j2]["pts"][0] if ej2 == 0 else open[j2]["pts"][open[j2]["pts"].size() - 1]
					closest_miss = min(closest_miss, q1.distance_to(q2))
	printerr("[SketchConv] join pass: ", n_join, " join(s), smallest remaining endpoint gap ",
		closest_miss if closest_miss < 1e8 else -1.0)
	return out


func _cv_smooth_runs(pts, loop: bool, pw: float) -> Array:
	var n = pts.size()
	if n < 8:
		return []
	var runs = []
	var lim = (2 * n) if loop else n
	var run_start = -1
	var run_sign = 0
	var vi = 1
	while vi < lim - 1:
		var i0 = (vi - 1) % n
		var i1 = vi % n
		var i2 = (vi + 1) % n
		var d0 = pts[i1] - pts[i0]
		var d1 = pts[i2] - pts[i1]
		var ok = d0.length() >= 2.0 * pw and d1.length() >= 2.0 * pw
		var t = 0.0
		if ok:
			t = d0.normalized().angle_to(d1.normalized())
			ok = abs(t) >= 0.02 and abs(t) <= 0.6
		var sgn = int(sign(t))
		if ok and (run_sign == 0 or sgn == run_sign):
			if run_start < 0:
				run_start = vi - 1
			run_sign = sgn
			vi += 1
			if vi - run_start < n + 1:
				continue
		if run_start >= 0 and run_start < n:
			# run_start >= n would be the wrap lap re-finding the same
			# run: first lap already recorded it.
			var count = min(vi + 1 - run_start, n)
			if count >= 6:
				var rpts = []
				for k in range(run_start, run_start + count):
					rpts.append(pts[k % n])
				if _cv_polyline_len(rpts) >= 150.0:
					runs.append(rpts)
			if not loop and runs.size() == 0 and vi >= lim - 2:
				pass
		run_start = -1
		run_sign = 0
		vi += 1
	if run_start >= 0 and run_start < n:
		var count2 = min(lim - run_start, n)
		if count2 >= 6:
			var rpts2 = []
			for k2 in range(run_start, run_start + count2):
				rpts2.append(pts[k2 % n])
			if _cv_polyline_len(rpts2) >= 150.0:
				runs.append(rpts2)
	return runs


# Splits one chain against a ring: returns [members, rest]. A chain
# entirely on the ring stays whole; a mixed chain is cut at every ring
# entry/exit, boundary vertices shared so walls keep touching the arc.
# Short on-ring blips (under 3 points or 100 px) stay with the walls.
func _cv_ring_split(ch: Dictionary, c0: Vector2, r0: float, tol2: float) -> Array:
	var pts = ch["pts"]
	var n = pts.size()
	if n < 2:
		return [[], [ch]]
	var flags = []
	var n_on = 0
	for p in pts:
		var on = abs(p.distance_to(c0) - r0) <= tol2
		flags.append(on)
		if on:
			n_on += 1
	if n_on == n:
		return [[ch], []]
	if n_on == 0:
		return [[], [ch]]
	var order = range(n)
	var looped = bool(ch.get("loop", false))
	if looped:
		# Rotate so index 0 starts an OFF run: the walk then never
		# wraps mid-run.
		var start = -1
		for i in range(n):
			if not flags[i] and flags[(i - 1 + n) % n]:
				start = i
				break
		if start < 0:
			start = 0
		var order2 = []
		for i2 in range(n):
			order2.append((start + i2) % n)
		order = order2
	# Run list in walk order.
	var runs = []
	for oi in order:
		if runs.size() > 0 and runs[runs.size() - 1][0] == flags[oi]:
			runs[runs.size() - 1][1].append(pts[oi])
		else:
			runs.append([flags[oi], [pts[oi]]])
	# Downgrade insignificant on-runs, then re-merge neighbours.
	for r in runs:
		if r[0] and (r[1].size() < 3 or _cv_polyline_len(r[1]) < 100.0):
			r[0] = false
	var merged = []
	for r2 in runs:
		if merged.size() > 0 and merged[merged.size() - 1][0] == r2[0]:
			for p2 in r2[1]:
				merged[merged.size() - 1][1].append(p2)
		else:
			merged.append(r2)
	if merged.size() == 1:
		if merged[0][0]:
			return [[ch], []]
		return [[], [ch]]
	var members = []
	var rest = []
	for mi in range(merged.size()):
		var mr = merged[mi]
		var rpts = []
		# SYMMETRIC boundary sharing: OFF pieces extend to the
		# junction vertices on BOTH sides (previous run's last point
		# and next run's first point), so the wall segments crossing
		# the ring boundary stay whole. Members keep only their pure
		# on-ring points: stuffing the off-side corner into a member
		# fed it to the arc rebuild, which then REPLACED the polyline
		# and silently ate the corner-to-junction wall segment.
		if not mr[0]:
			if mi > 0:
				var prev = merged[mi - 1][1]
				rpts.append(prev[prev.size() - 1])
			elif looped:
				var last = merged[merged.size() - 1][1]
				rpts.append(last[last.size() - 1])
		for p3 in mr[1]:
			rpts.append(p3)
		if not mr[0]:
			if mi < merged.size() - 1:
				rpts.append(merged[mi + 1][1][0])
			elif looped:
				rpts.append(merged[0][1][0])
		if rpts.size() < 2:
			continue
		var pd = ch.duplicate(true)
		pd["pts"] = rpts
		pd["loop"] = false
		if mr[0]:
			members.append(pd)
		else:
			# Leftovers can double-cover walls in degenerate walks:
			# any later "rebuild" of a curve run inside one would
			# shortcut real geometry, so they are tagged to stay raw.
			pd["raw_rest"] = true
			rest.append(pd)
	return [members, rest]


func _cv_circle_pass(chains: Array) -> Array:
	# Seeded ring growth. Short arc fragments fit circles with wildly
	# unstable centers (a short arc barely constrains them), so
	# per-fragment clustering scattered one tower into several
	# mismatched arcs. Instead: take the most trustworthy fragment as
	# the SEED, absorb every chain hugging its ring (crumbs included),
	# refit the circle on the union of their points, and rebuild.
	# World size of one texture pixel: quantization noise (and so every
	# absolute rms/tolerance below) scales with it on big maps.
	var pw = max(1.0, 1.0 / _tex_scale)
	# Mixed chains (a circle WELDED to its adjoining straight walls by
	# the chain assembly, often as one closed loop) fit nothing as a
	# whole: SMOOTH SAME-SIGN TURNING RUNS are extracted as extra seed
	# candidates - threshold-light, corner shape irrelevant - while
	# the originals stay whole. Membership later SPLITS the originals
	# at the ring, so nothing is ever emitted twice.
	var pool = []
	var cands = []
	for ch in chains:
		pool.append(ch)
		for run in _cv_smooth_runs(ch["pts"], bool(ch.get("loop", false)), pw):
			cands.append({"pts": run, "loop": false, "cand": true})
	var out = []
	var guard = 0
	while guard < 40:
		guard += 1
		var best_ch = null
		var best_fit = null
		var best_score = 0.0
		var seedables = []
		for sc in pool:
			seedables.append(sc)
		for sc2 in cands:
			seedables.append(sc2)
		for i in range(seedables.size()):
			var pts = seedables[i]["pts"]
			var ln = _cv_polyline_len(pts)
			if pts.size() < 6 or ln < 150.0:
				continue
			var fit = _cv_fit_circle(pts)
			if fit == null:
				continue
			var r = float(fit[1])
			# ABSOLUTE rms cap: a radius-proportional threshold let a
			# loop of ROOM WALLS pass for a giant circle (4% of r 3000
			# tolerates 120 px), hallucinating arcs out of floor plans.
			if r < 45.0 or r > 5000.0 or float(fit[2]) > min(max(5.0 * pw, r * 0.04), 26.0 * pw):
				continue
			# A staircase of right angles accumulates signed turning
			# like an arc does: reject seeds carrying sharp corners.
			var sharp = 0
			for tv in range(1, pts.size() - 1):
				# Pixel-noise micro-segments turn wildly without being
				# corners: only real-length edges vote.
				if pts[tv].distance_to(pts[tv - 1]) < 3.0 * pw \
						or pts[tv + 1].distance_to(pts[tv]) < 3.0 * pw:
					continue
				if abs((pts[tv] - pts[tv - 1]).normalized() \
						.angle_to((pts[tv + 1] - pts[tv]).normalized())) > 0.7:
					sharp += 1
			if sharp > int(max(1, pts.size() / 12)):
				continue
			var iv = _cv_chain_arc_interval(pts, fit[0])
			if abs(iv[1]) < 0.9:
				# Under ~50 degrees the fit is too shaky for a seed.
				continue
			var score = ln * min(abs(iv[1]), TAU)
			if score > best_score:
				best_score = score
				best_ch = seedables[i]
				best_fit = fit
		if best_ch == null:
			break
		var c0 = best_fit[0]
		var r0 = float(best_fit[1])
		# TWO-PASS membership. Even the best fragment of a mid-size
		# tower fits an unstable circle (the log showed one tower
		# splitting into r 651/620/614 groups): pass 1 gathers the
		# family with a LOOSE, radius-scaled ring, the refit on their
		# united points converges onto the true circle, and pass 2
		# re-selects strictly against that refit.
		var tol1 = clamp(r0 * 0.15, 34.0 * pw, 80.0 * pw)
		var fam = [best_ch]
		for pi in range(pool.size()):
			if pool[pi] == best_ch:
				continue
			var on1 = pool[pi]["pts"].size() >= 2
			for p2 in pool[pi]["pts"]:
				if abs(p2.distance_to(c0) - r0) > tol1:
					on1 = false
					break
			if on1:
				fam.append(pool[pi])
		var allp = []
		for m0 in fam:
			for p3 in m0["pts"]:
				allp.append(p3)
		var refit = _cv_fit_circle(allp)
		if refit != null and float(refit[2]) <= min(max(6.0 * pw, float(refit[1]) * 0.06), 30.0 * pw):
			c0 = refit[0]
			r0 = float(refit[1])
		var members = []
		var rest = []
		# Strict ring, radius- AND pixel-scaled. Chains are SPLIT at
		# their ring entry/exit points: the on-ring runs feed the arc
		# (their endpoints snap the arc ends), the off-ring remainders
		# survive as ordinary walls - a circle welded to its adjoining
		# walls in one closed loop no longer needs to fit whole.
		var tol2 = clamp(max(r0 * 0.04, 5.0 * pw), 34.0, 140.0)
		for pi2 in range(pool.size()):
			var sp = _cv_ring_split(pool[pi2], c0, r0, tol2)
			for mm in sp[0]:
				members.append(mm)
			for rr in sp[1]:
				rest.append(rr)
		if members.empty():
			var keep_c0 = []
			for cd0 in cands:
				var spent0 = true
				for pcd0 in cd0["pts"]:
					if abs(pcd0.distance_to(c0) - r0) > tol2:
						spent0 = false
						break
				if not spent0:
					keep_c0.append(cd0)
			cands = keep_c0
			pool = rest
			continue
		# Final refit on the strict members.
		var allp2 = []
		for m in members:
			for p5 in m["pts"]:
				allp2.append(p5)
		var refit2 = _cv_fit_circle(allp2)
		if refit2 != null and float(refit2[2]) <= min(max(6.0 * pw, float(refit2[1]) * 0.06), 30.0 * pw):
			c0 = refit2[0]
			r0 = float(refit2[1])
		# Angular coverage (modulo 2 pi via tripled copies).
		var full = false
		var ivs = []
		var ends = []
		for m2 in members:
			var iv2 = _cv_chain_arc_interval(m2["pts"], c0)
			if bool(m2["loop"]) and abs(iv2[1]) > PI * 1.6:
				full = true
			var lo = min(iv2[0], iv2[0] + iv2[1])
			var span = min(abs(iv2[1]), TAU)
			var base = fposmod(lo, TAU)
			for shift in [-TAU, 0.0, TAU]:
				ivs.append([base + shift, base + shift + span])
			if not bool(m2["loop"]):
				ends.append(m2["pts"][0])
				ends.append(m2["pts"][m2["pts"].size() - 1])
		ivs.sort_custom(self, "_plan_iv_less")
		var mg = []
		for iv3 in ivs:
			if mg.size() > 0 and iv3[0] <= mg[mg.size() - 1][1] + 0.45:
				mg[mg.size() - 1][1] = max(mg[mg.size() - 1][1], iv3[1])
			else:
				mg.append([iv3[0], iv3[1]])
		if not full:
			var covered = 0.0
			for iv4 in mg:
				covered += max(0.0, min(iv4[1], TAU) - max(iv4[0], 0.0))
			if covered > TAU * 0.86:
				full = true
		# DD's own convention (native Arc Point flattening, matched by
		# the UP's arc_draw): ARC_SEGS_PER_QUARTER segments per quarter
		# turn whatever the radius. Partial arcs derive proportionally.
		var step_n = int(ARC_SEGS_PER_QUARTER * 4)
		if full:
			var cpts = []
			for k in range(step_n):
				var an2 = float(k) / float(step_n) * PI * 2.0
				cpts.append(c0 + Vector2(cos(an2), sin(an2)) * r0)
			out.append({"pts": cpts, "loop": true, "arc": true})
			printerr("[SketchConv] circle rebuilt at ", c0, " r ", r0,
				" from ", members.size(), " fragment(s)")
		else:
			var np = 0
			for iv5 in mg:
				if iv5[0] < 0.0 or iv5[0] >= TAU:
					continue
				var span2 = min(iv5[1], iv5[0] + TAU) - iv5[0]
				if span2 < 0.15:
					continue
				var nk = int(max(3, ceil(span2 / (PI * 2.0) * step_n)))
				var apts = []
				for k2 in range(nk + 1):
					var an3 = iv5[0] + span2 * float(k2) / float(nk)
					apts.append(c0 + Vector2(cos(an3), sin(an3)) * r0)
				# Snap the arc ends to the REAL fragment endpoints so
				# the junctions with the straight walls stay welded.
				for side in [0, apts.size() - 1]:
					var bestp = null
					var bd = 45.0
					for e in ends:
						var dd2 = e.distance_to(apts[side])
						if dd2 < bd:
							bd = dd2
							bestp = e
					if bestp != null:
						apts[side] = bestp
				out.append({"pts": apts, "loop": false, "arc": true})
				np += 1
			printerr("[SketchConv] arc rebuilt at ", c0, " r ", r0, " (",
				np, " piece(s) from ", members.size(), " fragment(s))")
		# Candidates hugging THIS ring are spent: without this, the
		# same candidate re-seeded the same circle until the guard
		# (39 ghost "0 piece" iterations in the field log).
		var keep_c = []
		for cd in cands:
			var spent = true
			for pcd in cd["pts"]:
				if abs(pcd.distance_to(c0) - r0) > tol2:
					spent = false
					break
			if not spent:
				keep_c.append(cd)
		cands = keep_c
		pool = rest
	for ch2 in pool:
		out.append(ch2)
	return out


# Wall / leftover chain endpoints within reach of a rebuilt arc end
# land EXACTLY on it. Runs LAST: any pass moving vertices afterwards
# (the axis straightener did) would peel the joints open again.
func _cv_weld_arc_ends(chains: Array) -> void:
	var pw = max(1.0, 1.0 / _tex_scale)
	var arc_ends = []
	for oc in chains:
		if bool(oc.get("arc", false)) and oc["pts"].size() >= 2:
			arc_ends.append(oc["pts"][0])
			arc_ends.append(oc["pts"][oc["pts"].size() - 1])
	if arc_ends.empty():
		return
	var wd = max(24.0, 3.0 * pw)
	for oc2 in chains:
		if bool(oc2.get("arc", false)) or oc2["pts"].size() < 2:
			continue
		for side in [0, oc2["pts"].size() - 1]:
			var bp = null
			var bdw = wd
			for ae in arc_ends:
				var dae = ae.distance_to(oc2["pts"][side])
				if dae > 0.01 and dae < bdw:
					bdw = dae
					bp = ae
			if bp != null:
				# Read-modify-write: indexed assignment through the
				# Dictionary is a silent no-op on PoolVector2Array.
				var plw = oc2["pts"]
				plw[side] = bp
				oc2["pts"] = plw


# Uniform arc-length resampling of a closed loop to m points.
func _cv_resample_loop(pts: Array, m: int) -> Array:
	var n = pts.size()
	var per = []
	var total = 0.0
	for k in range(n):
		var d = pts[k].distance_to(pts[(k + 1) % n])
		per.append(d)
		total += d
	if total < 1.0:
		return []
	var out = []
	var pos = 0.0
	var seg = 0
	for i in range(m):
		var t = float(i) * total / float(m)
		while seg < n and pos + per[seg] < t:
			pos += per[seg]
			seg += 1
		if seg >= n:
			seg = n - 1
		var f = 0.0
		if per[seg] > 0.0:
			f = (t - pos) / per[seg]
		out.append(pts[seg].linear_interpolate(pts[(seg + 1) % n], f))
	return out


# Centered-conic ellipse fit on a closed loop. Center = arc-length
# centroid; then 1/r^2 = A cos^2 + B sin^2 + C sin cos is LINEAR in
# (A, B, C) - solved by Cramer like the circle fit - and the principal
# axes fall out of (A, B, C). Returns
# [center, a, b, theta, radial rms, perimeter] or null.
func _cv_fit_ellipse_loop(pts: Array):
	if pts.size() < 8:
		return null
	var rs = _cv_resample_loop(pts, 128)
	if rs.empty():
		return null
	var per = 0.0
	for k in range(pts.size()):
		per += pts[k].distance_to(pts[(k + 1) % pts.size()])
	var c = Vector2()
	for p in rs:
		c += p
	c /= float(rs.size())
	var s11 = 0.0
	var s12 = 0.0
	var s13 = 0.0
	var s22 = 0.0
	var s23 = 0.0
	var s33 = 0.0
	var b1 = 0.0
	var b2 = 0.0
	var b3 = 0.0
	for p2 in rs:
		var d = p2 - c
		var r2 = d.length_squared()
		if r2 < 1.0:
			return null
		var u = d.x * d.x / r2
		var v = d.y * d.y / r2
		var wq = d.x * d.y / r2
		var yv = 1.0 / r2
		s11 += u * u
		s12 += u * v
		s13 += u * wq
		s22 += v * v
		s23 += v * wq
		s33 += wq * wq
		b1 += u * yv
		b2 += v * yv
		b3 += wq * yv
	var det = s11 * (s22 * s33 - s23 * s23) - s12 * (s12 * s33 - s23 * s13) \
		+ s13 * (s12 * s23 - s22 * s13)
	if abs(det) < 1e-12:
		return null
	var da = b1 * (s22 * s33 - s23 * s23) - s12 * (b2 * s33 - s23 * b3) \
		+ s13 * (b2 * s23 - s22 * b3)
	var db = s11 * (b2 * s33 - s23 * b3) - b1 * (s12 * s33 - s23 * s13) \
		+ s13 * (s12 * b3 - b2 * s13)
	var dc = s11 * (s22 * b3 - b2 * s23) - s12 * (s12 * b3 - b2 * s13) \
		+ b1 * (s12 * s23 - s22 * s13)
	var qa = da / det
	var qb = db / det
	var qc = dc / det
	var th = 0.5 * atan2(qc, qa - qb)
	var ca = cos(th)
	var sa = sin(th)
	var ap = qa * ca * ca + qb * sa * sa + qc * sa * ca
	var bp = qa * sa * sa + qb * ca * ca - qc * sa * ca
	if ap <= 0.0 or bp <= 0.0:
		return null
	var ea = 1.0 / sqrt(ap)
	var eb = 1.0 / sqrt(bp)
	var rms = 0.0
	for p3 in rs:
		var d2 = p3 - c
		var x2 = d2.x * ca + d2.y * sa
		var y2 = -d2.x * sa + d2.y * ca
		var ps = atan2(y2 / eb, x2 / ea)
		var ex = ea * cos(ps)
		var ey = eb * sin(ps)
		rms += (Vector2(x2, y2) - Vector2(ex, ey)).length_squared()
	rms = sqrt(rms / float(rs.size()))
	return [c, ea, eb, th, rms, per]


# Structural gate: an ellipse candidate turns gently, always the same
# way, one full revolution. Returns "" when the loop qualifies.
func _cv_ellipse_gate(pts: Array) -> String:
	var n = pts.size()
	var turns = []
	var tot = 0.0
	for i in range(n):
		var v1 = (pts[i] - pts[(i - 1 + n) % n]).normalized()
		var v2 = (pts[(i + 1) % n] - pts[i]).normalized()
		var t = v1.angle_to(v2)
		if abs(t) > 1.1:
			return "sharp corner"
		turns.append(t)
		tot += t
	var sgn = 1.0 if tot >= 0.0 else -1.0
	for t2 in turns:
		if sgn * t2 < -0.08:
			return "concave"
	if abs(abs(tot) - TAU) > TAU * 0.25:
		return "winding"
	return ""


# Closed all-convex gentle loops refit as exact ellipses and resampled.
# Straight-sided rooms are kept out by three independent gates: sharp
# corners (right angles), the chord cap (a straight side is far longer
# than any RDP chord a real curve can produce at that radius), and the
# radial rms (a chamfered rectangle sits 40+ px off its best ellipse).
func _cv_ellipse_pass(chains: Array) -> Array:
	var out = []
	for ch in chains:
		var pts = ch["pts"]
		if not bool(ch["loop"]) or bool(ch.get("arc", false)) or pts.size() < 8:
			out.append(ch)
			continue
		var why = _cv_ellipse_gate(pts)
		if why != "":
			out.append(ch)
			continue
		var fit = _cv_fit_ellipse_loop(pts)
		if fit == null:
			out.append(ch)
			continue
		var c = fit[0]
		var ea = float(fit[1])
		var eb = float(fit[2])
		var th = float(fit[3])
		var rms = float(fit[4])
		var per = float(fit[5])
		var maxchord = 0.0
		for k in range(pts.size()):
			maxchord = max(maxchord, pts[k].distance_to(pts[(k + 1) % pts.size()]))
		var chord_cap = 1.6 * sqrt(100.0 * max(ea, eb))
		if ea < 40.0 or ea > 5000.0 or eb < 40.0 \
				or rms > min(max(6.0, eb * 0.05), 30.0) or maxchord > chord_cap:
			out.append(ch)
			continue
		var step_n = int(clamp(per / 24.0, 32.0, 200.0))
		var ca2 = cos(th)
		var sa2 = sin(th)
		var epts = []
		for k2 in range(step_n):
			var ps2 = float(k2) / float(step_n) * TAU
			var ex2 = ea * cos(ps2)
			var ey2 = eb * sin(ps2)
			epts.append(c + Vector2(ex2 * ca2 - ey2 * sa2, ex2 * sa2 + ey2 * ca2))
		out.append({"pts": epts, "loop": true, "arc": true})
		printerr("[SketchConv] ellipse rebuilt at ", c, " a ", ea, " b ", eb,
			" theta ", th, " rms ", rms)
	return out


# Smooths the arc-like PORTIONS inside mixed chains: consecutive
# vertices turning steadily in one direction (bastions, apses) are
# refit as a circle and resampled between their EXACT end vertices, so
# the junctions with the straight walls stay welded.
func _cv_smooth_chain_arcs(chains: Array) -> Array:
	var out = []
	for ch in chains:
		var pts = ch["pts"]
		var lp = bool(ch["loop"])
		if bool(ch.get("arc", false)) or bool(ch.get("raw_rest", false)) \
				or pts.size() < 7:
			# Circle-pass arcs are ANALYTIC and final: re-detecting
			# them here rebuilt them at the old 24 px density and
			# dropped their flag, which then let the Chaikin pass
			# double them twice (48 -> 272 points in the field log).
			# Ring-split leftovers stay raw: rebuilding a curve run
			# inside their doubled-cover walk shortcut-erased walls.
			out.append(ch)
			continue
		if lp:
			# Start the loop at its flattest vertex so an arc never
			# straddles the seam.
			var bi = 0
			var bt = 1e9
			for i in range(pts.size()):
				var pa = pts[(i - 1 + pts.size()) % pts.size()]
				var pb = pts[i]
				var pc2 = pts[(i + 1) % pts.size()]
				if pb.distance_to(pa) < 0.5 or pc2.distance_to(pb) < 0.5:
					continue
				var t = abs((pb - pa).normalized().angle_to((pc2 - pb).normalized()))
				if t < bt:
					bt = t
					bi = i
			var rot = []
			for i2 in range(pts.size()):
				rot.append(pts[(bi + i2) % pts.size()])
			pts = rot
		var n = pts.size()
		# Turning angle at each interior vertex.
		var turns = []
		for t2 in range(n):
			if t2 == 0 or t2 == n - 1:
				turns.append(0.0)
				continue
			turns.append((pts[t2] - pts[t2 - 1]).normalized() \
				.angle_to((pts[t2 + 1] - pts[t2]).normalized()))
		var new_pts = []
		var cur = 0
		while cur < n:
			# Grow a run of same-sign, arc-like turning starting here.
			var t0 = cur
			while t0 < n - 1 and (abs(turns[t0]) < 0.05 or abs(turns[t0]) > 0.7):
				t0 += 1
			if t0 >= n - 1:
				break
			var sgn2 = sign(turns[t0])
			var t1 = t0
			var total = 0.0
			# Arc chords are SHORT: a long incoming segment means the
			# turning vertex belongs to a straight corner far away, not
			# to this curve - the run stops there instead of swallowing
			# a whole wall span into one giant arc.
			while t1 < n - 1 and sign(turns[t1]) == sgn2 \
					and abs(turns[t1]) >= 0.05 and abs(turns[t1]) <= 0.7 \
					and (t1 == t0 or pts[t1].distance_to(pts[t1 - 1]) <= CELL * 1.7):
				total += abs(turns[t1])
				t1 += 1
			# Span points: first turning vertex to one past the last.
			var sa = t0
			var sb = min(t1, n - 1)
			if total < 0.9 or sb - sa < 4:
				# Not arc-like enough: copy up to sb and move on.
				while cur <= sb and cur < n:
					new_pts.append(pts[cur])
					cur += 1
				continue
			var span_pts = []
			for si in range(sa, sb + 1):
				span_pts.append(pts[si])
			var fit = _cv_fit_circle(span_pts)
			if fit == null or float(fit[2]) > max(4.0, float(fit[1]) * 0.05) \
					or float(fit[1]) < 40.0 or float(fit[1]) > 5000.0:
				while cur <= sb and cur < n:
					new_pts.append(pts[cur])
					cur += 1
				continue
			var c3 = fit[0]
			var iv = _cv_chain_arc_interval(span_pts, c3)
			var a0 = float(iv[0])
			var span3 = float(iv[1])
			# Copy everything before the arc.
			while cur < sa:
				new_pts.append(pts[cur])
				cur += 1
			var nk = int(max(4, ceil(abs(span3) / (PI * 0.5) * ARC_SEGS_PER_QUARTER)))
			for k3 in range(nk + 1):
				var an4 = a0 + span3 * float(k3) / float(nk)
				new_pts.append(c3 + Vector2(cos(an4), sin(an4)) * float(fit[1]))
			# Exact junction endpoints.
			new_pts[new_pts.size() - nk - 1] = pts[sa]
			new_pts[new_pts.size() - 1] = pts[sb]
			cur = sb + 1
		while cur < n:
			new_pts.append(pts[cur])
			cur += 1
		if new_pts.size() >= 2:
			var pd = ch.duplicate(true)
			pd["pts"] = new_pts
			# Rebuilt portions are analytic arcs now: the flag keeps
			# the Chaikin pass off them. Untouched chains keep their
			# ORIGINAL dict (fields included).
			pd["arc"] = true
			out.append(pd)
		else:
			out.append(ch)
	return out


func _cv_prune_spurs(chains: Array, min_len: float) -> Array:
	var out = []
	for ch in chains:
		var pts = ch["pts"]
		var n = pts.size()
		var nseg = n - 1
		if bool(ch["loop"]):
			nseg = n
		var ln = 0.0
		for k in range(nseg):
			ln += pts[k].distance_to(pts[(k + 1) % n])
		if ln >= min_len:
			out.append(ch)
	return out


# Perimeter extraction: split the segment pool into connected
# components, walk each component's outer face into one closed loop,
# and hand back the leftover (interior) segments. A component whose
# walk fails (open structure, bridges walked twice, wrong face) simply
# contributes no loop and chains normally.
func _cv_extract_perimeters(pool: Array) -> Dictionary:
	var by_pt = {}
	var node_pos = {}
	for i in range(pool.size()):
		for e in range(2):
			var k = _cv_key(pool[i][e])
			if not by_pt.has(k):
				by_pt[k] = []
				node_pos[k] = pool[i][e]
			by_pt[k].append(i)
	# Connected components over segments.
	var comp = {}
	var ncomp = 0
	for i2 in range(pool.size()):
		if comp.has(i2):
			continue
		var stack = [i2]
		comp[i2] = ncomp
		while stack.size() > 0:
			var s = stack.pop_back()
			for e2 in range(2):
				for j in by_pt[_cv_key(pool[s][e2])]:
					if not comp.has(j):
						comp[j] = ncomp
						stack.append(j)
		ncomp += 1
	var loops = []
	var used = {}
	for c in range(ncomp):
		var res = _cv_walk_outer(pool, by_pt, node_pos, comp, c)
		if res.empty():
			continue
		for si in res["segs"]:
			used[si] = true
		loops.append({"pts": res["pts"], "loop": true})
	var rest = []
	for i3 in range(pool.size()):
		if not used.has(i3):
			rest.append(pool[i3])
	return {"loops": loops, "rest": rest}


# Walk the outer face of one component: start from its topmost node
# along the hull, at every node take the next edge clockwise from the
# arrival edge. Accept the loop only if it uses no segment twice and
# encloses every node of the component (the containment check rejects
# an inner-face walk, in which case the opposite turn rule is tried).
func _cv_walk_outer(pool: Array, by_pt: Dictionary, node_pos: Dictionary, comp: Dictionary, c: int) -> Dictionary:
	var start_key = ""
	var start_pos = Vector2()
	for k in by_pt:
		var in_comp = false
		for si in by_pt[k]:
			if int(comp.get(si, -1)) == c:
				in_comp = true
				break
		if not in_comp:
			continue
		var p = node_pos[k]
		if start_key == "" or p.y < start_pos.y - 0.5 \
				or (abs(p.y - start_pos.y) <= 0.5 and p.x < start_pos.x):
			start_key = k
			start_pos = p
	if start_key == "":
		return {}
	for turn_ccw in [false, true]:
		var res = _cv_walk_outer_try(pool, by_pt, node_pos, comp, c, start_key, start_pos, turn_ccw)
		if not res.empty() and _cv_loop_contains_component(res["pts"], by_pt, node_pos, comp, c):
			return res
	return {}


func _cv_walk_outer_try(pool: Array, by_pt: Dictionary, node_pos: Dictionary, comp: Dictionary, c: int, start_key: String, start_pos: Vector2, turn_ccw: bool) -> Dictionary:
	# First edge: the most rightward one out of the topmost node (a
	# hull edge for sure).
	var cur_seg = -1
	var best_x = -2.0
	for si in by_pt[start_key]:
		if int(comp.get(si, -1)) != c:
			continue
		var op = _cv_seg_other(pool[si], start_key)
		var dc = (op - start_pos).normalized()
		if dc.x > best_x:
			best_x = dc.x
			cur_seg = si
	if cur_seg < 0:
		return {}
	var pts = [start_pos]
	var segs = {}
	var cur_key = start_key
	var cur_pos = start_pos
	var guard = pool.size() * 2 + 8
	while guard > 0:
		guard -= 1
		if segs.has(cur_seg):
			return {}
		segs[cur_seg] = true
		var nxt = _cv_seg_other(pool[cur_seg], cur_key)
		var nxt_key = _cv_key(nxt)
		if nxt_key == start_key:
			if pts.size() >= 3:
				return {"pts": pts, "segs": segs.keys()}
			return {}
		pts.append(nxt)
		var d_in = (nxt - cur_pos).normalized()
		var rev = -d_in
		var best = -1
		var best_ang = 1e9
		for sj in by_pt[nxt_key]:
			if int(comp.get(sj, -1)) != c or sj == cur_seg:
				continue
			var op2 = _cv_seg_other(pool[sj], nxt_key)
			var dc2 = (op2 - nxt).normalized()
			var ang = wrapf(dc2.angle() - rev.angle(), 0.0, TAU)
			if turn_ccw:
				ang = TAU - ang
			if ang < 0.02:
				ang = TAU
			if ang < best_ang:
				best_ang = ang
				best = sj
		if best < 0:
			return {}
		cur_seg = best
		cur_key = nxt_key
		cur_pos = nxt
	return {}


func _cv_seg_other(seg, key: String) -> Vector2:
	if _cv_key(seg[0]) == key:
		return seg[1]
	return seg[0]


func _cv_loop_contains_component(pts: Array, by_pt: Dictionary, node_pos: Dictionary, comp: Dictionary, c: int) -> bool:
	var poly = PoolVector2Array(pts)
	for k in by_pt:
		var in_comp = false
		for si in by_pt[k]:
			if int(comp.get(si, -1)) == c:
				in_comp = true
				break
		if not in_comp:
			continue
		var p = node_pos[k]
		if Geometry.is_point_in_polygon(p, poly):
			continue
		# On-boundary points fail the inside test: allow anything within
		# a couple of pixels of a loop edge.
		var on_edge = false
		for i in range(pts.size()):
			var q = Geometry.get_closest_point_to_segment_2d(p, pts[i], pts[(i + 1) % pts.size()])
			if q.distance_to(p) <= 3.0:
				on_edge = true
				break
		if not on_edge:
			return false
	return true


# CreateFreestandingPortal returns VOID (the PortalTool ignores its
# result too): fish the freshly created Portal node back out of the
# level by position - a Node2D with WallID == -1 sitting on the spot.
func _cv_fish_freestanding(lvl, pos: Vector2):
	var stack = [lvl]
	var depth = {lvl.get_instance_id(): 0}
	var best = null
	while stack.size() > 0:
		var n = stack.pop_back()
		var d = int(depth.get(n.get_instance_id(), 0))
		for ch in n.get_children():
			if d < 2:
				depth[ch.get_instance_id()] = d + 1
				stack.append(ch)
			var wid = ch.get("WallID")
			if wid == null or int(wid) != -1:
				continue
			if ch.get("Radius") == null or not ch is Node2D:
				continue
			if ch.global_position.distance_to(pos) <= 8.0:
				best = ch
	return best


# Corner rule at the chain level: an opening touching a corner (or an
# end) of its best-aligned carrying chain removes the opening span from
# the chain itself - a REAL cut, no invisible portal - and queues one
# freestanding textured portal ([cls, center, dir]) for the zone.
func _cv_cut_corner_openings(chains: Array, holes: Array, fs_queue: Array, holes_cut: Dictionary) -> Array:
	var out = []
	for ch in chains:
		out.append(ch)
	for hi in range(holes.size()):
		var sg = holes[hi]
		var cls = 3
		if sg.size() > 2:
			cls = int(sg[2])
		var ptex = _cvw_portal_tex(cls)
		if ptex == null:
			continue
		var c = (sg[0] + sg[1]) * 0.5
		var hlen = sg[0].distance_to(sg[1])
		if hlen < 16.0:
			continue
		var hdir = (sg[1] - sg[0]).normalized()
		# Best-aligned carrying segment among all live chains.
		var best = null
		var bs = -1.0
		for ci in range(out.size()):
			if out[ci] == null:
				continue
			var pts = out[ci]["pts"]
			if pts.size() < 2:
				continue
			var ns = pts.size() - 1
			if bool(out[ci]["loop"]):
				ns = pts.size()
			for si in range(ns):
				var pa = pts[si]
				var pb = pts[(si + 1) % pts.size()]
				var q = Geometry.get_closest_point_to_segment_2d(c, pa, pb)
				var d = q.distance_to(c)
				if d > 14.0:
					continue
				var al = abs((pb - pa).normalized().dot(hdir))
				var sc = al * 100.0 - d
				if sc > bs:
					bs = sc
					best = [ci, si, q]
		if best == null:
			continue
		var ci2 = best[0]
		var pts2 = out[ci2]["pts"]
		var si2 = best[1]
		var pa2 = pts2[si2]
		var pb2 = pts2[(si2 + 1) % pts2.size()]
		var wdir = (pb2 - pa2).normalized()
		var seg_len = pa2.distance_to(pb2)
		var tmid = (best[2] - pa2).dot(wdir)
		if tmid - hlen * 0.5 > 12.0 and tmid + hlen * 0.5 < seg_len - 12.0:
			# Fully inside the segment: the chunked wall-portal path
			# handles it.
			continue
		var pre = 0.0
		for k in range(si2):
			pre += pts2[k].distance_to(pts2[(k + 1) % pts2.size()])
		# Cut exactly the PORTAL footprint (the texture width), only
		# within the matched segment: the freestanding covers precisely
		# what disappears, no wall gap peeking past the door frame and
		# no bite into the neighbouring segment.
		var rad_cut = float(ptex.get_width()) * 0.5
		var cut0 = pre + clamp(tmid - rad_cut, 0.0, seg_len)
		var cut1 = pre + clamp(tmid + rad_cut, 0.0, seg_len)
		printerr("[SketchConv] corner cut span [", cut0 - pre, ", ", cut1 - pre,
			"] on seg_len ", seg_len)
		var repl = _cv_chain_cut(out[ci2], cut0, cut1)
		printerr("[SketchConv] corner opening cut at ", c, " (chain ", ci2, " -> ", repl.size(), " piece(s))")
		holes_cut[hi] = true
		fs_queue.append([cls, c, hdir])
		if repl.size() > 0:
			out[ci2] = repl[0]
			for ri in range(1, repl.size()):
				out.append(repl[ri])
		else:
			out[ci2] = null
	var res = []
	for ch2 in out:
		if ch2 != null and ch2["pts"].size() >= 2:
			res.append(ch2)
	return res


# Removes the arc-length interval [s0, s1] from a chain. An open chain
# yields up to two open chains; a loop yields one open chain walking
# from s1 around to s0. Degenerate leftovers (under 8 px) are dropped.
func _cv_chain_cut(ch: Dictionary, s0: float, s1: float) -> Array:
	var pts = ch["pts"]
	var lp = bool(ch["loop"])
	var n = pts.size()
	var nseg = n - 1
	if lp:
		nseg = n
	var total = 0.0
	for k in range(nseg):
		total += pts[k].distance_to(pts[(k + 1) % n])
	s0 = clamp(s0, 0.0, total)
	s1 = clamp(s1, 0.0, total)
	if s1 - s0 < 4.0:
		return [ch]
	var part_a = [pts[0]]
	var part_b = []
	var acc = 0.0
	for k2 in range(nseg):
		var p0 = pts[k2]
		var p1 = pts[(k2 + 1) % n]
		var lg = max(0.001, p0.distance_to(p1))
		var e = acc + lg
		if e <= s0:
			part_a.append(p1)
		elif acc < s0:
			part_a.append(p0 + (p1 - p0) * ((s0 - acc) / lg))
		if acc < s1 and e > s1 - 0.001:
			# Cut end inside this segment OR exactly on its end vertex
			# (a clamped corner cut lands there): with a strict e > s1
			# the boundary segment emitted nothing and the next one
			# entered through the append-p1-only branch - part B then
			# started one vertex late and its first segment (the
			# chamfer diagonal of the U) silently vanished. The
			# interpolated point degenerates to p1 in the exact case
			# and dedup removes the duplicate.
			part_b.append(p0 + (p1 - p0) * ((s1 - acc) / lg))
			part_b.append(p1)
		elif acc >= s1 - 0.001:
			part_b.append(p1)
		acc = e
	var res = []
	if lp:
		# One open chain from s1 around the wrap back to s0. part_b ends
		# on pts[0] (the wrap), part_a starts there: drop the duplicate.
		var merged = part_b
		for ai in range(part_a.size()):
			if ai == 0 and merged.size() > 0 \
					and merged[merged.size() - 1].distance_to(part_a[0]) < 0.5:
				continue
			merged.append(part_a[ai])
		merged = _cv_dedup_close(merged)
		if merged.size() >= 2 and _cv_polyline_len(merged) >= 8.0:
			res.append({"pts": merged, "loop": false})
	else:
		part_a = _cv_dedup_close(part_a)
		part_b = _cv_dedup_close(part_b)
		if part_a.size() >= 2 and _cv_polyline_len(part_a) >= 8.0:
			res.append({"pts": part_a, "loop": false})
		if part_b.size() >= 2 and _cv_polyline_len(part_b) >= 8.0:
			res.append({"pts": part_b, "loop": false})
	return res


# The cut boundary can land near an existing vertex (the opening
# reaching the corner apex, plus trace jitter off the lattice): the
# near-coincident pair distorts DD's wall miter into a spike. Merge
# anything closer than 16 px to its predecessor and, of the pair, KEEP
# whichever point sits nearest the half-cell lattice - dropping the
# snapped apex in favour of a jittery cut boundary dragged the wall end
# off the grid.
func _cv_dedup_close(pts: Array) -> Array:
	if pts.size() < 2:
		return pts
	var out = [pts[0]]
	for k in range(1, pts.size()):
		var prev = out[out.size() - 1]
		if pts[k].distance_to(prev) >= 16.0:
			out.append(pts[k])
			continue
		if _cv_off_lattice(pts[k]) + 0.5 < _cv_off_lattice(prev):
			out[out.size() - 1] = pts[k]
	return out


func _cv_off_lattice(p: Vector2) -> float:
	return p.distance_to(_cv_lattice_snap(p))


func _cv_polyline_len(pts: Array) -> float:
	var t = 0.0
	for k in range(pts.size() - 1):
		t += pts[k].distance_to(pts[k + 1])
	return t


# One [stem, bar] constraint per wall pair: both stem endpoints (or
# several segment hits) can report the same junction.
func _cv_zcon_add(zcons: Array, zseen: Dictionary, wa, wb) -> void:
	var k = str(wa.get_instance_id()) + "_" + str(wb.get_instance_id())
	if zseen.has(k):
		return
	zseen[k] = true
	zcons.append([wa, wb])


# An open chain whose endpoint lands on a non-adjacent segment of its
# OWN body encloses a loop between the touch point and that endpoint.
# Split it: the loop becomes a closed chain, the rest stays open. This
# is what lets a self-T behave (pillar + stem-under-bar): both need two
# distinct Wall nodes.
func _cv_split_self_touch(chains: Array) -> Array:
	var out = []
	var queue = []
	for ch in chains:
		queue.append(ch)
	var guard = 0
	while queue.size() > 0 and guard < 256:
		guard += 1
		var ch = queue.pop_front()
		if bool(ch["loop"]):
			out.append(ch)
			continue
		var pts = ch["pts"]
		var n = pts.size()
		var done = false
		if n >= 4:
			for epi in [0, n - 1]:
				if done:
					break
				var ep = pts[epi]
				# Skip the two segments adjacent to this endpoint: those
				# touches are just the chain folding on the spot.
				var k_lo = 2
				var k_hi = n - 1
				if epi == n - 1:
					k_lo = 0
					k_hi = n - 3
				for k in range(k_lo, k_hi):
					var q = Geometry.get_closest_point_to_segment_2d(ep, pts[k], pts[k + 1])
					if q.distance_to(ep) > 10.0:
						continue
					var loop_pts = []
					var rest = []
					if epi == 0:
						# head touches (pk, pk+1): loop = p0..pk(+q),
						# rest = q, pk+1..pn-1
						for ii in range(0, k + 1):
							loop_pts.append(pts[ii])
						if q.distance_to(pts[k]) > 1.0:
							loop_pts.append(q)
						rest.append(q)
						for ii in range(k + 1, n):
							rest.append(pts[ii])
					else:
						# tail touches (pk, pk+1): loop = q, pk+1..pn-2,
						# rest = p0..pk, q
						loop_pts.append(q)
						for ii in range(k + 1, n - 1):
							loop_pts.append(pts[ii])
						for ii in range(0, k + 1):
							rest.append(pts[ii])
						rest.append(q)
					if loop_pts.size() >= 3:
						queue.append({"pts": loop_pts, "loop": true})
						if rest.size() >= 2:
							queue.append({"pts": rest, "loop": false})
						done = true
						break
		if not done:
			out.append(ch)
	return out


# Open endpoints within reach of another chain get moved exactly onto
# it, so T stems visually meet their bar instead of stopping a few
# pixels short (or overshooting by one).
func _cv_weld_junctions(chains: Array) -> void:
	for ci in range(chains.size()):
		if bool(chains[ci]["loop"]):
			continue
		var pts = chains[ci]["pts"]
		for epi in [0, pts.size() - 1]:
			var ep = pts[epi]
			var best = null
			var best_d = 10.0
			for cj in range(chains.size()):
				if cj == ci:
					continue
				var pj = chains[cj]["pts"]
				var nsg = pj.size() - 1
				if bool(chains[cj]["loop"]):
					nsg = pj.size()
				for k in range(nsg):
					var q = Geometry.get_closest_point_to_segment_2d(ep, pj[k], pj[(k + 1) % pj.size()])
					var d = q.distance_to(ep)
					if d < best_d:
						best_d = d
						best = q
			if best != null and best_d > 0.05:
				pts[epi] = best


# Drop duplicated consecutive points and degrade degenerate loops.
# Zero-length wall segments crash DD's native mesh/bevel build.
func _cv_clean_chains(chains: Array) -> Array:
	var out = []
	for ch in chains:
		var pts = ch["pts"]
		var cl = []
		for p in pts:
			if cl.size() == 0 or cl[cl.size() - 1].distance_to(p) > 1.0:
				cl.append(p)
		# Near-coincident vertex pairs (trace jitter beside a snapped
		# junction vertex) kink otherwise straight walls: merge under
		# 14 px keeping the point nearest the half-cell lattice. The
		# cut-side merge uses the same rule at 16.
		var cl2 = []
		for p2 in cl:
			if cl2.size() == 0 or p2.distance_to(cl2[cl2.size() - 1]) >= 14.0:
				cl2.append(p2)
			elif _cv_off_lattice(p2) + 0.5 < _cv_off_lattice(cl2[cl2.size() - 1]):
				cl2[cl2.size() - 1] = p2
		cl = cl2
		var lp = bool(ch["loop"])
		if lp and cl.size() >= 2 and cl[0].distance_to(cl[cl.size() - 1]) <= 14.0:
			if _cv_off_lattice(cl[cl.size() - 1]) + 0.5 < _cv_off_lattice(cl[0]):
				cl[0] = cl[cl.size() - 1]
			cl.remove(cl.size() - 1)
		if lp and cl.size() < 3:
			lp = false
		if cl.size() >= 2:
			out.append({"pts": cl, "loop": lp})
	return out


# Meeting point of two segments, or null. Wraps Godot's crossing test
# and adds vertex-on-segment contacts: segment_intersects_segment_2d
# misses meetings that sit exactly ON a vertex (its side test counts
# "touching" as non-crossing), which is where the lattice snap puts
# most junctions - the reason self-crossing pillars silently skipped.
func _cv_seg_meet(a1: Vector2, a2: Vector2, b1: Vector2, b2: Vector2, eps: float):
	var xp = Geometry.segment_intersects_segment_2d(a1, a2, b1, b2)
	if xp != null:
		return xp
	var best = null
	var best_d = eps
	for pr in [[a1, b1, b2], [a2, b1, b2], [b1, a1, a2], [b2, a1, a2]]:
		var q = Geometry.get_closest_point_to_segment_2d(pr[0], pr[1], pr[2])
		var d = q.distance_to(pr[0])
		if d <= best_d:
			best_d = d
			best = (q + pr[0]) * 0.5
	return best


# Position-based pillar dedup: exact-key plus a 12px radius, so the T
# pass and the X pass never stack two pillars on one junction.
func _cv_junction_seen(seen: Dictionary, seen_pts: Array, p: Vector2) -> bool:
	var k = str(int(round(p.x))) + "_" + str(int(round(p.y)))
	if seen.has(k):
		return true
	for sp in seen_pts:
		if sp.distance_to(p) <= 12.0:
			return true
	seen[k] = true
	seen_pts.append(p)
	return false


func _cv_make_pillar(pos: Vector2):
	var prop = Global.World.Level.Objects.CreateObject(0)
	if prop == null:
		return null
	prop.position = pos
	prop.z_index = 700
	_cv_pillar_setup(prop)
	var ps2 = 1.0
	if _cvw != null:
		ps2 = float(_cvw.get("pillar_scale", 1.0))
	if abs(ps2 - 1.0) > 0.001:
		# AFTER the mirror setup: multiplies whatever sign is there.
		prop.scale *= ps2
	prop.Texture = _cv_pick_pillar_tex()
	if prop.Texture == null:
		printerr("[SketchConv] pillar texture write failed (Mono property)")
		prop.queue_free()
		return null
	if not prop.has_meta("node_id"):
		Global.World.AssignNodeID(prop)
	# Objects.Save() reads GetMeta("preview") UNCONDITIONALLY on every
	# prop: without the meta the read throws, the try/catch swallows it
	# and the prop is silently SKIPPED from the save (pillars vanished
	# on reload). Objects.Resize() does the same unconditional read.
	prop.set_meta("preview", false)
	Global.World.Level.Objects.AddToSearchTable(prop, false)
	return prop


func _cv_fuse_chains(chains: Array, tol: float) -> Array:
	while true:
		# Nearest pair first, tie-broken by collinearity: at a junction
		# where three ends coincide (a T after the junction rule split
		# them), the two bar arms fuse together and the stem stays out,
		# instead of whichever pair the scan met first.
		var best_s = 1e18
		var bi = -1
		var bj = -1
		var bcombo = -1
		for i in range(chains.size()):
			if bool(chains[i]["loop"]):
				continue
			for j in range(i + 1, chains.size()):
				if bool(chains[j]["loop"]):
					continue
				var pa = chains[i]["pts"]
				var pb = chains[j]["pts"]
				var ds = [pa[pa.size() - 1].distance_to(pb[0]),
					pa[pa.size() - 1].distance_to(pb[pb.size() - 1]),
					pa[0].distance_to(pb[0]),
					pa[0].distance_to(pb[pb.size() - 1])]
				# Direction entering pa's end, dotted with the direction
				# leaving pb's end, per combo (1.0 = straight through).
				var in_a_tail = (pa[pa.size() - 1] - pa[pa.size() - 2]).normalized()
				var in_a_head = (pa[0] - pa[1]).normalized()
				var out_b_head = (pb[1] - pb[0]).normalized()
				var out_b_tail = (pb[pb.size() - 2] - pb[pb.size() - 1]).normalized()
				var dots = [in_a_tail.dot(out_b_head),
					in_a_tail.dot(out_b_tail),
					in_a_head.dot(out_b_head),
					in_a_head.dot(out_b_tail)]
				for c2 in range(4):
					if ds[c2] <= tol:
						var sc = ds[c2] - dots[c2] * tol * 0.35
						if sc < best_s:
							best_s = sc
							bi = i
							bj = j
							bcombo = c2
		if bi < 0:
			break
		var pa2 = chains[bi]["pts"]
		var pb2 = chains[bj]["pts"]
		# Combos and inversions, junction always pa2.tail <-> pb2.head:
		#   0: pa.tail-pb.head  -> none      1: pa.tail-pb.tail -> flip pb
		#   2: pa.head-pb.head  -> flip pa   3: pa.head-pb.tail -> flip both
		# (2 and 3 used to flip the WRONG side of pb: chains got glued by
		# the far end - offset "fake T" bars, lost stubs, and duplicated
		# points that crashed the native wall mesh build.)
		if bcombo == 1 or bcombo == 3:
			pb2.invert()
		if bcombo == 2 or bcombo == 3:
			pa2.invert()
		for k in range(1, pb2.size()):
			pa2.append(pb2[k])
		chains[bi]["pts"] = pa2
		chains.remove(bj)
		if pa2[0].distance_to(pa2[pa2.size() - 1]) <= tol:
			pa2.remove(pa2.size() - 1)
			chains[bi]["loop"] = true
	return chains


# Greedy overlap removal: chains sorted by descending length; a chain is
# dropped when >= 80% of its sampled points hug (<= 14px) the chains
# already kept. Kills duplicate skeleton lines of ANY size.
func _cv_drop_overlaps(chains: Array, hug: float) -> Array:
	var order = []
	for i in range(chains.size()):
		var pts = chains[i]["pts"]
		var ln = 0.0
		for k in range(pts.size() - 1):
			ln += pts[k].distance_to(pts[k + 1])
		order.append([ln, i])
	order.sort()
	order.invert()
	var kept = []
	for o in order:
		var ch = chains[int(o[1])]
		var samples = _cv_chain_samples(ch)
		var near_n = 0
		for sp in samples:
			var near = false
			for kc in kept:
				if near:
					break
				var pj = kc["pts"]
				var nseg = pj.size() - 1
				if bool(kc["loop"]):
					nseg = pj.size()
				for k in range(nseg):
					var q = Geometry.get_closest_point_to_segment_2d(sp, pj[k], pj[(k + 1) % pj.size()])
					if q.distance_to(sp) <= hug:
						near = true
						break
			if near:
				near_n += 1
		var ln2 = float(o[0])
		var short_touch = ln2 < 24.0 / _tex_scale and not bool(ch["loop"]) \
			and samples.size() > 0 and float(near_n) / float(samples.size()) >= 0.6
		if not short_touch and (samples.size() == 0 or float(near_n) / float(samples.size()) < 0.8):
			kept.append(ch)
	return kept


# Polyline sample points: vertices plus 40px subdivisions of long edges.
func _cv_chain_samples(ch: Dictionary) -> Array:
	var pts = ch["pts"]
	var out = []
	var nseg = pts.size() - 1
	if bool(ch["loop"]):
		nseg = pts.size()
	for k in range(nseg):
		var a = pts[k]
		var b = pts[(k + 1) % pts.size()]
		out.append(a)
		var d = a.distance_to(b)
		var nsub = int(d / 40.0)
		for m in range(1, nsub + 1):
			out.append(a.linear_interpolate(b, float(m) / float(nsub + 1)))
	if not bool(ch["loop"]):
		out.append(pts[pts.size() - 1])
	return out


func _find_node_named(node, part: String):
	if String(node.name).find(part) >= 0:
		return node
	for c in node.get_children():
		var r = _find_node_named(c, part)
		if r != null:
			return r
	return null


func _find_itemlist_biggest(node, best):
	if node is ItemList and node.get_item_count() >= 1 \
			and (best == null or node.get_item_count() > best.get_item_count()):
		best = node
	for c in node.get_children():
		best = _find_itemlist_biggest(c, best)
	return best


func _find_itemlist(node):
	# Strict pass: a populated list whose first thumbnail is ready.
	var r = _find_itemlist_strict(node)
	if r != null:
		return r
	# Thumbnails are generated lazily: requiring icon(0) made the whole
	# wall library "unreachable" whenever the first one was not ready
	# (or a first item simply has no preview), and the conversion wizard
	# silently degraded to the direct conversion. Fall back to the
	# biggest populated ItemList instead.
	return _find_itemlist_biggest(node, null)


# The wall library specifically: try the tool panel (strict, biggest,
# then GridMenu regardless of contents), then scan the whole editor for
# an ItemList under a node whose name mentions walls. When everything
# fails, dump the panel subtree once so the log shows what is there.
# The Floor page mixes DD's two floor systems in one list: the Pattern
# tool's texture menu (skipping its leading Null entry) and the Floor
# tool's smart tileset list. Both tools are primed with a quickswitch
# first (their lists and modulates fill lazily, wall-list style).
# _cvw_floor_map records where each row comes from.
func _cvw_build_floor_source():
	Global.Editor.Toolset.Quickswitch("PatternShapeTool")
	var pt0 = Global.Editor.Tools.get("PatternShapeTool")
	if pt0 != null:
		# Quickswitch can defer Enable() to the next frame; the default
		# patterns' colors (brown colorables, tinted tiles) are set by
		# Enable's modulate pass, and reading the menu before it leaves
		# them white. Calling it directly while the tool is current is
		# exactly what DD itself does.
		pt0.call("Enable")
	Global.Editor.Toolset.Quickswitch("FloorShapeTool")
	var ft0 = Global.Editor.Tools.get("FloorShapeTool")
	if ft0 != null:
		ft0.call("Enable")
	Global.Editor.Toolset.Quickswitch(TOOL_ID)
	_cvw_floor_map = []
	var out = ItemList.new()
	out.same_column_width = true
	out.max_columns = 0
	out.icon_mode = ItemList.ICON_MODE_TOP
	out.fixed_icon_size = Vector2(48, 48)
	var pat_tool = Global.Editor.Tools.get("PatternShapeTool")
	if pat_tool != null:
		var ctl = pat_tool.get("Controls")
		if ctl != null and ctl.has("Texture"):
			var gm = ctl["Texture"]
			# Index 0 is the Null icon injected by PostInit: skipped.
			for i in range(1, gm.get_item_count()):
				out.add_item("", gm.get_item_icon(i))
				var ni = out.get_item_count() - 1
				out.set_item_icon_modulate(ni, gm.get_item_icon_modulate(i))
				out.set_item_tooltip(ni, "Pattern: " + String(gm.get_item_tooltip(i)))
				_cvw_floor_map.append(["pat", i])
	var flo_tool = Global.Editor.Tools.get("FloorShapeTool")
	if flo_tool != null:
		var ctl2 = flo_tool.get("Controls")
		if ctl2 != null and ctl2.has("SmartTileId"):
			var tl = ctl2["SmartTileId"]
			for i in range(tl.get_item_count()):
				out.add_item("", tl.get_item_icon(i))
				var ni2 = out.get_item_count() - 1
				out.set_item_icon_modulate(ni2, tl.get_item_icon_modulate(i))
				var tip = String(tl.get_item_tooltip(i))
				if tip == "":
					tip = String(tl.get_item_text(i))
				out.set_item_tooltip(ni2, "Tiles: " + tip)
				_cvw_floor_map.append(["tile", i])
	if out.get_item_count() == 0:
		printerr("[SketchConv] no floor sources found (pattern/floor tools empty)")
		return null
	return out


func _cvw_find_wall_list():
	# The Unofficial Patch's LibraryRightPanel reparents the library
	# GridMenus out of the tool panels: crawling the panel finds nothing.
	# Resolve through Tools[tool].Controls["Texture"] instead - the same
	# registry the Patch itself uses to move them, valid wherever the
	# node currently lives.
	var src = _cvw_tool_library("WallTool")
	if src != null:
		return src
	var panel = Global.Editor.Toolset.GetToolPanel("WallTool")
	if panel != null:
		src = _find_gridmenu(panel)
		if src == null:
			src = _find_itemlist(panel)
	if src == null and not _cvw_dump_done:
		_cvw_dump_done = true
		_cvw_dump_libraries()
	return src


# The library GridMenu registered by Toolset.Init for a tool, fetched
# from the tool's Controls dictionary: survives any reparenting.
func _cvw_tool_library(tool_key: String):
	var tools = Global.Editor.get("Tools")
	if not tools is Dictionary:
		return null
	var t = tools.get(tool_key)
	if t == null or not is_instance_valid(t):
		return null
	var controls = t.get("Controls")
	if not controls is Dictionary:
		return null
	var ctrl = controls.get("Texture")
	if ctrl != null and is_instance_valid(ctrl) and ctrl is ItemList:
		return ctrl
	return null


# Read-only census of every ItemList in the editor: path, class, item
# count, GridMenu or not. No duplication, no C# property reads - safe.
func _cvw_dump_libraries() -> void:
	printerr("[SketchConv] wall list not found, ItemList census:")
	_cvw_census(Global.Editor.get_tree().get_root(), "")


func _cvw_census(node, path: String) -> void:
	var p = path + "/" + String(node.name)
	if node is ItemList:
		var tag = "ItemList"
		if node.has_method("ShowSet"):
			tag = "GridMenu"
		printerr("[SketchConv]   ", p, " [", tag, "] items=", node.get_item_count())
	for c in node.get_children():
		_cvw_census(c, p)


func _cvw_dump_tree(node, depth: int) -> void:
	if depth > 4:
		return
	var line = ""
	for _i in range(depth):
		line += "  "
	line += String(node.name) + " (" + node.get_class() + ")"
	if node is ItemList:
		line += " items=" + str(node.get_item_count())
	printerr("[SketchConv] ", line)
	for c in node.get_children():
		_cvw_dump_tree(c, depth + 1)


func _find_itemlist_strict(node):
	if node is ItemList and node.get_item_count() > 0 and node.get_item_icon(0) != null:
		return node
	for c in node.get_children():
		var r = _find_itemlist_strict(c)
		if r != null:
			return r
	return null


func _cv_key(p: Vector2) -> String:
	return str(int(round(p.x * 2.0))) + "_" + str(int(round(p.y * 2.0)))


func _on_plan_convert() -> void:
	_cv_area = null
	_plan_convert_to_dd()


func _plan_wipe_before_regen() -> void:
	if _last_plan_undo == null or not _nodes_ok():
		return
	_ops.append({"type": "stamp", "image": _last_plan_undo["pre"], "tex_rect": _last_plan_undo["rect"]})
	var skr = _active_sketch()
	if skr.has("labels"):
		var keep = int(_last_plan_undo.get("labels_n", 0))
		while skr["labels"].size() > keep:
			skr["labels"].pop_back()
		_write_map_data()
		_update_labels_overlay()


# Regenerates the last area with the SAME seed and current settings: used
# by the Doors & Windows and Exterior Walls Only toggles for immediate
# visual feedback.
func _plan_regen_same() -> void:
	if _stroke != null or _plan_pending != null or _plan_render != null:
		return
	if _last_plan_area == null:
		return
	var keep_e = _plan_lock_ext
	var keep_i = _plan_lock_int
	var flags = _plan_rand_flags.duplicate()
	_plan_lock_ext = true
	_plan_lock_int = true
	for k in _plan_rand_flags:
		_plan_rand_flags[k] = false
	if _last_plan_undo != null and bool(_last_plan_undo.get("clear", false)):
		_on_plan_whole_map()
	else:
		_plan_wipe_before_regen()
		_generate_plan(_last_plan_area)
	_plan_lock_ext = keep_e
	_plan_lock_int = keep_i
	_plan_rand_flags = flags


func _on_plan_seed_lock(which: String) -> void:
	if which == "ext":
		_plan_lock_ext = not _plan_lock_ext
	else:
		_plan_lock_int = not _plan_lock_int
	_plan_update_lock_icons()


func _plan_update_lock_icons() -> void:
	for pair in [[_lock_btn_ext, _plan_lock_ext, _rr_btn_ext],
			[_lock_btn_int, _plan_lock_int, _rr_btn_int]]:
		var btn = pair[0]
		if btn == null or not is_instance_valid(btn):
			continue
		var locked = bool(pair[1])
		var ic = _make_small_icon(_load_icon("lock" if locked else "unlock"), 18)
		if ic != null:
			btn.icon = ic
			btn.text = ""
		else:
			btn.icon = null
			btn.text = "L" if locked else "U"
		# Locked reads blue; its reroll is pointless, grey it out.
		btn.self_modulate = Color(0.45, 0.7, 1.0) if locked else Color(1, 1, 1)
		var rr = pair[2]
		if rr != null and is_instance_valid(rr):
			rr.disabled = locked


func _on_plan_seed_reroll(which: String) -> void:
	# Reroll ONE seed: the targeted field gets a fresh value, the other
	# keeps its current one (locked or not), then the last generation is
	# redone. Locking External and rerolling Internal = next floor of
	# the same building.
	if _stroke != null or _plan_pending != null or _plan_render != null:
		return
	if (which == "ext" and _plan_lock_ext) or (which == "int" and _plan_lock_int):
		return
	var tgt = _seed_edit_ext if which == "ext" else _seed_edit_int
	if tgt != null and is_instance_valid(tgt):
		tgt.text = str(_plan_ui_rng().randi() % 100000000)
	var le = _plan_lock_ext
	var li = _plan_lock_int
	_plan_lock_ext = true
	_plan_lock_int = true
	if _last_plan_undo != null and bool(_last_plan_undo.get("clear", false)):
		_on_plan_whole_map()
	elif _last_plan_area != null:
		_plan_wipe_before_regen()
		_generate_plan(_last_plan_area)
	else:
		_on_plan_whole_map()
	_plan_lock_ext = le
	_plan_lock_int = li


func _plan_seed_one(edit, locked: bool) -> int:
	var seed_v = _plan_ui_rng().randi() % 100000000
	if locked and edit != null and is_instance_valid(edit) \
			and edit.text.strip_edges().is_valid_integer():
		seed_v = int(edit.text.strip_edges())
	if edit != null and is_instance_valid(edit):
		edit.text = str(seed_v)
	return seed_v


func _plan_seed() -> int:
	# Both seeds resolved together; the return value keeps feeding the
	# legacy single-seed call sites (debug print, shuffle seeding).
	_plan_cur_seed_ext = _plan_seed_one(_seed_edit_ext, _plan_lock_ext)
	_plan_cur_seed_int = _plan_seed_one(_seed_edit_int, _plan_lock_int)
	return _plan_cur_seed_ext


func _generate_plan(area_world: Rect2, clear_all: bool = false) -> void:
	# Queued ops are fine (the render pipeline waits for an idle queue before
	# reading back the pre image): only a live stroke/plan blocks.
	if _stroke != null or _plan_pending != null or _plan_render != null or not _nodes_ok():
		return
	_sel_cancel()
	_plan_apply_rand_flags()
	# Snap the area to whole cells, clamped to the map.
	var cx = int(round(area_world.position.x / CELL))
	var cy = int(round(area_world.position.y / CELL))
	var cw = int(round(area_world.size.x / CELL))
	var ch = int(round(area_world.size.y / CELL))
	var wox = Global.World.WoxelDimensions
	cx = int(clamp(cx, 0, int(wox.x / CELL) - 1))
	cy = int(clamp(cy, 0, int(wox.y / CELL) - 1))
	cw = int(clamp(cw, 2, int(wox.x / CELL) - cx))
	ch = int(clamp(ch, 2, int(wox.y / CELL) - cy))
	if cw < 2 or ch < 2:
		_dbg("plan: area too small after clamping")
		return
	_last_plan_area = Rect2(cx * CELL, cy * CELL, cw * CELL, ch * CELL)
	var seed_v = _plan_seed()
	var rng = RandomNumberGenerator.new()
	rng.seed = seed_v
	# Array.shuffle() uses the global RNG: seed it too for reproducibility.
	seed(seed_v)
	var t0 = OS.get_ticks_msec()
	var payload = _plan_build(rng, cx, cy, cw, ch)
	_dbg("plan: " + str(payload["segs"].size()) + " segs, " + str(payload["wins"].size())
		+ " windows, " + str(payload["doors"].size()) + " doors, " + str(payload["arcs"].size())
		+ " towers, " + str(payload["labels"].size()) + " labels in "
		+ str(OS.get_ticks_msec() - t0) + " ms (ext " + str(_plan_cur_seed_ext)
		+ " / int " + str(_plan_cur_seed_int) + ")")
	# Force the sketch visible, like drawing does.
	if not bool(_map_data["visible"]):
		_map_data["visible"] = true
		_apply_display()
		_sync_display_controls()
		_write_map_data()
	var margin = _width + CELL * 3.0
	var world_rect = Rect2(_last_plan_area.position - Vector2(margin, margin),
		_last_plan_area.size + Vector2(margin, margin) * 2.0)
	var tex_rect = _clamp_rect_tex(Rect2(world_rect.position * _tex_scale, world_rect.size * _tex_scale))
	if clear_all:
		# The undo record must cover the wiped content too.
		tex_rect = Rect2(Vector2(), _tex_size)
	_plan_pending = {"payload": payload, "rect_tex": tex_rect, "clear": clear_all}
	_last_plan_payload = payload


func _after_plan(rect: Rect2) -> void:
	_plan_render = null
	var post = _readback_a()
	var sk = _active_sketch()
	if not sk.has("labels"):
		sk["labels"] = []
	var labels_before = sk["labels"].duplicate(true)
	if _plan_was_clear:
		sk["labels"] = []
	var labels_n = sk["labels"].size()
	for lb in _plan_pend_labels:
		if _rl_col != "":
			lb["col"] = _rl_col
		if _rl_s > 0.0:
			lb["s"] = _rl_s
		sk["labels"].append(lb)
	_plan_pend_labels = []
	_write_map_data()
	_update_labels_overlay()
	var undo_entry = null
	if post != null and _pre_image != null:
		var pre_crop = _pre_image.get_rect(rect)
		_push_history(int(_active_sketch()["uid"]), rect, pre_crop, post.get_rect(rect),
			null, [labels_before, sk["labels"].duplicate(true)])
		undo_entry = {"rect": rect, "pre": pre_crop, "labels_n": labels_n, "clear": _plan_was_clear}
	_pre_image = null
	_mark_dirty()
	# Set AFTER _mark_dirty (which clears it).
	_last_plan_undo = undo_entry


func _draw_plan(item) -> void:
	var pl = _plan_render
	if pl == null:
		return
	if pl.has("img"):
		if not pl.has("_tex_cache"):
			var t = ImageTexture.new()
			t.create_from_image(pl["img"], 0)
			pl["_tex_cache"] = t
		var base = pl["img_base"]
		var c = pl["img_center"] * _tex_scale
		item.draw_set_transform(c, float(pl.get("img_rot", 0.0)), Vector2(1, 1))
		item.draw_texture_rect(pl["_tex_cache"],
			Rect2(-base * 0.5 * _tex_scale, base * _tex_scale), false)
		item.draw_set_transform(Vector2(), 0.0, Vector2(1, 1))
		return
	var w = max(1.0, float(pl["w"]) * _tex_scale)
	var col = pl["color"]
	# Endpoint sharing across all three lists: a FREE end gets a square
	# cap (butt edge flush at the true endpoint, done by extending the
	# line half a width); a SHARED joint is left unextended (uniform
	# extension made rotated generator segments overshoot their
	# corners) and patched with a small axis-aligned square instead.
	var use = {}
	for lst in [pl["segs"], pl["wins"], pl["doors"]]:
		for seg in lst:
			for pi in range(2):
				var k = str(seg[pi])
				use[k] = int(use.get(k, 0)) + 1
	var patched = {}
	# Pass 1 - the wall network, drawn CONTINUOUS through the openings:
	# door and window spans get the wall color at full width first, the
	# portal stroke then sits on top at half width (same convention as
	# the segment tool - the converter runs the wall through portals).
	for lst1 in [pl["segs"], pl["wins"], pl["doors"]]:
		for seg in lst1:
			var dv = (seg[1] - seg[0]).normalized() * w * 0.5 / _tex_scale
			var a2 = seg[0]
			var b2 = seg[1]
			if int(use.get(str(seg[0]), 0)) == 1:
				a2 = seg[0] - dv
			if int(use.get(str(seg[1]), 0)) == 1:
				b2 = seg[1] + dv
			item.draw_line(a2 * _tex_scale, b2 * _tex_scale, col, w, false)
			for pi2 in range(2):
				var k2 = str(seg[pi2])
				if int(use.get(k2, 0)) > 1 and not patched.has(k2):
					patched[k2] = true
					var c2 = seg[pi2] * _tex_scale
					item.draw_rect(Rect2(c2 - Vector2(w, w) * 0.5, Vector2(w, w)), col, true)
	# Pass 2 - the portals on top at half width, no end extensions
	# (openings sit inside their wall run). Joints shared between two
	# portal segments get a portal-colored patch so one opening never
	# reads as two.
	var pw = max(1.0, w * 0.5)
	var use_p = {}
	for lstp in [pl["wins"], pl["doors"]]:
		for seg in lstp:
			for pi in range(2):
				var kp = str(seg[pi])
				use_p[kp] = int(use_p.get(kp, 0)) + 1
	var patched_p = {}
	for li in range(1, 3):
		var lst2 = [pl["segs"], pl["wins"], pl["doors"]][li]
		var lcol = [col, WINDOW_COLOR, DOOR_COLOR][li]
		for seg in lst2:
			item.draw_line(seg[0] * _tex_scale, seg[1] * _tex_scale, lcol, pw, false)
			for pi3 in range(2):
				var k3 = str(seg[pi3])
				if int(use_p.get(k3, 0)) > 1 and not patched_p.has(k3):
					patched_p[k3] = true
					var c3 = seg[pi3] * _tex_scale
					item.draw_rect(Rect2(c3 - Vector2(pw, pw) * 0.5, Vector2(pw, pw)), lcol, true)
	for a in pl["arcs"]:
		item.draw_arc(a["c"] * _tex_scale, a["r"] * _tex_scale, float(a["a0"]), float(a["a1"]), 64, col, w, false)



# ── Generation core (cell coordinates, origin at the area's top-left) ──────

func _plan_build(rng, acx: int, acy: int, cw: int, ch: int) -> Dictionary:
	var cand = _plan_build_one(int(rng.randi()), acx, acy, cw, ch)
	if cand == null:
		return {"segs": [], "wins": [], "doors": [], "arcs": [], "labels": [], "color": Color(0, 0, 0, 1), "w": 32.0}
	_dbg("plan: score " + str(cand["score"]))
	return cand["payload"]


func _plan_sround(rng, x: float) -> int:
	# Stochastic rounding: integer part plus fractional probability, for a
	# progressive slider response (hard round() made visible steps).
	var base = int(floor(x))
	if rng.randf() < x - float(base):
		base += 1
	return base


func _plan_restore_tuning(t: Array) -> void:
	_plan_min = int(t[0])
	_plan_max = int(t[1])
	_plan_complexity = float(t[2])
	_plan_corr = float(t[3])
	_plan_orig = float(t[4])
	_plan_room_irr = float(t[5])
	_plan_tower_count = int(t[6])


func _plan_stream(seed_i: int, salt: int):
	var r = RandomNumberGenerator.new()
	r.seed = seed_i + salt
	return r


func _plan_shuffle(rng, arr: Array) -> void:
	# Fisher-Yates on a dedicated stream (Array.shuffle() uses the global
	# RNG, which would couple the stages together).
	for i in range(arr.size() - 1, 0, -1):
		var j = rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


func _plan_build_one(seed_i: int, acx: int, acy: int, cw: int, ch: int):
	# "Random" archetype: resolved HERE, on the Shape stream (a locked
	# Shape Seed keeps the same pick across floors), presets applied for
	# this build only - the dropdown stays on Random.
	var arch_saved = _plan_archetype
	var tune_saved = [_plan_min, _plan_max, _plan_complexity, _plan_corr,
		_plan_orig, _plan_room_irr, _plan_tower_count]
	if String(_plan_archetype.get("id", "")) == "random":
		var r_pickA = _plan_stream(_plan_cur_seed_ext, 47)
		var cands_a = []
		for ai in range(PLAN_ARCHETYPES.size()):
			var da = PLAN_ARCHETYPES[ai]
			if bool(da.get("hidden", false)):
				continue
			if String(da.get("id", "")) == "random":
				continue
			cands_a.append(da)
		_plan_archetype = cands_a[r_pickA.randi_range(0, cands_a.size() - 1)]
		var sl_a = _plan_archetype.get("sliders", null)
		if sl_a != null:
			_plan_min = int(sl_a.get("min", _plan_min))
			_plan_max = int(sl_a.get("max", _plan_max))
			_plan_complexity = float(sl_a.get("cpx", _plan_complexity))
			_plan_corr = float(sl_a.get("corr", _plan_corr))
			_plan_orig = float(sl_a.get("orig", _plan_orig))
			_plan_room_irr = float(sl_a.get("irr", _plan_room_irr))
			_plan_tower_count = int(sl_a.get("towers", _plan_tower_count))
	# The silhouette only consumes r_env, so with a fixed seed only Building
	# Shape Oddity can change it.
	# Silhouette stream: EXTERNAL seed - envelope, apse, bumps, annexes.
	var r_env = _plan_stream(_plan_cur_seed_ext, 101)
	# 1. Envelope (shape grammar driven by Building Shape Oddity).
	var mask = _plan_zeroed_ints(cw * ch)
	_plan_draw_silhouette(r_env, mask, cw, ch)
	if bool(_plan_archetype.get("massing", false)) and int(min(cw, ch)) >= 12:
		# MASSING GATE: one silhouette roll in ~4 has good bones, so the
		# gate rolls a few salted candidates and keeps the best-massed
		# one (compact fill of its bounding box + x-symmetry) -
		# deterministic per Shape Seed. The winning candidate is redrawn
		# so every silhouette member (symx flag, oriel corners, last
		# shape...) belongs to the kept mask.
		var best_ms = _plan_massing_score(mask, cw, ch)
		var best_salt = -1
		for mk in range(3):
			var m2 = _plan_zeroed_ints(cw * ch)
			var r2 = _plan_stream(_plan_cur_seed_ext, 10101 + mk * 97)
			_plan_draw_silhouette(r2, m2, cw, ch)
			var sc_ms = _plan_massing_score(m2, cw, ch)
			if sc_ms > best_ms + 0.02:
				best_ms = sc_ms
				best_salt = mk
		if best_salt >= 0:
			mask = _plan_zeroed_ints(cw * ch)
			var r3 = _plan_stream(_plan_cur_seed_ext, 10101 + best_salt * 97)
			_plan_draw_silhouette(r3, mask, cw, ch)
	var area_cells = 0
	for i in range(cw * ch):
		if mask[i] == 1:
			area_cells += 1
	if area_cells < 4:
		_plan_archetype = arch_saved
		_plan_restore_tuning(tune_saved)
		return null

	var room_min = int(min(_plan_min, _plan_max - 1))
	var room_max = int(max(_plan_max, room_min + 1))
	var bsp_min = int(max(room_min, 2))
	# Room Density shrinks the effective max leaf size: high density packs
	# more, smaller rooms; low density lets rooms reach Room Max.
	var eff_max = int(clamp(int(round(lerp(float(room_max), float(max(bsp_min + 1, room_max / 2)), _plan_complexity))), bsp_min + 1, room_max))

	# Interior variants over the SAME envelope: the architectural score
	# picks the best interior while the silhouette stays seed+shape-only.
	var best = null
	var n_var = 3
	if not _plan_archetype.empty():
		# Archetype scoring is selective intelligence: give it a real
		# population to choose from.
		n_var = 8
	for vi in range(n_var):
		var res = _plan_build_interior(_plan_cur_seed_int + 131071 * (vi + 1), mask, acx, acy, cw, ch,
			area_cells, room_min, room_max, bsp_min, eff_max)
		if res == null:
			continue
		if best == null or float(res["score"]) > float(best["score"]):
			best = res
	if best == null:
		_plan_archetype = arch_saved
		_plan_restore_tuning(tune_saved)
		return null
	# Towers AFTER variant selection, on a base-seed stream: the slider can
	# never reshuffle the interior, it only adds or removes towers.
	_plan_cur_towers = []
	# The emission clip must use the CHOSEN variant's bevel triangles,
	# not whatever the last loop iteration left in the member.
	_plan_bevel_tris = best.get("bevel_tris", [])
	var r_tow = _plan_stream(_plan_cur_seed_ext, 809)
	_plan_towers_pass(r_tow, mask, best["runs"], cw, ch, acx, acy,
		best["extra_segs"], best["arcs"], best["rooms"], best["cats"])
	best["payload"] = _plan_emit(best, acx, acy, cw, ch)
	_plan_archetype = arch_saved
	_plan_restore_tuning(tune_saved)
	return best


func _plan_emit(best: Dictionary, acx: int, acy: int, cw: int = 0, ch: int = 0) -> Dictionary:
	# Exterior Walls Only and Doors & Windows only act HERE: the geometry
	# pipeline above is strictly identical whatever the toggles.
	var runs = best["runs"]
	var emit_cats = best.get("cats", {})
	var extra_segs = best["extra_segs"]
	var extra_int = best["extra_int"]
	var arcs = best["arcs"]
	var labels = best["labels"]
	if not _plan_ext_only:
		for sgi in extra_int:
			extra_segs.append(sgi)
	if not _plan_openings:
		# Solid walls: strip door/open/window holes, keep the cuts.
		for run in runs:
			var kept_h = []
			for h in run["holes"]:
				if String(h[2]) == "cut":
					kept_h.append(h)
			run["holes"] = kept_h
	elif bool(_plan_archetype.get("no_windows", false)):
		# Underground archetypes: windows make no sense, doors stay.
		for run in runs:
			var kept_w = []
			for h in run["holes"]:
				if String(h[2]) != "window":
					kept_w.append(h)
			run["holes"] = kept_w
	for run in runs:
		var has_cut = false
		for h in run["holes"]:
			if String(h[2]) == "cut":
				has_cut = true
				break
		if not has_cut:
			continue
		var cleaned = []
		for h in run["holes"]:
			var ht0 = String(h[2])
			if ht0 == "door" or ht0 == "window" or ht0 == "open":
				var near_cut = false
				for hc in run["holes"]:
					if String(hc[2]) != "cut":
						continue
					if float(h[0]) < float(hc[0]) + float(hc[1]) + 0.1 \
							and float(hc[0]) < float(h[0]) + float(h[1]) + 0.1:
						near_cut = true
						break
				if near_cut:
					continue
			cleaned.append(h)
		run["holes"] = cleaned
	var round_env = bool(_plan_archetype.get("round_env", false)) and _plan_env_circle != null
	if bool(_plan_archetype.get("no_ext_doors", false)):
		# Underground level: NO opening to the outside at all - access
		# is by stairs from the level above.
		for run0 in runs:
			if String(run0["kind"]) != "ext":
				continue
			var kc0 = []
			for h0 in run0["holes"]:
				if String(h0[2]) == "cut":
					kc0.append(h0)
			run0["holes"] = kc0
	elif bool(_plan_archetype.get("single_entrance", false)):
		# One exterior door only: the SOUTHERNMOST door survives (the
		# ceremonial facade entrance), every other exterior door or gap
		# becomes solid wall. Windows stay. In a bailey, walls facing
		# the COURTYARD are exempt: the court is the circulation, every
		# ring room keeps its court door.
		var best_run0 = null
		var best_y0 = -1
		for run1 in runs:
			if String(run1["kind"]) != "ext":
				continue
			if _plan_run_faces_court(run1):
				continue
			if String(emit_cats.get(int(max(int(run1["a"]), int(run1["b"]))), "")) == "gatehouse":
				continue
			for h1 in run1["holes"]:
				var ht1 = String(h1[2])
				if ht1 == "door" or ht1 == "open":
					var ry1 = int(run1["y"]) if not bool(run1["vert"]) else int(run1.get("y1", run1["y0"]))
					if ry1 > best_y0:
						best_y0 = ry1
						best_run0 = run1
		for run2b in runs:
			if String(run2b["kind"]) != "ext":
				continue
			if _plan_run_faces_court(run2b):
				continue
			if String(emit_cats.get(int(max(int(run2b["a"]), int(run2b["b"]))), "")) == "gatehouse":
				# The gatehouse IS the single entrance: its open passage
				# is sacred, the strip pass never walls it up.
				continue
			var kc2 = []
			for h2b in run2b["holes"]:
				var ht2b = String(h2b[2])
				if (ht2b == "door" or ht2b == "open") and run2b != best_run0:
					continue
				kc2.append(h2b)
			run2b["holes"] = kc2
	var env_door = null
	# ENTRANCE GUARANTEE: a building always keeps at least one way in.
	# After every strip pass, if no exterior door or open gap survives
	# anywhere, one is punched dead-center on the longest exterior wall
	# (centered on a long run: the corner-door pass will never drop it).
	if not bool(_plan_archetype.get("no_ext_doors", false)):
		var any_ext = false
		var long_ext = null
		for run_ge in runs:
			if String(run_ge["kind"]) != "ext":
				continue
			if long_ext == null or _plan_run_len(run_ge) > _plan_run_len(long_ext):
				long_ext = run_ge
			if not any_ext:
				for h_ge in run_ge["holes"]:
					var ht_ge = String(h_ge[2])
					if ht_ge == "door" or ht_ge == "open":
						any_ext = true
						break
		if not any_ext and long_ext != null:
			var ll = _plan_run_len(long_ext)
			var pge = stepify(float(ll - 1) * 0.5, 0.5)
			if not _plan_try_hole(long_ext, pge, 1, "door"):
				var kge = []
				for h2g in long_ext["holes"]:
					if String(h2g[2]) == "window" and float(h2g[0]) < pge + 2.0 \
							and float(h2g[0]) + float(h2g[1]) > pge - 1.0:
						continue
					kge.append(h2g)
				long_ext["holes"] = kge
				if not _plan_try_hole(long_ext, pge, 1, "door"):
					_plan_force_hole(long_ext, pge, 1.0)
					var fge = long_ext["holes"][long_ext["holes"].size() - 1]
					fge[2] = "door"
	var segs = extra_segs
	var wins = []
	var doors = []
	for run in runs:
		if _plan_ext_only and String(run["kind"]) == "int":
			continue
		if String(run["kind"]) == "ext":
			# An exterior wall never gets a bare gap: an "open" hole there
			# (the connection wave uses them for entrances) becomes a real
			# door instead of a hole to the outside. Exception: the castle
			# gatehouse passage IS a bare gap by design (portcullis bay).
			var inner_c = int(max(int(run["a"]), int(run["b"])))
			if not (_plan_bailey != null and String(emit_cats.get(inner_c, "")) == "gatehouse"):
				for hop in run["holes"]:
					if String(hop[2]) == "open":
						hop[2] = "door"
		if round_env and String(run["kind"]) == "ext":
			# The stair-stepped disc boundary is replaced by one true
			# circle arc below - but the door the generator placed on it
			# survives as the entrance gap of that circle.
			if env_door == null:
				for hole0 in run["holes"]:
					if String(hole0[2]) == "door":
						var dsg = _plan_run_seg(run, hole0[0], hole0[0] + hole0[1], acx, acy)
						env_door = (dsg[0] + dsg[1]) * 0.5
						break
			continue
		var kept = _plan_run_intervals_ex(run)
		for iv in kept:
			if iv[1] - iv[0] < 0.45:
				continue
			segs.append(_plan_run_seg(run, iv[0], iv[1], acx, acy))
		for hole in run["holes"]:
			var ht = String(hole[2])
			if ht == "window":
				wins.append(_plan_run_seg(run, hole[0], hole[0] + hole[1], acx, acy))
			elif ht == "door":
				doors.append(_plan_run_seg(run, hole[0], hole[0] + hole[1], acx, acy))
	var env_arc = null
	if round_env:
		var ccw = Vector2((float(acx) + float(_plan_env_circle[0])) * CELL,
			(float(acy) + float(_plan_env_circle[1])) * CELL)
		var crw = float(_plan_env_circle[2]) * CELL
		# Built but appended AFTER the clip passes: clip_segs_to_arcs
		# deletes any diagonal fully inside an arc (nothing-inside-a-tower
		# rule), which would wipe every interior diagonal here.
		env_arc = {"c": ccw, "r": crw, "a0": 0.0, "a1": PI * 2.0}
		if env_door != null:
			# Entrance: the circle opens over one cell width around the
			# angle where the generator's exterior door used to sit.
			var da = (env_door - ccw).angle()
			var half_gap = min(0.6, (CELL * 0.6) / max(crw, 1.0))
			env_arc["a0"] = da + half_gap
			env_arc["a1"] = da - half_gap + PI * 2.0
		# Interior walls used to stop on the stair-stepped mask boundary:
		# stretch any end sitting near the circle onto the circle itself.
		for sgi2 in range(segs.size()):
			var sg2 = segs[sgi2]
			var u = (sg2[1] - sg2[0])
			if u.length() < 1.0:
				continue
			u = u.normalized()
			for endi in range(2):
				var pe = sg2[endi]
				var de = pe.distance_to(ccw)
				if de > crw - CELL * 1.6 and de < crw - 4.0:
					var dirn = u if endi == 1 else -u
					# |pe + dirn * t - c| = crw, smallest positive t.
					var fo = pe - ccw
					var qb2 = 2.0 * fo.dot(dirn)
					var qc2 = fo.dot(fo) - crw * crw
					var disc2 = qb2 * qb2 - 4.0 * qc2
					if disc2 <= 0.0:
						continue
					var tt = (-qb2 + sqrt(disc2)) * 0.5
					if tt > 0.0 and tt < CELL * 2.0:
						sg2[endi] = pe + dirn * tt
	# Diagonals must never cross a tower: clip them at the circles; then any
	# diagonal left hanging in the air is pruned.
	segs = _plan_clip_seg_tris(segs, acx, acy)
	segs = _plan_clip_segs_to_arcs(segs, arcs)
	segs = _plan_prune_diagonals(segs, arcs, wins, doors)
	if env_arc != null:
		arcs.append(env_arc)
	if _plan_proc_apse != null:
		# Rounded apse: the straight northernmost wall of the chevet is
		# replaced by a half-circle bulging north. The wall runs were
		# collected already, so the segment(s) spanning the chord are
		# dropped here and the arc takes their place. Canvas angles are
		# y-down: the north half-circle is PI..2*PI.
		var apx = (float(acx) + float(_plan_proc_apse[0])) * CELL
		var apy = (float(acy) + float(_plan_proc_apse[1])) * CELL
		var apr = float(_plan_proc_apse[2]) * CELL
		# Openings punched into that wall would float on the chord: they
		# go with it.
		var apse_lists = [segs, wins, doors]
		for li4 in range(apse_lists.size()):
			var kept4 = []
			for sg3 in apse_lists[li4]:
				var p0 = sg3[0]
				var p1 = sg3[1]
				var horiz3 = abs(p0.y - p1.y) < 1.0
				var on_chord = horiz3 and abs(p0.y - apy) < CELL * 0.25 \
						and min(p0.x, p1.x) > apx - apr - CELL * 0.25 \
						and max(p0.x, p1.x) < apx + apr + CELL * 0.25
				if not on_chord:
					kept4.append(sg3)
			apse_lists[li4] = kept4
		segs = apse_lists[0]
		wins = apse_lists[1]
		doors = apse_lists[2]
		arcs.append({"c": Vector2(apx, apy), "r": apr, "a0": PI, "a1": PI * 2.0})
	# Corner-door rule (AFTER the rooms are decided): a door touching a
	# corner slides half a cell away from it when the wall allows;
	# stuck doors become plain wall gaps instead.
	var cfix = _plan_fix_corner_doors(segs, doors, arcs)
	segs = cfix[0]
	doors = cfix[1]
	var dbg_drop = cfix[2]
	var dbg_shift = cfix[3]
	# LAST geometry passes, once every arc / apse / bevel is final.
	# FIRST the bridge: the tower carve can leave the shell open next
	# to an arc (the wall's own line misses the circle, so the on-line
	# stretch fixup has nothing to extend to) - every loose wall end
	# links to its nearest wall end or arc point instead of gaping.
	# THEN the trim: whatever still floats after bridging is debris.
	_plan_bridge_gaps(segs, arcs, wins, doors)
	_plan_trim_stubs(segs, arcs, wins, doors)
	if not bool(_plan_archetype.get("no_ext_doors", false)) and cw > 0:
		# Every earlier guarantee ran on the RUN level, BEFORE the
		# tower carve, the apse, the corner-door pass and the stub
		# trim - any of which can eat the last EXTERIOR door (interior
		# doors surviving fooled the old emptiness check). Real test:
		# a door is exterior when exactly one of its sides lies
		# outside the room grid. None left: punch one mid-run into
		# the longest exterior wall.
		var rooms_g = best["rooms"]
		var has_ext = false
		for dr in doors:
			if _plan_seg_is_ext(dr, rooms_g, acx, acy, cw, ch):
				has_ext = true
				break
		if not has_ext:
			_plan_emergency_door(segs, doors, rooms_g, acx, acy, cw, ch)
	var payload = {"segs": segs, "wins": wins, "doors": doors, "arcs": arcs, "labels": labels, "color": Color(0, 0, 0, 1), "w": 32.0, "dbg_drop": dbg_drop, "dbg_shift": dbg_shift}
	return payload


# Prison-cell CARVING: before walls are built, every ordinary room
# leaning on a corridor is re-cut into 3x2 / 2x3 stalls against the
# corridor side (each stall a fresh room id); only the trimmings keep
# the old id. The comb proposes, this pass enforces: cells end up the
# overwhelming majority, the leftovers become the couple of stores.
func _plan_carve_cells(rooms: Array, cw: int, ch: int, circ_cat: Dictionary, protected: Dictionary) -> void:
	if not bool(_plan_archetype.get("cells_exact", false)):
		return
	var is_corr = {}
	for k in circ_cat:
		if _plan_cat_group(String(circ_cat[k])) == "corridor":
			is_corr[int(k)] = true
	if is_corr.empty():
		return
	var infos = _plan_room_infos(rooms, cw, ch)
	var next_id = 0
	for i in range(cw * ch):
		if rooms[i] > next_id:
			next_id = rooms[i]
	next_id += 1
	for r in infos.keys():
		var rid = int(r)
		if is_corr.has(rid) or protected.has(rid):
			continue
		var ir = infos[rid]
		var bw = int(ir["bw"])
		var bh = int(ir["bh"])
		if int(ir["cells"]) != bw * bh:
			continue
		if (bw == 3 and bh == 2) or (bw == 2 and bh == 3):
			continue
		var x0 = int(ir["x0"])
		var y0 = int(ir["y0"])
		# Which side leans on a corridor? Count boundary cells per side.
		var side_n = [0, 0, 0, 0]
		for x in range(x0, x0 + bw):
			if y0 > 0 and is_corr.has(rooms[(y0 - 1) * cw + x]):
				side_n[0] += 1
			if y0 + bh < ch and is_corr.has(rooms[(y0 + bh) * cw + x]):
				side_n[1] += 1
		for y in range(y0, y0 + bh):
			if x0 > 0 and is_corr.has(rooms[y * cw + x0 - 1]):
				side_n[2] += 1
			if x0 + bw < cw and is_corr.has(rooms[y * cw + x0 + bw]):
				side_n[3] += 1
		var side = -1
		var side_best = 0
		for si in range(4):
			if side_n[si] > side_best:
				side_best = side_n[si]
				side = si
		if side < 0:
			continue
		var horiz = side <= 1
		var along = bw if horiz else bh
		var depth_av = bh if horiz else bw
		# Stall depth toward the corridor: prefer 3-deep (2 wide), else
		# 2-deep (3 wide).
		var sd = 3 if depth_av >= 3 else 2
		var sw2 = 2 if sd == 3 else 3
		if depth_av < 2 or along < sw2:
			continue
		var n_st = int(along / sw2)
		if (horiz and n_st < 1) or n_st < 1:
			continue
		for st in range(n_st):
			var sx = x0
			var sy = y0
			if horiz:
				sx = x0 + st * sw2
				sy = y0 if side == 0 else y0 + bh - sd
			else:
				sy = y0 + st * sw2
				sx = x0 if side == 2 else x0 + bw - sd
			var wst = sw2 if horiz else sd
			var hst = sd if horiz else sw2
			for yy in range(sy, sy + hst):
				for xx in range(sx, sx + wst):
					rooms[yy * cw + xx] = next_id
			next_id += 1


# Prison-cell discipline. (1) Every CELL has exactly the same size:
# the majority (bw x bh) signature among the repeat rooms defines the
# cell; off-size ones are re-labeled as ordinary storage. (2) A cell
# opens on a CORRIDOR and nothing else: doors toward neighbors are
# wiped, one corridor door is guaranteed, and a cell with no corridor
# wall is no cell at all.
func _plan_prison_cells(runs: Array, rooms: Array, cw: int, ch: int, cats: Dictionary) -> void:
	if not bool(_plan_archetype.get("cells_exact", false)):
		return
	_plan_prison_leftover = 0
	# A prison cell is 3x2 or 2x3, FULL rectangle, and nothing else.
	var infos = _plan_room_infos(rooms, cw, ch)
	var cells_set = {}
	for r2 in cats.keys():
		if _plan_cat_group(String(cats[r2])) != "bedroom" or not infos.has(int(r2)):
			continue
		var ir2 = infos[int(r2)]
		var bw2 = int(ir2["bw"])
		var bh2 = int(ir2["bh"])
		var ok_cell = int(ir2["cells"]) == 6 \
			and ((bw2 == 3 and bh2 == 2) or (bw2 == 2 and bh2 == 3))
		if ok_cell:
			cells_set[int(r2)] = true
		else:
			# Rotate the leftovers through varied service labels: twenty
			# rooms of one kind reads absurd (the all-Armory prison).
			var pool_p = ["servants", "storage", "pantry", "closet", "laundry", "bathroom"]
			cats[int(r2)] = pool_p[_plan_prison_leftover % pool_p.size()]
			_plan_prison_leftover += 1
	# Doors: corridor side only.
	var corr_run = {}
	var has_corr_door = {}
	for run in runs:
		var a = int(run["a"])
		var b = int(run["b"])
		var ca = cells_set.has(a)
		var cb = cells_set.has(b)
		if not ca and not cb:
			continue
		var cell_id = a if ca else b
		var other = b if ca else a
		var other_corr = other >= 0 \
			and _plan_cat_group(String(cats.get(other, ""))) == "corridor"
		if String(run["kind"]) == "int" and other_corr:
			if not corr_run.has(cell_id) \
					or _plan_run_len(run) > _plan_run_len(corr_run[cell_id]):
				corr_run[cell_id] = run
			for h in run["holes"]:
				var ht = String(h[2])
				if ht == "door" or ht == "open":
					has_corr_door[cell_id] = true
		else:
			# Neighbor room, another cell, or the outside: no way through.
			var kept = []
			for h2 in run["holes"]:
				var ht2 = String(h2[2])
				if ht2 == "door" or ht2 == "open":
					continue
				kept.append(h2)
			run["holes"] = kept
	for cid in cells_set:
		if not corr_run.has(int(cid)):
			# No corridor wall: not a cell.
			cats[int(cid)] = "storage"
			continue
		if has_corr_door.has(int(cid)):
			continue
		var runc = corr_run[int(cid)]
		var lc = _plan_run_len(runc)
		if lc < 1:
			continue
		var pc = stepify(float(lc - 1) * 0.5, 0.5)
		if not _plan_try_hole(runc, pc, 1, "door"):
			_plan_force_hole(runc, pc, 1.0)
			var fc = runc["holes"][runc["holes"].size() - 1]
			fc[2] = "door"


# Carves one short transverse passage between each pair of circulation
# rooms (corridors/halls) separated by a 1-2 cell sliver of ordinary
# room: the sliver cells are handed to the first corridor. One stitch
# per pair, the thinnest spot wins.
func _plan_stitch_corridors(rooms: Array, cw: int, ch: int, circ_cat: Dictionary, protected: Dictionary) -> void:
	if not bool(_plan_archetype.get("open_circ", false)):
		return
	var is_circ = {}
	for k in circ_cat:
		var g = _plan_cat_group(String(circ_cat[k]))
		if g == "corridor" or g == "hall":
			is_circ[int(k)] = true
	if is_circ.size() < 2:
		return
	var best_by_pair = {}
	for vert in [true, false]:
		var d0 = cw if vert else 1
		var outer = cw if vert else ch
		var inner = ch if vert else cw
		for o in range(outer):
			for i2 in range(1, inner - 1):
				var idx = (i2 * cw + o) if vert else (o * cw + i2)
				var above = idx - d0
				var pa = rooms[above]
				if not is_circ.has(pa):
					continue
				var dep = 0
				var cells2 = []
				var pb = -1
				var j2 = idx
				while dep < 2:
					var pr = rooms[j2]
					if pr < 0 or is_circ.has(pr) or protected.has(pr):
						break
					cells2.append(j2)
					dep += 1
					j2 += d0
					if vert:
						if j2 >= cw * ch:
							break
					elif j2 % cw == 0:
						# Walked off the row's end.
						break
					if is_circ.has(rooms[j2]):
						pb = rooms[j2]
						break
				if pb < 0 or cells2.empty():
					continue
				var key = str(int(min(pa, pb))) + ":" + str(int(max(pa, pb)))
				if not best_by_pair.has(key) or cells2.size() < best_by_pair[key][1].size():
					best_by_pair[key] = [pa, cells2]
	for key2 in best_by_pair:
		var ent = best_by_pair[key2]
		for c3 in ent[1]:
			rooms[int(c3)] = int(ent[0])


# Any ordinary room whose removal DISCONNECTS the plan is a bridge: it
# gets re-labeled as a corridor (and open_circ then knocks its walls
# down) - two wings should be linked by an open hallway, not through
# somebody's bedroom.
func _plan_bridge_corridors(runs: Array, cats: Dictionary) -> void:
	if not bool(_plan_archetype.get("bridge_corridors", false)):
		return
	var adj = {}
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var a = int(run["a"])
		var b = int(run["b"])
		if a < 0 or b < 0:
			continue
		if not adj.has(a):
			adj[a] = {}
		adj[a][b] = true
		if not adj.has(b):
			adj[b] = {}
		adj[b][a] = true
	var to_corr = []
	for r in adj:
		var g = _plan_cat_group(String(cats.get(int(r), "")))
		if g == "hall" or g == "corridor" or g == "kitchen":
			continue
		if adj[r].size() < 2:
			continue
		# Flood the graph without r: unreached neighbors = articulation.
		var start = -1
		for nb in adj[r]:
			start = int(nb)
			break
		var seen = {int(r): true, start: true}
		var qq = [start]
		while not qq.empty():
			var cur = int(qq.pop_back())
			for nb2 in adj.get(cur, {}):
				if not seen.has(int(nb2)):
					seen[int(nb2)] = true
					qq.append(int(nb2))
		for nb3 in adj[r]:
			if not seen.has(int(nb3)):
				to_corr.append(int(r))
				break
	for r2 in to_corr:
		cats[int(r2)] = "corridor"


# Circulation flows OPEN: every wall between the hall and a corridor,
# or between two corridors, is knocked down entirely - a hallway
# leaving the common room is a doorless mouth, not a walled room.
func _plan_open_circulation_walls(runs: Array, cats: Dictionary) -> void:
	if not bool(_plan_archetype.get("open_circ", false)):
		return
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var a = int(run["a"])
		var b = int(run["b"])
		if a < 0 or b < 0:
			continue
		var ga = _plan_cat_group(String(cats.get(a, "")))
		var gb = _plan_cat_group(String(cats.get(b, "")))
		var pairv = [ga, gb]
		var knock = ("hall" in pairv and "corridor" in pairv) \
			or (ga == "corridor" and gb == "corridor")
		if not knock:
			continue
		var lr = _plan_run_len(run)
		if lr < 1:
			continue
		var kept = []
		for h in run["holes"]:
			if String(h[2]) == "cut":
				kept.append(h)
		run["holes"] = kept
		# Half-cell anchor stubs stay at both ends: a fully knocked wall
		# also removes its junction nodes, leaving the neighbors' walls
		# floating in space.
		if lr >= 2:
			_plan_force_hole(run, 0.5, float(lr) - 1.0)
		else:
			_plan_force_hole(run, 0.0, float(lr))
		var fh = run["holes"][run["holes"].size() - 1]
		fh[2] = "open"


# Network entrances (archetypes with "open_ends"): one or two tunnel
# end caps open onto the darkness - the passage runs off the sketch
# instead of dead-ending on a wall. End caps are short exterior runs on
# corridor rooms; the ones nearest the sketch border are preferred, and
# multiple entrances keep their distance from each other.
func _plan_network_entrances(vr, runs: Array, cats: Dictionary, cw: int, ch: int) -> void:
	var oe = _plan_archetype.get("open_ends", null)
	if oe == null:
		return
	var want = vr.randi_range(int(oe[0]), int(oe[1]))
	var cands = []
	for ri in range(runs.size()):
		var run = runs[ri]
		if String(run["kind"]) != "ext":
			continue
		var lr = _plan_run_len(run)
		if lr < 1 or lr > 3:
			continue
		var rid = int(max(int(run["a"]), int(run["b"])))
		if _plan_cat_group(String(cats.get(rid, ""))) != "corridor":
			continue
		var px = 0.0
		var py = 0.0
		if bool(run["vert"]):
			px = float(run["x"])
			py = (float(run["y0"]) + float(run["y1"])) * 0.5
		else:
			px = (float(run["x0"]) + float(run["x1"])) * 0.5
			py = float(run["y"])
		var edge_d = min(min(px, float(cw) - px), min(py, float(ch) - py))
		cands.append([edge_d + vr.randf() * 0.5, ri, Vector2(px, py)])
	cands.sort()
	var made = 0
	var placed_at = []
	var min_gap = float(int(min(cw, ch))) / 3.0
	for ci in range(cands.size()):
		if made >= want:
			break
		var mid = cands[ci][2]
		var far_enough = true
		for pp in placed_at:
			if mid.distance_to(pp) < min_gap:
				far_enough = false
				break
		if not far_enough:
			continue
		var run = runs[int(cands[ci][1])]
		var lr2 = _plan_run_len(run)
		var kept = []
		for h in run["holes"]:
			if String(h[2]) == "cut":
				kept.append(h)
		run["holes"] = kept
		_plan_force_hole(run, 0.0, float(lr2))
		var fh = run["holes"][run["holes"].size() - 1]
		fh[2] = "open"
		placed_at.append(mid)
		made += 1


# Cavern rule (archetypes with "wide_opens"): rooms do not have DOORS,
# they flow into each other - every doored interior wall opens up to a
# wide gap with half-cell rock stubs at both ends, so the separations
# read as pinched necks between chambers instead of built walls.
func _plan_cave_openings(runs: Array, cats: Dictionary) -> void:
	if not bool(_plan_archetype.get("wide_opens", false)):
		return
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var has_door = false
		for h in run["holes"]:
			if String(h[2]) == "door":
				has_door = true
				break
		if not has_door:
			continue
		var lr = _plan_run_len(run)
		if lr < 1:
			continue
		var kept = []
		for h in run["holes"]:
			var ht = String(h[2])
			if ht == "door" or ht == "open":
				continue
			kept.append(h)
		run["holes"] = kept
		if lr >= 2:
			_plan_force_hole(run, 0.5, float(lr) - 1.0)
		else:
			_plan_force_hole(run, 0.0, float(lr))
		var fh = run["holes"][run["holes"].size() - 1]
		fh[2] = "open"


# Orphan wall pruning: after the door passes some wall scraps end up
# attached to nothing (a fully knocked junction strands the neighbors'
# anchor stubs, an opened-up room leaves a floating box). Solid wall
# stretches are grouped into connectivity components over touching
# points (T-junctions and diagonal chamfer endpoints included);
# interior-only components under 3.5 cells of total length are erased,
# their window/door holes with them.
func _plan_prune_orphan_walls(runs: Array, extra_segs: Array, extra_int: Array, acx: int, acy: int) -> void:
	var anchors = {}
	for arrs in [extra_segs, extra_int]:
		for sg in arrs:
			for pv in [sg[0], sg[1]]:
				var lp = pv / CELL - Vector2(float(acx), float(acy))
				anchors[str(int(round(lp.x * 2.0))) + "_" + str(int(round(lp.y * 2.0)))] = true
	for _pass in range(2):
		var ivs = []
		for run in runs:
			var lr = _plan_run_len(run)
			if lr <= 0:
				continue
			var gaps = []
			for h in run["holes"]:
				var ht = String(h[2])
				if ht == "open" or ht == "cut":
					gaps.append([float(h[0]), float(h[0]) + float(h[1])])
			gaps.sort()
			var solids = []
			var cur = 0.0
			for g in gaps:
				if float(g[0]) > cur + 0.01:
					solids.append([cur, float(g[0])])
				cur = max(cur, float(g[1]))
			if cur < float(lr) - 0.01:
				solids.append([cur, float(lr)])
			for sv in solids:
				var pa = Vector2()
				var pb = Vector2()
				if bool(run["vert"]):
					pa = Vector2(float(run["x"]), float(run["y0"]) + float(sv[0]))
					pb = Vector2(float(run["x"]), float(run["y0"]) + float(sv[1]))
				else:
					pa = Vector2(float(run["x0"]) + float(sv[0]), float(run["y"]))
					pb = Vector2(float(run["x0"]) + float(sv[1]), float(run["y"]))
				ivs.append({"run": run, "s": float(sv[0]), "e": float(sv[1]),
					"a": pa, "b": pb, "ext": String(run["kind"]) == "ext"})
		if ivs.empty():
			return
		var parent = []
		for i in range(ivs.size()):
			parent.append(i)
		for i in range(ivs.size()):
			for j in range(i + 1, ivs.size()):
				if not _plan_iv_touch(ivs[i], ivs[j]):
					continue
				var ri = _plan_uf_root(parent, i)
				var rj = _plan_uf_root(parent, j)
				if ri != rj:
					parent[ri] = rj
		var comp_len = {}
		var comp_keep = {}
		for i in range(ivs.size()):
			var r = _plan_uf_root(parent, i)
			comp_len[r] = float(comp_len.get(r, 0.0)) + (float(ivs[i]["e"]) - float(ivs[i]["s"]))
			if bool(ivs[i]["ext"]):
				comp_keep[r] = true
			for pv in [ivs[i]["a"], ivs[i]["b"]]:
				if anchors.has(str(int(round(pv.x * 2.0))) + "_" + str(int(round(pv.y * 2.0)))):
					comp_keep[r] = true
		var removed = 0
		for i in range(ivs.size()):
			var r = _plan_uf_root(parent, i)
			if comp_keep.has(r) or float(comp_len[r]) >= 3.5:
				continue
			var run = ivs[i]["run"]
			var s0 = float(ivs[i]["s"])
			var e0 = float(ivs[i]["e"])
			var kept = []
			for h in run["holes"]:
				var ht = String(h[2])
				if (ht == "door" or ht == "window" or ht == "open") \
						and float(h[0]) < e0 - 0.01 and float(h[0]) + float(h[1]) > s0 + 0.01:
					continue
				kept.append(h)
			run["holes"] = kept
			_plan_force_hole(run, s0, e0 - s0)
			var fh = run["holes"][run["holes"].size() - 1]
			fh[2] = "open"
			removed += 1
		if removed == 0:
			return


func _plan_uf_root(parent: Array, i: int) -> int:
	var r = i
	while int(parent[r]) != r:
		r = int(parent[r])
	return r


# Two solid stretches touch when an endpoint of one lies on the other
# (endpoint-to-endpoint or a T against its middle).
func _plan_iv_touch(u, v) -> bool:
	for pv in [u["a"], u["b"]]:
		if _plan_pt_on_iv(pv, v):
			return true
	for pv in [v["a"], v["b"]]:
		if _plan_pt_on_iv(pv, u):
			return true
	return false


func _plan_pt_on_iv(p: Vector2, iv) -> bool:
	var a = iv["a"]
	var b = iv["b"]
	if abs(a.x - b.x) < 0.01:
		return abs(p.x - a.x) < 0.26 and p.y > min(a.y, b.y) - 0.26 and p.y < max(a.y, b.y) + 0.26
	return abs(p.y - a.y) < 0.26 and p.x > min(a.x, b.x) - 0.26 and p.x < max(a.x, b.x) + 0.26


# The inn rule: you walk STRAIGHT into the common room. The hall's
# southernmost exterior wall takes a wide centered door; every other
# exterior door goes away (windows stay).
func _plan_hall_entrance(runs: Array, cats: Dictionary, cw: int = -1) -> void:
	if not bool(_plan_archetype.get("hall_entrance", false)):
		return
	# Symmetric envelope: the ceremonial door sits ON the axis, south.
	var axis = -1.0
	if _plan_env_symx and cw > 0:
		axis = float(cw) * 0.5
	var best = null
	var best_ax = false
	for run in runs:
		if String(run["kind"]) != "ext" or bool(run["vert"]):
			continue
		if String(cats.get(int(max(int(run["a"]), int(run["b"]))), "")) != "hall":
			continue
		if _plan_run_len(run) < 2:
			continue
		var on_ax = axis > 0.0 and float(run["x0"]) + 0.5 <= axis \
				and float(run["x1"]) + 0.5 >= axis
		if best == null or (on_ax and not best_ax) \
				or (on_ax == best_ax and (int(run["y"]) > int(best["y"]) \
				or (int(run["y"]) == int(best["y"]) and _plan_run_len(run) > _plan_run_len(best)))):
			best = run
			best_ax = on_ax
	if best == null:
		# No horizontal facade: fall back to the hall's longest VERTICAL
		# exterior wall - the entrance belongs in the common room, east
		# or west door included.
		for runv in runs:
			if String(runv["kind"]) != "ext" or not bool(runv["vert"]):
				continue
			if String(cats.get(int(max(int(runv["a"]), int(runv["b"]))), "")) != "hall":
				continue
			if _plan_run_len(runv) < 2:
				continue
			if best == null or _plan_run_len(runv) > _plan_run_len(best):
				best = runv
	if best == null:
		# The hall has no exterior wall at all: leave the wave's entrance.
		return
	for run2 in runs:
		if String(run2["kind"]) != "ext":
			continue
		var kc = []
		for h in run2["holes"]:
			var ht = String(h[2])
			if ht == "door" or ht == "open":
				continue
			kc.append(h)
		run2["holes"] = kc
	var lb = _plan_run_len(best)
	var wd = 2 if lb >= 4 else 1
	var pos = stepify(float(lb - wd) * 0.5, 0.5)
	if best_ax:
		# Door centered on the BUILDING axis, not on the run.
		pos = stepify(clamp(axis - float(wd) * 0.5 - float(best["x0"]), 0.0, float(lb - wd)), 0.5)
	if not _plan_try_hole(best, pos, wd, "door"):
		var kept = []
		for h2 in best["holes"]:
			if String(h2[2]) == "window" and float(h2[0]) < pos + wd + 1.0 \
					and float(h2[0]) + float(h2[1]) > pos - 1.0:
				continue
			kept.append(h2)
		best["holes"] = kept
		if not _plan_try_hole(best, pos, wd, "door"):
			_plan_force_hole(best, pos, float(wd))
			var fh = best["holes"][best["holes"].size() - 1]
			fh[2] = "door"


# Manor doors: (1) enfilade - the dining room (or the living room)
# opens onto the hall through a grand bay, most of the shared wall;
# (2) the monumental staircase is fully open to the hall; (3) a modest
# service back door survives hall_entrance's front-door purge.
func _plan_manor_doors(runs: Array, cats: Dictionary) -> void:
	if bool(_plan_archetype.get("enfilade", false)):
		for want in _plan_archetype.get("enfilade_cats", ["dining", "living"]):
			var enf = null
			for run in runs:
				if String(run["kind"]) != "int":
					continue
				var ca = String(cats.get(int(run["a"]), ""))
				var cb = String(cats.get(int(run["b"]), ""))
				if not ((ca == "hall" and cb == want) or (ca == want and cb == "hall")):
					continue
				if enf == null or _plan_run_len(run) > _plan_run_len(enf):
					enf = run
			if enf == null:
				continue
			var le = _plan_run_len(enf)
			if le < 3:
				continue
			var ke = []
			for h in enf["holes"]:
				var ht = String(h[2])
				if ht == "door" or ht == "open":
					continue
				ke.append(h)
			enf["holes"] = ke
			var wb = max(2.0, float(le) - 2.0)
			_plan_force_hole(enf, float(le - wb) * 0.5, wb)
			var eh = enf["holes"][enf["holes"].size() - 1]
			eh[2] = "open"
			break
	if bool(_plan_archetype.get("grand_stair", false)):
		# The stair block and the hall are ONE space: every shared wall
		# is knocked down entirely.
		for run in runs:
			if String(run["kind"]) != "int":
				continue
			var ga = String(cats.get(int(run["a"]), ""))
			var gb = String(cats.get(int(run["b"]), ""))
			var pv = [ga, gb]
			if not ("hall" in pv and "staircase" in pv):
				continue
			var ls = _plan_run_len(run)
			if ls < 1:
				continue
			var ks = []
			for h in run["holes"]:
				if String(h[2]) == "cut":
					ks.append(h)
			run["holes"] = ks
			if ls >= 2:
				_plan_force_hole(run, 0.5, float(ls) - 1.0)
			else:
				_plan_force_hole(run, 0.0, float(ls))
			var sh2 = run["holes"][run["holes"].size() - 1]
			sh2[2] = "open"
	if bool(_plan_archetype.get("service_door", false)):
		# One discreet back door on a service room, preferring the wall
		# furthest from the facade (smallest y).
		var best = null
		for run in runs:
			if String(run["kind"]) != "ext" or bool(run["vert"]):
				continue
			var rid = int(max(int(run["a"]), int(run["b"])))
			var cat = String(cats.get(rid, ""))
			var grp = _plan_cat_group(cat)
			if not (grp == "kitchen" or grp == "storage" or cat == "servants"):
				continue
			if _plan_run_len(run) < 2:
				continue
			if best == null or int(run["y"]) < int(best["y"]):
				best = run
		if best == null:
			for runv in runs:
				if String(runv["kind"]) != "ext" or not bool(runv["vert"]):
					continue
				var rid2 = int(max(int(runv["a"]), int(runv["b"])))
				var cat2 = String(cats.get(rid2, ""))
				var grp2 = _plan_cat_group(cat2)
				if not (grp2 == "kitchen" or grp2 == "storage" or cat2 == "servants"):
					continue
				if _plan_run_len(runv) < 2:
					continue
				if best == null or _plan_run_len(runv) > _plan_run_len(best):
					best = runv
		if best != null:
			var lb = _plan_run_len(best)
			var pos = stepify(float(lb - 1) * 0.5, 0.5)
			if not _plan_try_hole(best, pos, 1, "door"):
				var kept = []
				for h2 in best["holes"]:
					if String(h2[2]) == "window" and float(h2[0]) < pos + 2.0 \
							and float(h2[0]) + float(h2[1]) > pos - 1.0:
						continue
					kept.append(h2)
				best["holes"] = kept
				if not _plan_try_hole(best, pos, 1, "door"):
					_plan_force_hole(best, pos, 1.0)
					var fh = best["holes"][best["holes"].size() - 1]
					fh[2] = "door"


# True when an exterior run's outside is the bailey COURTYARD.
func _plan_run_faces_court(run) -> bool:
	if _plan_bailey == null or String(run["kind"]) != "ext":
		return false
	var courts = _plan_bailey.get("courts", [_plan_bailey["court"]])
	var probes = []
	if bool(run["vert"]):
		var ym = (float(run["y0"]) + float(run["y1"])) * 0.5
		probes.append(Vector2(float(run["x"]) + 0.5, ym))
		probes.append(Vector2(float(run["x"]) - 0.5, ym))
	else:
		var xm = (float(run["x0"]) + float(run["x1"])) * 0.5
		probes.append(Vector2(xm, float(run["y"]) + 0.5))
		probes.append(Vector2(xm, float(run["y"]) - 0.5))
	for court in courts:
		for pr in probes:
			if court.has_point(pr):
				return true
	return false


# UNIVERSAL CONNECTIVITY GUARANTEE (every archetype and Custom): flood
# from every exterior-opened room through interior doors; while an
# unreached component remains, punch a bridging door on the longest
# interior wall between reached and unreached (preferring walls that
# do not belong to a prison cell), and flood again. With no exterior
# opening at all (underground levels), the biggest room seeds the flood.
func _plan_connect_flood(runs: Array, cats: Dictionary) -> void:
	for _pass in range(24):
		var reached = {}
		var queue = []
		var edges = {}
		for run5 in runs:
			var a5 = int(run5["a"])
			var b5 = int(run5["b"])
			var has_op = false
			for h5 in run5["holes"]:
				var ht5 = String(h5[2])
				if ht5 == "door" or ht5 == "open":
					has_op = true
					break
			if not has_op:
				continue
			if String(run5["kind"]) == "ext":
				for sid5 in [a5, b5]:
					if sid5 >= 0 and not reached.has(sid5):
						reached[sid5] = true
						queue.append(sid5)
			elif a5 >= 0 and b5 >= 0:
				if not edges.has(a5):
					edges[a5] = []
				edges[a5].append(b5)
				if not edges.has(b5):
					edges[b5] = []
				edges[b5].append(a5)
		if reached.empty():
			# No exterior opening at all (underground levels): the room
			# with the most interior wall seeds the flood.
			var wall_by = {}
			for runf in runs:
				if String(runf["kind"]) != "int":
					continue
				for sidf in [int(runf["a"]), int(runf["b"])]:
					if sidf >= 0:
						wall_by[sidf] = int(wall_by.get(sidf, 0)) + _plan_run_len(runf)
			var seedr = -1
			var seedw = -1
			for sidg in wall_by:
				if int(wall_by[sidg]) > seedw:
					seedw = int(wall_by[sidg])
					seedr = int(sidg)
			if seedr >= 0:
				reached[seedr] = true
				queue.append(seedr)
		while not queue.empty():
			var cur = int(queue.pop_back())
			for nb in edges.get(cur, []):
				if not reached.has(int(nb)):
					reached[int(nb)] = true
					queue.append(int(nb))
		var best_run5 = null
		var best_clean = false
		for run6 in runs:
			if String(run6["kind"]) != "int":
				continue
			var a6 = int(run6["a"])
			var b6 = int(run6["b"])
			if a6 < 0 or b6 < 0:
				continue
			if reached.has(a6) == reached.has(b6):
				continue
			# Prefer bridges that avoid prison cells (corridor-only rule).
			var clean6 = _plan_cat_group(String(cats.get(a6, ""))) != "bedroom" \
				and _plan_cat_group(String(cats.get(b6, ""))) != "bedroom"
			if not bool(_plan_archetype.get("cells_exact", false)):
				clean6 = true
			if best_run5 == null or (clean6 and not best_clean) \
					or (clean6 == best_clean and _plan_run_len(run6) > _plan_run_len(best_run5)):
				best_run5 = run6
				best_clean = clean6
		if best_run5 == null:
			break
		var len6 = _plan_run_len(best_run5)
		if not _plan_try_hole(best_run5, stepify(float(len6 - 1) * 0.5, 0.5), 1, "door"):
			_plan_force_hole(best_run5, stepify(float(len6 - 1) * 0.5, 0.5), 1.0)
			var fh6 = best_run5["holes"][best_run5["holes"].size() - 1]
			fh6[2] = "door"


# Castle door pass. (1) The gatehouse gets its ceremonial through
# passage: a wide door on the outer south wall, a wide opening onto the
# court, both axis-centered. (2) Every ring room and the keep get one
# centered door onto the COURT (the court is the corridor); rooms the
# wave already served keep theirs.
func _plan_bailey_doors(rng, runs: Array, cats: Dictionary) -> void:
	if _plan_bailey == null:
		return
	var court = _plan_bailey["court"]
	# Perimeter discipline (replaces single_entrance for castles): the
	# curtain wall keeps NO stray door - only the gatehouse passage and
	# the posterns punched further down.
	for run0 in runs:
		if String(run0["kind"]) != "ext":
			continue
		if _plan_run_faces_court(run0):
			continue
		if String(cats.get(int(max(int(run0["a"]), int(run0["b"]))), "")) == "gatehouse":
			continue
		var kept0 = []
		for h0 in run0["holes"]:
			var ht0 = String(h0[2])
			if ht0 == "door" or ht0 == "open":
				continue
			kept0.append(h0)
		run0["holes"] = kept0
	var best_court = {}
	var has_court_door = {}
	var hall_south = null
	var peri_by_room = {}
	var gate_runs_h = []
	for run in runs:
		if String(run["kind"]) != "ext":
			continue
		var inner = int(max(int(run["a"]), int(run["b"])))
		if inner < 0:
			continue
		var is_gate = String(cats.get(inner, "")) == "gatehouse"
		var faces_court = _plan_run_faces_court(run)
		if String(cats.get(inner, "")) == "hall" and faces_court and not bool(run["vert"]):
			# The keep's ceremonial front: its SOUTHERNMOST court-facing
			# wall takes the wide double door.
			if hall_south == null or int(run["y"]) > int(hall_south["y"]):
				hall_south = run
		if not is_gate and not faces_court and _plan_run_len(run) >= 3:
			if not peri_by_room.has(inner) \
					or _plan_run_len(run) > _plan_run_len(peri_by_room[inner]):
				peri_by_room[inner] = run
		if is_gate:
			# Gatehouse: wipe every opening on all its walls. The actual
			# passage is punched AFTER the loop, on the two AXIS runs
			# only - small-room merging can weld side rooms onto the
			# gatehouse, and punching every horizontal run of the
			# deformed room gaped the south curtain open.
			var kept_g = []
			for hg in run["holes"]:
				if String(hg[2]) == "cut":
					kept_g.append(hg)
			run["holes"] = kept_g
			if not bool(run["vert"]):
				gate_runs_h.append(run)
			continue
		if not faces_court:
			continue
		for h in run["holes"]:
			var ht = String(h[2])
			if ht == "door" or ht == "open":
				has_court_door[inner] = true
				break
		if not best_court.has(inner) or _plan_run_len(run) > _plan_run_len(best_court[inner]):
			best_court[inner] = run
	for rid in best_court:
		if has_court_door.has(int(rid)):
			continue
		var run2 = best_court[rid]
		var len2 = _plan_run_len(run2)
		if len2 < 1:
			continue
		var done2 = _plan_try_hole(run2, stepify(float(len2 - 1) * 0.5, 0.5), 1, "door")
		if not done2:
			for off2 in range(int(len2)):
				if _plan_try_hole(run2, float(off2), 1, "door"):
					done2 = true
					break
		if not done2:
			# Windows saturate the wall: a room MUST reach the court -
			# the most central window makes way for the door.
			var best_w = -1
			var best_d = 1e18
			for wi in range(run2["holes"].size()):
				if String(run2["holes"][wi][2]) != "window":
					continue
				var wc = float(run2["holes"][wi][0]) + float(run2["holes"][wi][1]) * 0.5
				var dd2 = abs(wc - float(len2) * 0.5)
				if dd2 < best_d:
					best_d = dd2
					best_w = wi
			if best_w >= 0:
				var wpos = float(run2["holes"][best_w][0])
				run2["holes"].remove(best_w)
				_plan_try_hole(run2, wpos, 1, "door")
	# Gatehouse passage: ONE opening per side, dead on the gate axis.
	# Among the gatehouse's horizontal runs crossing the axis, the
	# southernmost is the front bay, the northernmost court-facing one
	# the court bay - any other wall segment of the room stays solid.
	if not gate_runs_h.empty():
		var grect = _plan_bailey["gate"]
		var gaxis = grect.position.x + grect.size.x * 0.5
		var gw2 = grect.size.x if grect.size.x <= 2.0 else grect.size.x - 2.0
		var g_front = null
		var g_court = null
		for gr in gate_runs_h:
			if float(gr["x0"]) > gaxis - 0.5 or float(gr["x1"]) < gaxis + 0.5:
				continue
			if _plan_run_faces_court(gr):
				if g_court == null or int(gr["y"]) < int(g_court["y"]):
					g_court = gr
			else:
				if g_front == null or int(gr["y"]) > int(g_front["y"]):
					g_front = gr
		for gsel in [g_front, g_court]:
			if gsel == null:
				continue
			var gpos = gaxis - gw2 * 0.5 - float(gsel["x0"])
			_plan_force_hole(gsel, gpos, gw2)
			var ghh = gsel["holes"][gsel["holes"].size() - 1]
			ghh[2] = "open"
	# Enfilade door: hall -> throne room, wide (2) and centered on the
	# keep axis. The wave's own hall/living door (anywhere) is wiped
	# first so the processional line reads clean.
	var krect = _plan_bailey["keep"]
	var kaxis = krect.position.x + krect.size.x * 0.5
	var enf_run = null
	for run_e in runs:
		if String(run_e["kind"]) != "int" or bool(run_e["vert"]):
			continue
		var ca = String(cats.get(int(run_e["a"]), ""))
		var cb = String(cats.get(int(run_e["b"]), ""))
		if not ((ca == "hall" and cb == "living") or (ca == "living" and cb == "hall")):
			continue
		var ke = []
		for he in run_e["holes"]:
			var hte = String(he[2])
			if hte == "door" or hte == "open":
				continue
			ke.append(he)
		run_e["holes"] = ke
		if enf_run == null or _plan_run_len(run_e) > _plan_run_len(enf_run):
			enf_run = run_e
	if enf_run != null:
		# A grand bay, most of the shared wall: hall and throne room
		# are nearly one room, two wall stubs marking the threshold.
		var wb = max(2.0, float(_plan_run_len(enf_run)) - 2.0)
		var epos = kaxis - wb * 0.5 - float(enf_run["x0"])
		_plan_force_hole(enf_run, epos, wb)
		var ehh = enf_run["holes"][enf_run["holes"].size() - 1]
		ehh[2] = "open"
	# The keep's double door: wide (2), dead-centered on its south
	# court wall, windows making way if they must.
	if hall_south != null:
		var lh = _plan_run_len(hall_south)
		if lh >= 2:
			var hpos = stepify(float(lh - 2) * 0.5, 0.5)
			if not _plan_try_hole(hall_south, hpos, 2, "door"):
				var keep_h = []
				for hh in hall_south["holes"]:
					var hta = String(hh[2])
					if hta == "window" and float(hh[0]) < hpos + 3.0 \
							and float(hh[0]) + float(hh[1]) > hpos - 1.0:
						continue
					keep_h.append(hh)
				hall_south["holes"] = keep_h
				if not _plan_try_hole(hall_south, hpos, 2, "door"):
					_plan_force_hole(hall_south, hpos, 2.0)
					var fhh = hall_south["holes"][hall_south["holes"].size() - 1]
					fhh[2] = "door"
	# Posterns: 1-2 modest side doors through the curtain on random ring
	# rooms - a castle lives through more than its front gate.
	var pool = peri_by_room.keys()
	_plan_shuffle(rng, pool)
	var n_post = rng.randi_range(1, 2)
	for pi2 in range(int(min(n_post, pool.size()))):
		var prun = peri_by_room[pool[pi2]]
		var lp = _plan_run_len(prun)
		var pdone = _plan_try_hole(prun, stepify(float(lp - 1) * 0.5, 0.5), 1, "door")
		if not pdone:
			for poff in range(int(lp)):
				if _plan_try_hole(prun, float(poff), 1, "door"):
					pdone = true
					break
		if not pdone:
			# The curtain is wall-to-wall windows: the most central one
			# steps aside - a castle needs its posterns.
			var pw_b = -1
			var pw_d = 1e18
			for pwi in range(prun["holes"].size()):
				if String(prun["holes"][pwi][2]) != "window":
					continue
				var pwc = float(prun["holes"][pwi][0]) + float(prun["holes"][pwi][1]) * 0.5
				var pdd = abs(pwc - float(lp) * 0.5)
				if pdd < pw_d:
					pw_d = pdd
					pw_b = pwi
			if pw_b >= 0:
				var pw_pos = float(prun["holes"][pw_b][0])
				prun["holes"].remove(pw_b)
				_plan_try_hole(prun, pw_pos, 1, "door")
	# ACCESSIBILITY GUARANTEE: no room ever ends up doorless. Any room
	# with zero door/open on ANY of its walls gets one punched toward a
	# neighbor on its longest interior wall - by force if it must.
	var opened = {}
	var by_room_int = {}
	for run3 in runs:
		for h3 in run3["holes"]:
			var ht3 = String(h3[2])
			if ht3 == "door" or ht3 == "open":
				for sid in [int(run3["a"]), int(run3["b"])]:
					if sid >= 0:
						opened[sid] = true
		if String(run3["kind"]) == "int":
			for sid2 in [int(run3["a"]), int(run3["b"])]:
				if sid2 < 0:
					continue
				if not by_room_int.has(sid2) \
						or _plan_run_len(run3) > _plan_run_len(by_room_int[sid2]):
					by_room_int[sid2] = run3
	for rid3 in by_room_int:
		if opened.has(int(rid3)):
			continue
		var run4 = by_room_int[rid3]
		var len4 = _plan_run_len(run4)
		if len4 < 1:
			continue
		var done4 = _plan_try_hole(run4, stepify(float(len4 - 1) * 0.5, 0.5), 1, "door")
		if not done4:
			for off4 in range(int(len4)):
				if _plan_try_hole(run4, float(off4), 1, "door"):
					done4 = true
					break
		if not done4:
			_plan_force_hole(run4, stepify(float(len4 - 1) * 0.5, 0.5), 1.0)
			var fh4 = run4["holes"][run4["holes"].size() - 1]
			fh4[2] = "door"


# Sealed vaults: on archetypes that ask for it, a fraction of the
# signature rooms lose EVERY door - walled-off burial chambers the
# players have to break into. Pure crypt flavor.
func _plan_seal_rooms(vr, runs: Array, cats: Dictionary) -> void:
	var chance = float(_plan_archetype.get("seal_chance", 0.0))
	if chance <= 0.0:
		return
	var program = _plan_archetype.get("program", null)
	if program == null:
		return
	var rep_grp = _plan_cat_group(String(program.get("repeat", ["bedroom", "M"])[0]))
	var sealed = {}
	for r in cats:
		if _plan_cat_group(String(cats[r])) == rep_grp and vr.randf() < chance:
			sealed[int(r)] = true
			if bool(_plan_archetype.get("cells_exact", false)):
				# A walled-up cell READS as intentional: it gets the
				# oubliette label instead of looking like a door bug.
				cats[int(r)] = "wine"
	if sealed.empty():
		return
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		if not (sealed.has(int(run["a"])) or sealed.has(int(run["b"]))):
			continue
		var kept7 = []
		for h7 in run["holes"]:
			var ht7 = String(h7[2])
			if ht7 != "door" and ht7 != "open":
				kept7.append(h7)
		run["holes"] = kept7


# Processional suite: the doors along the ceremonial axis are CENTERED
# (nave -> chancel -> sanctuary), and the nave gets a centered entrance
# on its bottom exterior wall - crooked side doors between axis rooms
# would break the whole progression the layout exists for.
func _plan_axis_doors(runs: Array, cats: Dictionary) -> void:
	var axial = bool(_plan_archetype.get("axial_corridor", false))
	if not bool(_plan_archetype.get("processional", false)) and not axial:
		return
	var order = {"hall": 0, "chancel": 1, "sanctuary": 2}
	for run in runs:
		var a = int(run["a"])
		var b = int(run["b"])
		if String(run["kind"]) == "int":
			var ca = String(cats.get(a, ""))
			var cb = String(cats.get(b, ""))
			if not order.has(ca) or not order.has(cb):
				continue
			if int(abs(int(order[ca]) - int(order[cb]))) != 1:
				continue
			# Wipe the wave's off-axis doors between the pair, then
			# punch one centered opening.
			var kept = []
			for h in run["holes"]:
				var ht = String(h[2])
				if ht != "door" and ht != "open":
					kept.append(h)
			run["holes"] = kept
			var len3 = _plan_run_len(run)
			var w3 = 2 if len3 >= 4 else 1
			_plan_try_hole(run, stepify(float(len3 - w3) * 0.5, 0.5), w3, "open")

	# Bottom entrance of the nave: among the nave's horizontal exterior
	# runs, the SOUTHERNMOST (largest y - the entrance side of every
	# reference plan), longest on ties. One centered door if the
	# connection wave left none anywhere on it.
	var best_ent = null
	for run2 in runs:
		if String(run2["kind"]) != "ext" or bool(run2["vert"]):
			continue
		var ic2 = String(cats.get(int(max(int(run2["a"]), int(run2["b"]))), ""))
		if ic2 != "hall" and not (axial and ic2 == "corridor"):
			continue
		if best_ent == null or int(run2["y"]) > int(best_ent["y"]) \
				or (int(run2["y"]) == int(best_ent["y"]) \
				and _plan_run_len(run2) > _plan_run_len(best_ent)):
			best_ent = run2
	if best_ent != null:
		# One BIG centered double door: whatever the wave punched on the
		# facade is wiped and replaced.
		var kept5 = []
		for h2 in best_ent["holes"]:
			var ht2 = String(h2[2])
			if ht2 != "door" and ht2 != "open":
				kept5.append(h2)
		best_ent["holes"] = kept5
		var len4 = _plan_run_len(best_ent)
		var dw = 2 if len4 >= 4 else 1
		if not _plan_try_hole(best_ent, stepify(float(len4 - dw) * 0.5, 0.5), dw, "door"):
			_plan_try_hole(best_ent, stepify(float(len4 - 1) * 0.5, 0.5), 1, "door")
	_plan_temple_windows(runs, cats)


# Churches are pierced: dense REGULAR windows along every exterior wall
# of the axial suite (nave, alcoves, chancel, sanctuary), one window
# every other cell. Offsets depend only on the run length, so mirror
# walls get mirror windows and the symmetry holds.
func _plan_temple_windows(runs: Array, cats: Dictionary) -> void:
	if not bool(_plan_archetype.get("processional", false)):
		return
	var suite = {"hall": true, "chancel": true, "sanctuary": true}
	for run in runs:
		if String(run["kind"]) != "ext":
			continue
		var inner = int(max(int(run["a"]), int(run["b"])))
		if not suite.has(String(cats.get(inner, ""))):
			continue
		var len5 = _plan_run_len(run)
		if len5 < 2:
			continue
		var n_w = int(len5 / 2)
		var start = (float(len5) - float(n_w * 2 - 1)) * 0.5
		for wi in range(n_w):
			_plan_try_hole(run, stepify(start + float(wi * 2), 0.5), 1, "window")


# Under a comb, every signature room (cell, ward, dormitory...) that sits
# on the circulation gets its own door onto it, centered on the shared
# wall - the row of identical doors along the corridor is half of what
# makes a prison read as a prison. Rooms the connection wave already
# doored are left alone.
func _plan_comb_doors(runs: Array, cats: Dictionary) -> void:
	if not _plan_archetype.has("comb") or _plan_small_mode:
		return
	var program = _plan_archetype.get("program", null)
	if program == null:
		return
	var rep_grp = _plan_cat_group(String(program.get("repeat", ["bedroom", "M"])[0]))
	# Longest shared run per (signature room -> circulation) pair, and
	# whether ANY run of that room already carries a door.
	var best_run = {}
	var has_door = {}
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var a = int(run["a"])
		var b = int(run["b"])
		var ga = _plan_cat_group(String(cats.get(a, "")))
		var gb = _plan_cat_group(String(cats.get(b, "")))
		var rep_id = -1
		if ga == rep_grp and (gb == "corridor" or gb == "hall"):
			rep_id = a
		elif gb == rep_grp and (ga == "corridor" or ga == "hall"):
			rep_id = b
		if rep_id < 0:
			continue
		for h in run["holes"]:
			var ht = String(h[2])
			if ht == "door" or ht == "open":
				has_door[rep_id] = true
				break
		if not best_run.has(rep_id) or _plan_run_len(run) > _plan_run_len(best_run[rep_id]):
			best_run[rep_id] = run
	for rep_id2 in best_run:
		if has_door.has(int(rep_id2)):
			continue
		var run2 = best_run[rep_id2]
		var len2 = _plan_run_len(run2)
		if len2 < 1:
			continue
		# Centered door first; tiny random fallback if the center is
		# blocked by a cut.
		if not _plan_try_hole(run2, stepify(float(len2 - 1) * 0.5, 0.5), 1, "door"):
			for off in [0.0, float(len2 - 1)]:
				if _plan_try_hole(run2, off, 1, "door"):
					break


# Cuts a corridor-bounded block into regular slices along its long axis,
# with a mid split into two back-to-back banks when the block is deep.
# Returns false when the block is too small to comb (caller BSPs it).
func _plan_comb_slice(rect: Rect2, slice_w: int, leaves: Array, mid_corrs: Array) -> bool:
	var rw = int(rect.size.x)
	var rh = int(rect.size.y)
	if rw < slice_w or rh < slice_w or rw * rh < slice_w * 4:
		return false
	var horiz = rw >= rh
	var along = rw if horiz else rh
	var deep = rh if horiz else rw
	if along < slice_w * 2:
		return false
	var serve = bool(_plan_archetype.get("comb_serve", false))
	var banks = [[0, deep]]
	if serve and deep > 5:
		# Serviced comb (prisons, hospitals): a corridor runs BETWEEN the
		# two banks, so every single slice opens on a corridor - no room
		# is ever landlocked behind another.
		var midr = int(deep / 2)
		banks = [[0, midr], [midr + 1, deep]]
		if horiz:
			mid_corrs.append(Rect2(rect.position.x, rect.position.y + midr, rw, 1))
		else:
			mid_corrs.append(Rect2(rect.position.x + midr, rect.position.y, 1, rh))
	elif deep > 7:
		var half = int(deep / 2)
		banks = [[0, half], [half, deep]]
	var n_sl = int(max(1, along / slice_w))
	for bk in banks:
		for si in range(n_sl):
			var a0 = int(round(float(si) * float(along) / float(n_sl)))
			var a1 = int(round(float(si + 1) * float(along) / float(n_sl)))
			if a1 <= a0:
				continue
			if horiz:
				leaves.append(Rect2(rect.position.x + a0, rect.position.y + bk[0], a1 - a0, bk[1] - bk[0]))
			else:
				leaves.append(Rect2(rect.position.x + bk[0], rect.position.y + a0, bk[1] - bk[0], a1 - a0))
	return true


func _plan_build_interior(seed_i: int, mask: Array, acx: int, acy: int, cw: int, ch: int, area_cells: int, room_min: int, room_max: int, bsp_min: int, eff_max: int):
	# SMALL MODE (archetypes with a wish_small, under 250 used cells):
	# a handful of BIG rooms, not a warren - the BSP aims for 4-6 rooms
	# total and the comb slicing stands down.
	_plan_small_mode = area_cells < 250 and _plan_archetype.get("program", {}) != null \
			and Dictionary(_plan_archetype.get("program", {})).has("wish_small")
	if _plan_small_mode:
		# Aim for 4-6 rooms total: min side 3-4 (the merge threshold is
		# min^2 - a min of 6 melted every room under 36 cells into one
		# blob), and a re-split ceiling of a third of the floor so the
		# non-hall remainder still divides into a few rooms.
		room_min = int(max(room_min, clamp(round(sqrt(area_cells / 10.0)), 3, 4)))
		room_max = int(max(room_max, room_min + 5))
		bsp_min = int(max(bsp_min, room_min))
		eff_max = int(clamp(area_cells / 3, 25, 80))
	elif bool(_plan_archetype.get("grand_rooms", false)):
		# MANOR MODE: on big footprints the rooms grow with the house -
		# a manor has drawing rooms and long galleries, not a warren of
		# cottage-sized rooms. Floors only: raising the sliders by hand
		# still works.
		var g_min = int(clamp(round(sqrt(area_cells) / 7.0), 3, 6))
		room_min = int(max(room_min, g_min))
		room_max = int(max(room_max, g_min + 4))
		bsp_min = int(max(bsp_min, room_min))
		# Grand but BOUNDED: past ~10 cells of side the BSP must split,
		# or single leaves swallow a third of the plan.
		eff_max = int(clamp(max(eff_max, g_min + 4), 7, 10))
		# A big house circulates through hallways, not through bedrooms:
		# the corridor density floor rises with the footprint (restored
		# with the rest of the tuning after generation).
		var g_corr = clamp(0.35 + (float(area_cells) - 300.0) / 2200.0, 0.35, 0.75)
		_plan_corr = max(_plan_corr, g_corr)
	# UNIVERSAL tiny-footprint floor, on top of every mode and every
	# archetype: small structures hold FEW rooms - a 4x4 cottage is one
	# room, maybe two, never four 2x2 closets. Raising bsp_min stops
	# the splits mechanically (a side must reach 2*min to divide), and
	# eff_max is lifted so the area rule cannot force one either.
	if area_cells <= 32:
		bsp_min = int(max(bsp_min, 5))
		eff_max = int(max(eff_max, area_cells))
		_plan_corr = 0.0
	elif area_cells <= 60:
		bsp_min = int(max(bsp_min, 4))
		eff_max = int(max(eff_max, 24))
		_plan_corr = min(_plan_corr, 0.2)
	_plan_cur_towers = []
	_plan_diag_pts = []
	_plan_bevel_tris = []
	# Independent RNG streams per interior stage: each slider reshuffles its
	# own stage only.
	var r_circ = _plan_stream(seed_i, 211)
	var r_bsp = _plan_stream(seed_i, 307)
	var r_irr = _plan_stream(seed_i, 401)
	var r_misc = _plan_stream(seed_i, 503)
	var r_cat = _plan_stream(seed_i, 601)
	# Bevels and towers shape the SILHOUETTE: external seed, so every
	# interior variant (and every floor) shares the exact same outline.
	var r_bev = _plan_stream(_plan_cur_seed_ext, 701)
	var r_tow = _plan_stream(_plan_cur_seed_ext, 809)
	var r_door = _plan_stream(seed_i, 907)
	var r_win = _plan_stream(seed_i, 1009)
	var r_split = _plan_stream(seed_i, 1103)

	# 2. Circulation FIRST: hall + corridor spine + secondary corridors.
	var circ = _plan_circulation(r_circ, mask, cw, ch, area_cells)
	var leaves = []
	var bands = []
	for li in range(circ["leaves"].size()):
		if String(circ["cats"][li]) == "corridor":
			bands.append(circ["leaves"][li])
		elif String(circ["cats"][li]) in ["hall", "chancel", "sanctuary", "gatehouse"] and _plan_archetype.has("comb") and not _plan_small_mode:
			# Under a comb the landmark hall structures the grid too: the
			# side blocks align on the nave / market floor / great pool,
			# so the slices become regular chapels / stalls / chambers
			# flanking it.
			bands.append(circ["leaves"][li])
	var xs = _plan_intervals(0, cw, bands, true)
	var ys = _plan_intervals(0, ch, bands, false)
	var comb_w = 0
	if _plan_archetype.has("comb") and not _plan_small_mode:
		# Comb macro-pattern (prisons, barracks, wards, monk cells): the
		# blocks between corridors are cut into REGULAR slices instead of
		# BSP - repeated identical rooms in rows are the identity of these
		# buildings. One slice width per building.
		var cwr = _plan_archetype["comb"]
		comb_w = r_bsp.randi_range(int(cwr[0]), int(cwr[1]))
	var mid_corrs = []
	for yi in ys:
		for xi in xs:
			var cell_r = Rect2(xi[0], yi[0], xi[1] - xi[0], yi[1] - yi[0])
			if comb_w > 0 and not _plan_comb_slice(cell_r, comb_w, leaves, mid_corrs):
				_plan_bsp(r_bsp, cell_r, bsp_min, eff_max, leaves)
			elif comb_w == 0:
				_plan_bsp(r_bsp, cell_r, bsp_min, eff_max, leaves)
	for mc in mid_corrs:
		circ["leaves"].append(mc)
		circ["cats"].append("corridor")
	var circ_leaf_from = leaves.size()
	for c in circ["leaves"]:
		leaves.append(c)

	var leaf_id = _plan_zeroed_ints(cw * ch)
	for li in range(leaves.size()):
		var lr = leaves[li]
		for y in range(int(max(0, lr.position.y)), int(min(ch, lr.position.y + lr.size.y))):
			for x in range(int(max(0, lr.position.x)), int(min(cw, lr.position.x + lr.size.x))):
				leaf_id[y * cw + x] = li + 1
	var sym_int = bool(_plan_archetype.get("sym_interior", false))
	if sym_int:
		# Perfect interior symmetry: the right half of the leaf grid is the
		# mirror of the left half (the axis-centered hall reflects onto
		# itself). Mirror twins share a leaf index but the component
		# labeling below separates them into their own rooms.
		for y in range(ch):
			for x in range(int(cw / 2)):
				leaf_id[y * cw + (cw - 1 - x)] = leaf_id[y * cw + x]
	var net_rooms = bool(_plan_archetype.get("net_rooms", false)) \
			and not _plan_net_chambers.empty()
	if net_rooms:
		# CHAMBER-AND-PASSAGE dungeons: every network chamber is exactly
		# ONE room, every tunnel cell is corridor. No BSP subdivision,
		# no extra circulation, no interior walls - just isolated rooms
		# strung on 1-cell passages.
		for i in range(cw * ch):
			leaf_id[i] = 0
		for k in range(_plan_net_chambers.size()):
			for rc in _plan_net_chambers[k]:
				for y in range(int(max(0, rc.position.y)), int(min(ch, rc.position.y + rc.size.y))):
					for x in range(int(max(0, rc.position.x)), int(min(cw, rc.position.x + rc.size.x))):
						if mask[y * cw + x] == 1:
							leaf_id[y * cw + x] = k + 1
	var lab = _plan_label_components(mask, leaf_id, cw, ch)
	var rooms = lab["rooms"]
	var comp_leaf = lab["leaf"]
	# Circulation components: category + protection from merging.
	var circ_cat = {}
	var protected = {}
	for ci in range(comp_leaf.size()):
		var lidx = int(comp_leaf[ci]) - 1
		if net_rooms:
			# Tunnels (unassigned cells) are the corridors; chambers are
			# the rooms - nothing else exists.
			if int(comp_leaf[ci]) == 0:
				circ_cat[ci] = "corridor"
				protected[ci] = true
			continue
		if lidx >= circ_leaf_from:
			circ_cat[ci] = String(circ["cats"][lidx - circ_leaf_from])
			protected[ci] = true
	# Circulation slivers (corridor leaves clipped to 1-3 cells by the
	# mask) must not survive as sealed boxes: protection and category
	# drop, the merge pass absorbs them like any fragment.
	var frag_sizes = {}
	for i in range(cw * ch):
		if rooms[i] >= 0:
			frag_sizes[rooms[i]] = int(frag_sizes.get(rooms[i], 0)) + 1
	for k in circ_cat.keys():
		if String(circ_cat[k]) == "hall":
			continue
		if int(frag_sizes.get(int(k), 0)) < 6:
			circ_cat.erase(int(k))
			protected.erase(int(k))
	_plan_merge_small_rooms(rooms, cw, ch, room_min * room_min, protected)
	_plan_dissolve_useless_corridors(rooms, cw, ch, protected, circ_cat)
	_plan_refresh_corr_ids(circ_cat)
	for k in protected.keys():
		if not circ_cat.has(int(k)):
			circ_cat[int(k)] = "corridor"
	for k in circ_cat.keys():
		if not protected.has(int(k)):
			circ_cat.erase(int(k))
	# Exactly one hall, and it must keep real hall proportions (>= 2x2)
	# after envelope clipping; leftovers become normal rooms.
	var infos_h = _plan_room_infos(rooms, cw, ch)
	var hall_best = -1
	var hall_cells = 0
	for kk in circ_cat.keys():
		if String(circ_cat[kk]) != "hall":
			continue
		var nh = 0
		if infos_h.has(int(kk)):
			nh = int(infos_h[int(kk)]["cells"])
		if nh > hall_cells:
			hall_cells = nh
			hall_best = int(kk)
	for kk in circ_cat.keys():
		if String(circ_cat[kk]) == "hall" and int(kk) != hall_best:
			protected.erase(int(kk))
			circ_cat.erase(int(kk))
	if hall_best >= 0 and infos_h.has(hall_best):
		var hb = infos_h[hall_best]
		if int(hb["bw"]) < 2 or int(hb["bh"]) < 2 or int(hb["cells"]) < 4:
			protected.erase(hall_best)
			circ_cat.erase(hall_best)

	# 3. Room Irregularity: L-shaped rooms via corner transfers, then a
	# relabel (transfers can split a room id in two).
	if bool(_plan_archetype.get("grand_rooms", false)) and area_cells >= 300 \
			and hall_best >= 0:
		# GRAND RECEPTIONS: 1-2 pairs of ordinary rooms flanking the hall
		# merge into double-size reception rooms - the deliberate size
		# hierarchy (ballroom, dining hall vs bedrooms) that uniform BSP
		# never produces. Rectangular unions strongly preferred.
		var cap_gr = int(clamp(area_cells / 8, 30, 110))
		for _gp in range(2):
			var sizes_gr = {}
			var bx0g = {}
			var bx1g = {}
			var by0g = {}
			var by1g = {}
			var hall_adj = {}
			var borders_gr = {}
			for i in range(cw * ch):
				var r = rooms[i]
				if r < 0:
					continue
				sizes_gr[r] = int(sizes_gr.get(r, 0)) + 1
				var y = i / cw
				var x = i - y * cw
				bx0g[r] = int(min(int(bx0g.get(r, cw)), x))
				bx1g[r] = int(max(int(bx1g.get(r, -1)), x))
				by0g[r] = int(min(int(by0g.get(r, ch)), y))
				by1g[r] = int(max(int(by1g.get(r, -1)), y))
				for nb in [[x + 1, y], [x, y + 1]]:
					if nb[0] >= cw or nb[1] >= ch:
						continue
					var o = rooms[nb[1] * cw + nb[0]]
					if o < 0 or o == r:
						continue
					if o == hall_best or r == hall_best:
						hall_adj[o if r == hall_best else r] = true
					else:
						var kp = [int(min(r, o)), int(max(r, o))]
						borders_gr[kp] = int(borders_gr.get(kp, 0)) + 1
			var cands_gr = []
			for kp in borders_gr:
				if int(borders_gr[kp]) < 2:
					continue
				var a = int(kp[0])
				var b = int(kp[1])
				if protected.has(a) or protected.has(b):
					continue
				if not hall_adj.has(a) or not hall_adj.has(b):
					continue
				var tot = int(sizes_gr.get(a, 0)) + int(sizes_gr.get(b, 0))
				if tot > cap_gr:
					continue
				var ubw = int(max(int(bx1g[a]), int(bx1g[b]))) - int(min(int(bx0g[a]), int(bx0g[b]))) + 1
				var ubh = int(max(int(by1g[a]), int(by1g[b]))) - int(min(int(by0g[a]), int(by0g[b]))) + 1
				var sc_gr = float(tot) + r_irr.randf() * 6.0
				if ubw * ubh == tot:
					# The union is a clean rectangle: a real ballroom.
					sc_gr += 40.0
				cands_gr.append([sc_gr, a, b])
			if cands_gr.empty():
				break
			cands_gr.sort()
			var pick = cands_gr[cands_gr.size() - 1]
			for i in range(cw * ch):
				if rooms[i] == int(pick[2]):
					rooms[i] = int(pick[1])
	if bool(_plan_archetype.get("grand_rooms", false)):
		# Reference-style wall discipline: no four-way crossings, no
		# staircase borders.
		_plan_break_cross_junctions(rooms, cw, ch, protected, room_min * room_min)
		_plan_straighten_walls(rooms, cw, ch, protected, room_min * room_min)
	if _plan_room_irr > 0.02:
		_plan_l_transfers(r_irr, rooms, mask, cw, ch, protected)
		var lab2 = _plan_label_components(mask, rooms, cw, ch)
		var rooms2 = lab2["rooms"]
		var old_of = lab2["leaf"]
		var protected2 = {}
		var circ_cat2 = {}
		for ci in range(old_of.size()):
			var old_id = int(old_of[ci])
			if protected.has(old_id):
				protected2[ci] = true
				circ_cat2[ci] = String(circ_cat.get(old_id, "corridor"))
		rooms = rooms2
		protected = protected2
		circ_cat = circ_cat2
		_plan_merge_small_rooms(rooms, cw, ch, room_min * room_min, protected)

	# 4. Residual closets, then thin-room cleanup (nothing 1 cell wide over
	# 3+ cells long may exist outside corridors).
	if room_min <= 2:
		_plan_carve_closets(r_misc, rooms, mask, cw, ch)
	_plan_fix_thin_rooms(rooms, cw, ch, protected)
	var trimmed = _plan_trim_thin_arms(rooms, cw, ch, protected)
	_plan_smooth_stairs(rooms, mask, cw, ch, protected)
	# Sprawling rooms (filling under 45% of their bounding box, way over
	# the max size, or dwarfing every other room) are re-split by a local
	# BSP: merging them away would only grow the snake.
	var splitted = _plan_split_sprawling(r_split, rooms, cw, ch, protected, bsp_min, eff_max)
	var enforced = _plan_enforce_corridor_width(rooms, cw, ch, protected, circ_cat, int(circ.get("wd", 1)))
	if trimmed or splitted or enforced:
		rooms = _plan_relabel_remap(mask, rooms, cw, ch, protected, circ_cat)
		_plan_merge_small_rooms(rooms, cw, ch, room_min * room_min, protected)
		# The merges above can recreate stepped boundaries: smooth again.
		_plan_smooth_stairs(rooms, mask, cw, ch, protected)
	# Corridors that touch must communicate openly: adjacent corridor ids
	# fuse into a single room (no wall, no door between them).
	if _plan_merge_touching_corridors(rooms, cw, ch, protected, circ_cat):
		_plan_enforce_corridor_width(rooms, cw, ch, protected, circ_cat, int(circ.get("wd", 1)))
	# Rooms glued only to corridors/outside make no sense: they annex the
	# corridor stretch separating them from the nearest room.
	if _plan_fix_isolated_rooms(rooms, cw, ch, protected, circ_cat):
		rooms = _plan_relabel_remap(mask, rooms, cw, ch, protected, circ_cat)
		_plan_dissolve_useless_corridors(rooms, cw, ch, protected, circ_cat)
		_plan_refresh_corr_ids(circ_cat)
	rooms = _plan_min_room_count(r_split, mask, rooms, cw, ch, protected, circ_cat, area_cells, bsp_min)
	# Second stabilization round: the merges of the first round can rebuild
	# 1-wide bands and stretched Ls along corridors.
	_plan_fix_thin_rooms(rooms, cw, ch, protected)
	var trimmed2 = _plan_trim_thin_arms(rooms, cw, ch, protected)
	var splitted2 = _plan_split_sprawling(r_split, rooms, cw, ch, protected, bsp_min, eff_max)
	var enforced2 = _plan_enforce_corridor_width(rooms, cw, ch, protected, circ_cat, int(circ.get("wd", 1)))
	if trimmed2 or splitted2 or enforced2:
		rooms = _plan_relabel_remap(mask, rooms, cw, ch, protected, circ_cat)
		_plan_merge_small_rooms(rooms, cw, ch, room_min * room_min, protected)
		_plan_smooth_stairs(rooms, mask, cw, ch, protected)
	# Final safety: the stabilization merges can re-collapse tiny homes
	# into one big room; re-split without re-merging afterwards.
	rooms = _plan_min_room_count(r_split, mask, rooms, cw, ch, protected, circ_cat, area_cells, bsp_min)
	if _plan_proc_suite != null and not _plan_proc_bumps.empty():
		# Side chapels and porch: each bump's cells take the id of the
		# room RIGHT BEHIND it (the nave on the upper level, whatever
		# packed room sits there on the crypt level), so they render as
		# open alcoves instead of tiny closed boxes. Adjacency keeps the
		# welded room one connected component - no relabel needed.
		for bp in _plan_proc_bumps:
			var votes = {}
			for by in range(int(bp.position.y), int(bp.position.y + bp.size.y)):
				for bx in range(int(bp.position.x), int(bp.position.x + bp.size.x)):
					for nb in [[bx - 1, by], [bx + 1, by], [bx, by - 1], [bx, by + 1]]:
						if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
							continue
						if bp.has_point(Vector2(nb[0] + 0.5, nb[1] + 0.5)):
							continue
						if mask[nb[1] * cw + nb[0]] != 1:
							continue
						var rid = int(rooms[nb[1] * cw + nb[0]])
						if rid > 0:
							votes[rid] = int(votes.get(rid, 0)) + 1
			var best_id = -1
			var best_n = 0
			for vk in votes:
				if int(votes[vk]) > best_n:
					best_n = int(votes[vk])
					best_id = int(vk)
			if best_id <= 0:
				continue
			for by2 in range(int(bp.position.y), int(bp.position.y + bp.size.y)):
				for bx2 in range(int(bp.position.x), int(bp.position.x + bp.size.x)):
					if bx2 >= 0 and bx2 < cw and by2 >= 0 and by2 < ch \
							and mask[by2 * cw + bx2] == 1:
						rooms[by2 * cw + bx2] = best_id
	if sym_int:
		# The stabilization merges above pick neighbours without caring
		# about symmetry: stamp the left half back over the right and
		# relabel, so the FINAL geometry is exactly mirror-perfect.
		for y in range(ch):
			for x in range(int(cw / 2)):
				rooms[y * cw + (cw - 1 - x)] = rooms[y * cw + x]
		var lab3 = _plan_label_components(mask, rooms, cw, ch)
		var old_of3 = lab3["leaf"]
		var protected3 = {}
		var circ_cat3 = {}
		for ci3 in range(old_of3.size()):
			var oid3 = int(old_of3[ci3])
			if protected.has(oid3):
				protected3[ci3] = true
				circ_cat3[ci3] = String(circ_cat.get(oid3, "corridor"))
		rooms = lab3["rooms"]
		protected = protected3
		circ_cat = circ_cat3

	if bool(_plan_archetype.get("processional", false)):
		# Upper level guarantee: whatever degenerate sizing or clamping
		# produced, NO unprotected leftover room survives - every stray
		# cell blob is absorbed into an adjacent protected room (suite or
		# annex), keeping the level at suite + annexes, period.
		for _pass in range(3):
			var absorb = {}
			for y6 in range(ch):
				for x6 in range(cw):
					if mask[y6 * cw + x6] != 1:
						continue
					var rid6 = int(rooms[y6 * cw + x6])
					if rid6 <= 0 or protected.has(rid6) or absorb.has(rid6):
						continue
					for nb6 in [[x6 - 1, y6], [x6 + 1, y6], [x6, y6 - 1], [x6, y6 + 1]]:
						if nb6[0] < 0 or nb6[0] >= cw or nb6[1] < 0 or nb6[1] >= ch:
							continue
						if mask[nb6[1] * cw + nb6[0]] != 1:
							continue
						var nid6 = int(rooms[nb6[1] * cw + nb6[0]])
						if nid6 > 0 and protected.has(nid6):
							absorb[rid6] = nid6
							break
			if absorb.empty():
				break
			for i6 in range(cw * ch):
				var r6 = int(rooms[i6])
				if absorb.has(r6):
					rooms[i6] = int(absorb[r6])
	# 5. Category assignment (Traditional profile).
	var cats = _plan_assign_categories(r_cat, rooms, cw, ch, circ_cat)
	# A hall only exists alongside at least a living room, a bedroom, a
	# bathroom and a kitchen; otherwise it becomes the first missing one.
	var have = {}
	for k0 in cats:
		have[_plan_cat_group(String(cats[k0]))] = true
	var hall_id2 = -1
	for k0 in cats:
		if String(cats[k0]) == "hall":
			hall_id2 = int(k0)
	if hall_id2 >= 0 and _plan_archetype.get("program", null) == null:
		# Residential rule only: an archetype program is not a house, its
		# hall (nave, market floor...) never converts into a bedroom.
		for req in ["living", "bedroom", "bathroom", "kitchen"]:
			if not have.has(req):
				cats[hall_id2] = req
				protected.erase(hall_id2)
				break

	# 5b. Corridor stitching: parallel corridors (or corridor and hall)
	# separated by a single 1-2 cell thickness of ordinary room get ONE
	# short transverse passage carved between them (the cells switch to
	# the corridor); open_circ then knocks the shared walls down and the
	# wings read as one connected open circulation.
	_plan_stitch_corridors(rooms, cw, ch, circ_cat, protected)
	# 6. Wall runs, then exterior corner work (bevels/towers) and interior
	# chamfers BEFORE any opening is placed.
	var runs = _plan_collect_runs(mask, rooms, cw, ch)
	_plan_all_runs = runs
	var extra_segs = []
	var extra_int = []
	var arcs = []
	_plan_corners(r_bev, mask, runs, cw, ch, acx, acy, extra_segs, arcs, rooms, cats)
	if _plan_room_irr > 0.02:
		_plan_interior_chamfers(r_irr, rooms, mask, runs, cw, ch, acx, acy, extra_int)

	# 7. Doors: entrance into the hall, wave connection through allowed host
	# categories, open passages between living spaces, loops, repairs.
	# 8. Windows per category. These ALWAYS run (identical RNG consumption
	# and scoring whatever the toggles); when Doors & Windows is off their
	# holes are simply not applied at emission, so the same seed always
	# reproduces the same building.
	var stats = _plan_connect_rooms(r_door, runs, rooms, cw, ch, cats)
	_plan_comb_doors(runs, cats)
	_plan_axis_doors(runs, cats)
	_plan_bailey_doors(r_door, runs, cats)
	_plan_hall_entrance(runs, cats, cw)
	_plan_manor_doors(runs, cats)
	_plan_network_entrances(r_door, runs, cats, cw, ch)
	_plan_bridge_corridors(runs, cats)
	_plan_open_circulation_walls(runs, cats)
	_plan_prison_cells(runs, rooms, cw, ch, cats)
	_plan_connect_flood(runs, cats)
	_plan_seal_rooms(r_door, runs, cats)
	_plan_cave_openings(runs, cats)
	_plan_prune_orphan_walls(runs, extra_segs, extra_int, acx, acy)
	var win_count = _plan_room_windows(r_win, runs, rooms, cw, ch, cats, area_cells)

	# 9. Labels (always computed, even in Exterior Walls Only: the overlay
	# toggle shows/hides them later).
	var labels = _plan_build_labels(rooms, cw, ch, cats, acx, acy)

	var score = _plan_score(runs, rooms, cw, ch, cats, stats, win_count, area_cells)
	return {"runs": runs, "extra_segs": extra_segs, "extra_int": extra_int,
		"arcs": arcs, "labels": labels, "rooms": rooms, "cats": cats,
		"stats": stats, "score": score, "bevel_tris": _plan_bevel_tris.duplicate()}


# ── Envelope grammar ────────────────────────────────────────────────────────

# Full silhouette pipeline for one candidate mask.
func _plan_draw_silhouette(vr, mask: Array, cw: int, ch: int) -> void:
	_plan_envelope(vr, mask, cw, ch)
	_plan_env_accrete(vr, mask, cw, ch)
	_plan_generic_annex(vr, mask, cw, ch)
	_plan_env_oriels(vr, mask, cw, ch)
	if _plan_last_shape != "network":
		# Networks LIVE on thin tunnels: eroding them would sever the map.
		_plan_erode_thin(mask, cw, ch)
	_plan_keep_main_component(mask, cw, ch)


# Massing quality: how compactly the footprint fills its bounding box,
# plus a bonus for x-symmetry - the two traits every keeper plan shared.
func _plan_massing_score(mask: Array, cw: int, ch: int) -> float:
	var x0 = cw
	var x1 = -1
	var y0 = ch
	var y1 = -1
	var n = 0
	for y in range(ch):
		for x in range(cw):
			if mask[y * cw + x] == 1:
				n += 1
				x0 = int(min(x0, x))
				x1 = int(max(x1, x))
				y0 = int(min(y0, y))
				y1 = int(max(y1, y))
	if n < 4:
		return -1.0
	var fill = float(n) / float((x1 - x0 + 1) * (y1 - y0 + 1))
	var symn = 0
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if mask[y * cw + x] == 1 and mask[y * cw + (x0 + x1 - x)] == 1:
				symn += 1
	# Fill is scored as a BAND around ~0.68: enough mass to read as one
	# building, enough void for wings to PROJECT. A filled slab (no
	# wings at all) is explicitly not a manor and gets buried.
	var band = 1.0 - abs(fill - 0.68) * 2.5
	if fill > 0.92:
		band -= 0.6
	return band + float(symn) / float(n) * 0.5


func _plan_envelope(vr, mask: Array, cw: int, ch: int) -> void:
	var e = _plan_orig
	var mn = int(min(cw, ch))
	var t = int(clamp(round(mn * (0.32 + vr.randf() * 0.16)), 3, mn))
	_plan_env_circle = null
	_plan_env_symx = false
	_plan_oriel_pts = []
	_plan_net_chambers = []
	_plan_proc_suite = null
	_plan_proc_bumps = []
	_plan_proc_apse = null
	_plan_proc_annex = []
	_plan_bailey = null
	# Size feasibility per shape: the archetype grammar below must obey
	# the same guards as the default grammar.
	var feasible = {"rect": true, "circle": mn >= 6, "network": cw >= 8 and ch >= 8,
		"suite": cw >= 10 and ch >= 10, "bailey": cw >= 13 and ch >= 13,
		"L": cw >= 6 and ch >= 6, "D": cw >= 6 and ch >= 6,
		"T": cw >= 8 and ch >= 8, "U": cw >= 8 and ch >= 8,
		"wings": cw >= 8 and ch >= 8, "Z": cw >= 8 and ch >= 8,
		"J": cw >= 8 and ch >= 8, "Y": cw >= 9 and ch >= 9,
		"H": cw >= 10 and ch >= 10, "cross": cw >= 10 and ch >= 10,
		"pavilions": cw >= 10 and ch >= 8,
		"courtyard": cw >= 11 and ch >= 11 and t * 2 + 3 <= mn}
	var opts = []
	var ashapes = _plan_archetype.get("shapes", null)
	if ashapes != null:
		# The archetype dictates its own silhouette grammar: a wizard's
		# tower is round, a warehouse is a rectangle, sewers are a network.
		# Under "shapes_by_size" the grammar leans with the footprint: a
		# cottage sticks to sober rectangles and Ls, a mansion can afford
		# follies (H, Y, cross, courtyards).
		var by_size = bool(_plan_archetype.get("shapes_by_size", false))
		var szt = clamp((float(mn) - 9.0) / 9.0, 0.0, 1.0)
		var tiers = {"rect": 0, "D": 0,
			"L": 1, "T": 1, "U": 1, "wings": 1, "Z": 1, "J": 1,
			"Y": 2, "H": 2, "cross": 2, "courtyard": 2, "pavilions": 2}
		for sk in ashapes:
			if bool(feasible.get(String(sk), false)):
				var w2 = float(ashapes[sk])
				if by_size:
					var tier = int(tiers.get(String(sk), 1))
					if tier == 0:
						# Plain slabs are a cottage privilege: on large
						# builds they vanish - a manor NEEDS projecting
						# wings.
						w2 *= lerp(1.6, 0.0, szt)
					elif tier == 2:
						w2 *= lerp(0.2, 1.6, szt)
					else:
						w2 *= lerp(0.7, 1.1, szt)
				opts.append([w2, String(sk)])
	if opts.empty():
		opts = [[1.4 - e, "rect"]]
		if cw >= 6 and ch >= 6:
			opts.append([0.3 + e * 0.8, "L"])
		if cw >= 8 and ch >= 8:
			opts.append([e * 0.8, "T"])
			opts.append([e * 0.8, "U"])
			opts.append([e * 0.9, "wings"])
		if cw >= 8 and ch >= 8:
			opts.append([e * 0.6, "Z"])
			opts.append([e * 0.5, "J"])
		if cw >= 9 and ch >= 9:
			opts.append([e * 0.5, "Y"])
		if cw >= 6 and ch >= 6:
			opts.append([0.2 + e * 0.5, "D"])
		if cw >= 10 and ch >= 10:
			opts.append([e * 0.6, "H"])
			opts.append([e * 0.6, "cross"])
		if cw >= 11 and ch >= 11 and t * 2 + 3 <= mn:
			opts.append([e * 0.7, "courtyard"])
	var total = 0.0
	for o in opts:
		total += float(o[0])
	var pick = vr.randf() * max(total, 0.001)
	var shape = "rect"
	for o in opts:
		pick -= float(o[0])
		if pick <= 0.0:
			shape = String(o[1])
			break
	if shape == "rect":
		var sm = _plan_sround(vr, e * mn * 0.12)
		_plan_fill_rect(mask, cw, ch, vr.randi_range(0, sm), vr.randi_range(0, sm),
			cw - vr.randi_range(0, sm) * 2, ch - vr.randi_range(0, sm) * 2, 1)
	elif shape == "L":
		_plan_fill_rect(mask, cw, ch, 0, 0, cw, t, 1)
		_plan_fill_rect(mask, cw, ch, 0, 0, t, ch, 1)
	elif shape == "T":
		_plan_fill_rect(mask, cw, ch, 0, 0, cw, t, 1)
		_plan_fill_rect(mask, cw, ch, int((cw - t) / 2), 0, t, ch, 1)
	elif shape == "U":
		_plan_fill_rect(mask, cw, ch, 0, 0, cw, ch, 1)
		_plan_fill_rect(mask, cw, ch, t, 0, cw - t * 2, ch - t, 0)
	elif shape == "H":
		_plan_fill_rect(mask, cw, ch, 0, 0, t, ch, 1)
		_plan_fill_rect(mask, cw, ch, cw - t, 0, t, ch, 1)
		_plan_fill_rect(mask, cw, ch, 0, int((ch - t) / 2), cw, t, 1)
	elif shape == "cross":
		_plan_fill_rect(mask, cw, ch, int((cw - t) / 2), 0, t, ch, 1)
		_plan_fill_rect(mask, cw, ch, 0, int((ch - t) / 2), cw, t, 1)
	elif shape == "Z":
		# Top bar right-aligned, bottom bar left-aligned, central link.
		var zw = int(clamp(round(cw * 0.65), t + 1, cw))
		_plan_fill_rect(mask, cw, ch, cw - zw, 0, zw, t, 1)
		_plan_fill_rect(mask, cw, ch, 0, ch - t, zw, t, 1)
		_plan_fill_rect(mask, cw, ch, int((cw - t) / 2), 0, t, ch, 1)
	elif shape == "J":
		# Tall right arm, bottom foot, small top cap.
		_plan_fill_rect(mask, cw, ch, cw - t, 0, t, ch, 1)
		_plan_fill_rect(mask, cw, ch, 0, ch - t, cw, t, 1)
		_plan_fill_rect(mask, cw, ch, int(max(0, cw - t * 2)), 0, t * 2, t, 1)
	elif shape == "Y":
		# Central stem plus two upper arms with a notch between them.
		_plan_fill_rect(mask, cw, ch, int((cw - t) / 2), int(ch / 3), t, ch - int(ch / 3), 1)
		var aw = int(max(2, (cw - t) / 2))
		_plan_fill_rect(mask, cw, ch, 0, 0, aw + int(t / 2) + 1, int(ch / 2), 1)
		_plan_fill_rect(mask, cw, ch, cw - aw - int(t / 2) - 1, 0, aw + int(t / 2) + 1, int(ch / 2), 1)
	elif shape == "D":
		# Full-height left bar plus a shorter right body: bevels round the
		# right side afterwards.
		var dw = int(clamp(round(cw * 0.7), 3, cw - 2))
		_plan_fill_rect(mask, cw, ch, 0, 0, dw, ch, 1)
		var ins = int(max(1, round(ch * 0.15)))
		_plan_fill_rect(mask, cw, ch, dw - 1, ins, cw - dw + 1, ch - ins * 2, 1)
	elif shape == "wings":
		var mw = int(round(cw * (0.55 + vr.randf() * 0.2)))
		var mh = int(round(ch * (0.55 + vr.randf() * 0.2)))
		var mx = int((cw - mw) / 2)
		var my = int((ch - mh) / 2)
		_plan_fill_rect(mask, cw, ch, mx, my, mw, mh, 1)
		for _i in range(1 + vr.randi_range(0, 2)):
			var ww = vr.randi_range(3, int(max(3, cw / 3)))
			var wh = vr.randi_range(3, int(max(3, ch / 3)))
			var side = vr.randi_range(0, 3)
			if side == 0:
				_plan_fill_rect(mask, cw, ch, vr.randi_range(mx, mx + mw - ww), int(max(0, my - wh)), ww, wh + 1, 1)
			elif side == 1:
				_plan_fill_rect(mask, cw, ch, vr.randi_range(mx, mx + mw - ww), my + mh - 1, ww, wh + 1, 1)
			elif side == 2:
				_plan_fill_rect(mask, cw, ch, int(max(0, mx - ww)), vr.randi_range(my, my + mh - wh), ww + 1, wh, 1)
			else:
				_plan_fill_rect(mask, cw, ch, mx + mw - 1, vr.randi_range(my, my + mh - wh), ww + 1, wh, 1)
	elif shape == "pavilions":
		# Manor facade: wide central body, two protruding corner
		# pavilions on the entrance (south) side, and usually a central
		# frontispiece over the door - x-symmetric by construction.
		var bh2 = int(clamp(round(ch * (0.55 + vr.randf() * 0.15)), 4, ch - 3))
		_plan_fill_rect(mask, cw, ch, 0, 0, cw, bh2, 1)
		var pw = int(clamp(round(cw * (0.18 + vr.randf() * 0.08)), 3, int(cw / 3)))
		_plan_fill_rect(mask, cw, ch, 0, bh2 - 1, pw, ch - bh2 + 1, 1)
		_plan_fill_rect(mask, cw, ch, cw - pw, bh2 - 1, pw, ch - bh2 + 1, 1)
		if vr.randf() < 0.7:
			var fw = int(clamp(round(cw * (0.16 + vr.randf() * 0.1)), 3, int(cw / 3)))
			var fd = int(max(2, int((ch - bh2) / 2)))
			_plan_fill_rect(mask, cw, ch, int((cw - fw) / 2), bh2 - 1, fw, fd + 1, 1)
		_plan_env_symx = true
	elif shape == "courtyard":
		_plan_fill_rect(mask, cw, ch, 0, 0, cw, ch, 1)
		_plan_fill_rect(mask, cw, ch, t, t, cw - t * 2, ch - t * 2, 0)
	elif shape == "circle":
		# Disc footprint. The stair-stepped exterior runs are dropped at
		# emission and replaced by one true circle arc.
		var ccx = cw * 0.5 - 0.5
		var ccy = ch * 0.5 - 0.5
		var rr = mn * 0.5 - 0.5
		for y in range(ch):
			for x in range(cw):
				var ddx = float(x) - ccx
				var ddy = float(y) - ccy
				if ddx * ddx + ddy * ddy <= rr * rr:
					mask[y * cw + x] = 1
		_plan_env_circle = [ccx + 0.5, ccy + 0.5, rr + 0.5]
	elif shape == "network":
		_plan_env_network(vr, mask, cw, ch)
	elif shape == "suite":
		_plan_env_suite(vr, mask, cw, ch)
	elif shape == "bailey":
		_plan_env_bailey(vr, mask, cw, ch)
	_plan_last_shape = shape
	var sym = String(_plan_archetype.get("sym", ""))
	if sym == "" and _plan_archetype.has("sym_large") and mn >= 13:
		# Stately symmetry is a big-house luxury: rolled per building,
		# only when the footprint can afford it.
		var sl2 = _plan_archetype.get("sym_large", {})
		if vr.randf() < float(sl2.get("chance", 0.5)):
			sym = String(sl2.get("axis", "x"))
	if sym == "x" or sym == "xy":
		_plan_env_symx = true
	if sym != "":
		# Ceremonial symmetry: the mask is unioned with its own mirror, so
		# whatever the grammar drew becomes symmetric on that axis. The
		# random mirroring below is skipped (it exists to break symmetry).
		var src2 = mask.duplicate()
		for y in range(ch):
			for x in range(cw):
				var sx2 = cw - 1 - x if (sym == "x" or sym == "xy") else x
				var sy2 = ch - 1 - y if (sym == "y" or sym == "xy") else y
				if src2[sy2 * cw + sx2] == 1:
					mask[y * cw + x] = 1
	else:
		# Random mirroring gives the asymmetric variants of each canonical
		# shape. Pavilions keep their facade: no flip.
		var fxr = vr.randf() < 0.5
		var fyr = vr.randf() < 0.5
		if shape != "pavilions":
			_plan_mask_mirror(mask, cw, ch, fxr, fyr)


# Organic accretion (archetypes with an "accrete" spec): rectangular
# bays pushed OUT of the silhouette edge plus an optional bite carved
# back IN, so the canonical shapes come out grown-over across the
# centuries rather than stamped. Runs on the Shape stream. A bite whose
# largest surviving component keeps less than 70% of the footprint is
# reverted (a severed wing would be dropped by the main-component pass).
func _plan_env_accrete(vr, mask: Array, cw: int, ch: int) -> void:
	var spec = _plan_archetype.get("accrete", null)
	if spec == null or cw < 8 or ch < 8:
		return
	if _plan_env_circle != null or _plan_bailey != null or _plan_proc_suite != null:
		return
	# Small builds accrete timidly (one bay, rare bite); big ones sprawl.
	var szt = clamp((float(int(min(cw, ch))) - 8.0) / 10.0, 0.0, 1.0)
	var bmax = 1 + int(round(float(int(spec.get("bumps", 3)) - 1) * szt))
	var nb = vr.randi_range(1, int(max(1, bmax)))
	for _b in range(nb):
		# Anchor: a filled cell with an empty inner-grid neighbor; the
		# bay extrudes outward through it, overlapping by one cell.
		var cands = []
		for y in range(1, ch - 1):
			for x in range(1, cw - 1):
				if mask[y * cw + x] != 1:
					continue
				for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
					if mask[(y + d[1]) * cw + x + d[0]] == 0:
						cands.append([x, y, d[0], d[1]])
		if cands.empty():
			break
		var c = cands[vr.randi_range(0, cands.size() - 1)]
		# Bays stay ANNEXES: shallow (2-3) and modest, or the canonical
		# silhouette drowns in blob.
		var depth = vr.randi_range(2, int(clamp(int(min(cw, ch)) / 5, 2, 3)))
		var breadth = vr.randi_range(2, int(clamp(int(min(cw, ch)) / 4, 3, 5)))
		if int(c[2]) != 0:
			var x0 = int(c[0])
			if int(c[2]) < 0:
				x0 = int(c[0]) - depth + 1
			_plan_fill_rect(mask, cw, ch, x0, int(c[1]) - int(breadth / 2), depth, breadth, 1)
			if _plan_env_symx:
				_plan_fill_rect(mask, cw, ch, cw - x0 - depth, int(c[1]) - int(breadth / 2), depth, breadth, 1)
		else:
			var y0 = int(c[1])
			if int(c[3]) < 0:
				y0 = int(c[1]) - depth + 1
			_plan_fill_rect(mask, cw, ch, int(c[0]) - int(breadth / 2), y0, breadth, depth, 1)
			if _plan_env_symx:
				_plan_fill_rect(mask, cw, ch, cw - (int(c[0]) - int(breadth / 2)) - breadth, y0, breadth, depth, 1)
	if vr.randf() < float(spec.get("notch", 0.0)) * (0.4 + 0.6 * szt):
		var pre = 0
		for i in range(cw * ch):
			if mask[i] == 1:
				pre += 1
		var backup = mask.duplicate()
		# The bite is anchored on the hull and carves inward.
		var cands2 = []
		for y in range(ch):
			for x in range(cw):
				if mask[y * cw + x] != 1:
					continue
				var hull = x == 0 or y == 0 or x == cw - 1 or y == ch - 1
				if not hull:
					for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
						if mask[(y + d[1]) * cw + x + d[0]] == 0:
							hull = true
							break
				if hull:
					cands2.append([x, y])
		if not cands2.empty():
			var c2 = cands2[vr.randi_range(0, cands2.size() - 1)]
			var nw = vr.randi_range(2, int(clamp(cw / 6, 2, 3)))
			var nh = vr.randi_range(2, int(clamp(ch / 6, 2, 3)))
			_plan_fill_rect(mask, cw, ch, int(c2[0]) - int(nw / 2), int(c2[1]) - int(nh / 2), nw, nh, 0)
			if _plan_env_symx:
				_plan_fill_rect(mask, cw, ch, cw - (int(c2[0]) - int(nw / 2)) - nw, int(c2[1]) - int(nh / 2), nw, nh, 0)
			var seen = {}
			var best_sz = 0
			for i in range(cw * ch):
				if mask[i] == 1 and not seen.has(i):
					var q = [i]
					seen[i] = true
					var qi = 0
					var sz = 0
					while qi < q.size():
						var cur = q[qi]
						qi += 1
						sz += 1
						var cy = cur / cw
						var cx = cur - cy * cw
						for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
							var nx2 = cx + int(d[0])
							var ny2 = cy + int(d[1])
							if nx2 >= 0 and nx2 < cw and ny2 >= 0 and ny2 < ch:
								var oi = ny2 * cw + nx2
								if mask[oi] == 1 and not seen.has(oi):
									seen[oi] = true
									q.append(oi)
					best_sz = int(max(best_sz, sz))
			if float(best_sz) < float(pre) * 0.7:
				for i in range(cw * ch):
					mask[i] = backup[i]


# Bow-window bays (archetypes with an "oriels" spec): shallow bays
# extruded from flat stretches of the south facade; their two outer
# corners are recorded and ALWAYS chamfered by the bevel pass, so the
# bay reads as a canted oriel instead of a square bump. Mirrored under
# a symmetric envelope.
func _plan_env_oriels(vr, mask: Array, cw: int, ch: int) -> void:
	var spec = _plan_archetype.get("oriels", null)
	if spec == null or cw < 10 or ch < 8:
		return
	if _plan_env_circle != null or _plan_bailey != null or _plan_proc_suite != null:
		return
	if vr.randf() > float(spec.get("chance", 0.75)):
		return
	# Bottom-most inside cell per column.
	var bot = []
	for x in range(cw):
		var b = -1
		for y in range(ch):
			if mask[y * cw + x] == 1:
				b = y
		bot.append(b)
	for _t in range(int(spec.get("tries", 2))):
		# Flat segments of the south wall with 2 cells of room below.
		var segs = []
		var sx = 0
		while sx < cw:
			if bot[sx] < 0 or bot[sx] > ch - 3:
				sx += 1
				continue
			var se = sx
			while se + 1 < cw and bot[se + 1] == bot[sx]:
				se += 1
			if se - sx + 1 >= 4:
				segs.append([sx, se, bot[sx]])
			sx = se + 1
		if segs.empty():
			return
		var sg = segs[vr.randi_range(0, segs.size() - 1)]
		var bw2 = vr.randi_range(3, int(min(4, int(sg[1]) - int(sg[0]))))
		var bx = vr.randi_range(int(sg[0]), int(sg[1]) - bw2 + 1)
		var by = int(sg[2])
		_plan_fill_rect(mask, cw, ch, bx, by + 1, bw2, 2, 1)
		_plan_oriel_pts.append(Vector2(bx, by + 3))
		_plan_oriel_pts.append(Vector2(bx + bw2, by + 3))
		for x in range(bx, bx + bw2):
			bot[x] = by + 2
		if _plan_env_symx:
			var mx = cw - bx - bw2
			_plan_fill_rect(mask, cw, ch, mx, by + 1, bw2, 2, 1)
			_plan_oriel_pts.append(Vector2(mx, by + 3))
			_plan_oriel_pts.append(Vector2(mx + bw2, by + 3))
			for x in range(mx, mx + bw2):
				bot[x] = by + 2


# Processional envelope (temples): the SILHOUETTE follows the axial
# suite. The nave/chancel/sanctuary are sized first, then the footprint
# is just the suite plus a THIN ring of aisles (2-3 cells) and an
# optional transept - so however big the drawn area, the side rooms
# stay one modest crown of chapels instead of flooding the leftover
# space with dozens of rooms. The suite rects are stored for
# _plan_processional to reuse verbatim.
func _plan_env_suite(vr, mask: Array, cw: int, ch: int) -> void:
	# Upper church level: NO crown of side rooms at all - the suite and
	# its open alcoves are the whole building, plus at most one pair of
	# annexes (transept arms OR sacristies).
	var aisle = 0
	var axis = int(cw / 2)
	# Suite sized from the area, capped so the crown always fits.
	var nave_w = int(clamp(round(cw * (0.4 + vr.randf() * 0.12)), 3, cw - aisle * 2))
	if (nave_w % 2) != (cw % 2):
		nave_w = int(max(3, nave_w - 1))
	var chan_w = int(clamp(round(float(nave_w) * (0.62 + vr.randf() * 0.14)), 2, nave_w))
	var sanc_w = int(clamp(round(float(nave_w) * (0.6 + vr.randf() * 0.15)), 2, chan_w))
	if (nave_w % 2) != (chan_w % 2):
		chan_w += 1
	if (nave_w % 2) != (sanc_w % 2):
		sanc_w += 1
	# The apse is decided EARLY: its half-circle needs headroom above the
	# chevet, reserved from the height budget - an apse bulging outside
	# the generation area both crosses map edges and survives rerolls
	# (the raster restore only covers the area).
	var want_apse = vr.randf() < 0.6
	var apr_c = (float(sanc_w) + float(aisle) * 2.0) * 0.5
	var top_res = int(ceil(apr_c)) + 1 if want_apse else 0
	var avail_h = ch - 2 - aisle - top_res
	if avail_h < 9 and want_apse:
		want_apse = false
		top_res = 0
		avail_h = ch - 2 - aisle
	var nave_h = int(max(4, round(ch * (0.46 + vr.randf() * 0.08))))
	var chan_h = int(max(2, round(ch * (0.16 + vr.randf() * 0.05))))
	var sanc_h = int(max(2, round(ch * (0.12 + vr.randf() * 0.04))))
	var total_h = nave_h + chan_h + sanc_h
	if total_h > avail_h:
		nave_h = int(max(4, nave_h - (total_h - avail_h)))
		total_h = nave_h + chan_h + sanc_h
	if total_h > avail_h:
		chan_h = int(max(2, chan_h - (total_h - avail_h)))
		total_h = nave_h + chan_h + sanc_h
	if total_h > avail_h:
		sanc_h = int(max(2, sanc_h - (total_h - avail_h)))
	# Two cells at the bottom stay reserved for an optional porch.
	var yb = ch - 2
	var nave = Rect2(axis - int(nave_w / 2), yb - nave_h, nave_w, nave_h)
	var chan = Rect2(axis - int(chan_w / 2), nave.position.y - chan_h, chan_w, chan_h)
	var sanc = Rect2(axis - int(sanc_w / 2), chan.position.y - sanc_h, sanc_w, sanc_h)
	_plan_proc_suite = [nave, chan, sanc]
	# Porch: a small central projection on the facade. It is welded to
	# the NAVE room later (open vestibule), and the southernmost-wall
	# entrance rule lands the door on it naturally.
	if vr.randf() < 0.6:
		var pw = int(clamp(round(float(nave_w) * 0.4), 2, nave_w - 2))
		if (pw % 2) != (nave_w % 2):
			pw += 1
		_plan_proc_bumps.append(Rect2(axis - int(pw / 2), yb, pw, 2))
	# Side chapels: 1-3 SYMMETRIC pairs of shallow open alcoves bulging
	# out of the nave walls - never closed rooms (real churches), they
	# share the nave's room id.
	var n_pairs = vr.randi_range(1, 3)
	var used_y = []
	for _pc in range(n_pairs):
		var bd = 1 + (1 if vr.randf() < 0.35 else 0)
		var bl = vr.randi_range(2, 3)
		var byy = int(nave.position.y) + 1 + vr.randi_range(0, int(max(0, nave_h - bl - 3)))
		var clash = false
		for uy in used_y:
			if abs(byy - int(uy)) < bl + 1:
				clash = true
				break
		if clash:
			continue
		used_y.append(byy)
		_plan_proc_bumps.append(Rect2(int(nave.position.x) - bd, byy, bd, bl))
		_plan_proc_bumps.append(Rect2(int(nave.position.x) + nave_w, byy, bd, bl))
	for bp in _plan_proc_bumps:
		_plan_fill_rect(mask, cw, ch, int(bp.position.x), int(bp.position.y),
			int(bp.size.x), int(bp.size.y), 1)
	# Rounded apse capping the chevet: emitted as a half-circle arc
	# replacing the straight north wall. Center and radius come from the
	# REAL chevet edges, so the arc ends land exactly on the two side
	# wall corners whatever the parities.
	if want_apse:
		var chv_x0 = float(int(sanc.position.x) - aisle)
		var chv_w = float(sanc_w + aisle * 2)
		_plan_proc_apse = [chv_x0 + chv_w * 0.5,
			float(int(sanc.position.y) - aisle), chv_w * 0.5]
	# Footprint. The NAVE gets no side rooms at all: its side walls are
	# the exterior walls, as in real churches - closed rooms flanking
	# the nave are nearly nonexistent there. The crown of annexes only
	# wraps the chancel and the sanctuary (vestries behind the wings,
	# ambulatory around the apse).
	_plan_fill_rect(mask, cw, ch, int(nave.position.x), int(nave.position.y),
		int(nave.size.x), int(nave.size.y), 1)
	for pr in [chan, sanc]:
		_plan_fill_rect(mask, cw, ch, int(pr.position.x) - aisle, int(pr.position.y),
			int(pr.size.x) + aisle * 2, int(pr.size.y), 1)
	_plan_fill_rect(mask, cw, ch, int(sanc.position.x) - aisle, int(sanc.position.y) - aisle,
		int(sanc.size.x) + aisle * 2, int(sanc.size.y) + aisle, 1)
	# One pair of annexes maximum: transept arms (closed side rooms
	# flanking the crossing) OR a pair of small sacristies on the
	# chancel - keeping the upper level at 1-3 rooms beyond the suite.
	var annex_roll = vr.randf()
	if annex_roll < 0.55 and cw >= nave_w + 6:
		# Transept arms: wider, deeper and fancier than a plain bar -
		# optionally hammer-headed (a taller end block welded onto each
		# arm as an open extension) and optionally doubled (a second,
		# shorter pair further down the nave, cathedral style).
		var span = int((cw - nave_w) / 2)
		var grand = vr.randf() < 0.3
		var t_out = int(clamp(2 + vr.randi_range(0, 3), 2, span))
		var t_h = int(clamp(chan_h + vr.randi_range(0, 2), 2, int(max(2, nave_h - 2))))
		if grand:
			# Grandiose roll: the arms swallow most of the side span and
			# run deep along the nave.
			t_out = int(clamp(4 + vr.randi_range(0, 3), 2, span))
			t_h = int(clamp(chan_h + vr.randi_range(2, 4), 2, int(max(2, nave_h - 2))))
		var t_y = int(chan.position.y)
		var ta = Rect2(axis - int(nave_w / 2) - t_out, t_y, t_out, t_h + 1)
		var tb = Rect2(axis + int(nave_w / 2), t_y, t_out, t_h + 1)
		_plan_proc_annex.append([ta, "transept"])
		_plan_proc_annex.append([tb, "transept"])
		if t_out >= 3 and vr.randf() < 0.45:
			# Hammer heads: the arm ends grow taller end blocks, welded
			# open into the arm (one T-shaped room, not extra rooms).
			var hw = int(min(3 if grand else 2, t_out))
			var hh = int(min(t_h + (4 if grand else 3), nave_h))
			var hy = int(max(0, t_y - int((hh - t_h) / 2)))
			var ha = Rect2(int(ta.position.x), hy, hw, hh)
			var hb = Rect2(int(tb.position.x + tb.size.x) - hw, hy, hw, hh)
			_plan_fill_rect(mask, cw, ch, int(ha.position.x), int(ha.position.y),
				int(ha.size.x), int(ha.size.y), 1)
			_plan_fill_rect(mask, cw, ch, int(hb.position.x), int(hb.position.y),
				int(hb.size.x), int(hb.size.y), 1)
			_plan_proc_bumps.append(ha)
			_plan_proc_bumps.append(hb)
		if nave_h >= 9 and vr.randf() < 0.35:
			# Second, shorter pair further down the nave.
			var t2_out = int(clamp(t_out - 1, 2, span))
			var t2_h = int(max(2, t_h - 1))
			var t2_y = int(clamp(t_y + t_h + 3, 0, ch - t2_h - 3))
			_plan_proc_annex.append([Rect2(axis - int(nave_w / 2) - t2_out, t2_y, t2_out, t2_h), "transept"])
			_plan_proc_annex.append([Rect2(axis + int(nave_w / 2), t2_y, t2_out, t2_h), "transept"])
	elif annex_roll < 0.8 and cw >= chan_w + 6:
		var s_w = int(clamp(3, 2, int((cw - chan_w) / 2)))
		var s_h = int(max(2, chan_h))
		_plan_proc_annex.append([Rect2(int(chan.position.x) - s_w,
			int(chan.position.y), s_w, s_h), "sacristy"])
		_plan_proc_annex.append([Rect2(int(chan.position.x + chan.size.x),
			int(chan.position.y), s_w, s_h), "sacristy"])
	for ax2 in _plan_proc_annex:
		var ar2 = ax2[0]
		_plan_fill_rect(mask, cw, ch, int(ar2.position.x), int(ar2.position.y),
			int(ar2.size.x), int(ar2.size.y), 1)


# Largest axis-aligned rectangle fully inside the mask (histogram +
# stack, O(cells)). Returns null when the mask is empty.
func _plan_max_inscribed_rect(mask: Array, cw: int, ch: int):
	var heights = []
	for _x in range(cw):
		heights.append(0)
	var best = null
	var best_a = 0
	for y in range(ch):
		for x in range(cw):
			if mask[y * cw + x] == 1:
				heights[x] += 1
			else:
				heights[x] = 0
		var stack = []
		for x2 in range(cw + 1):
			var hcur = heights[x2] if x2 < cw else 0
			var start = x2
			while not stack.empty() and stack[stack.size() - 1][1] > hcur:
				var top = stack.pop_back()
				var aa = int(top[1]) * (x2 - int(top[0]))
				if aa > best_a:
					best_a = aa
					best = Rect2(int(top[0]), y - int(top[1]) + 1, x2 - int(top[0]), int(top[1]))
				start = int(top[0])
			stack.append([start, hcur])
	return best


# Generic one-room ANNEX bolted onto the silhouette (an inn's stable,
# a smithy's shed): a small rect glued flush to a straight stretch of
# the outline, filled into the mask and protected as its own room.
func _plan_generic_annex(vr, mask: Array, cw: int, ch: int) -> void:
	var spec = _plan_archetype.get("annex", null)
	if spec == null or vr.randf() > float(spec.get("chance", 0.0)):
		return
	for _try in range(10):
		var side = vr.randi_range(0, 3)
		var aw = vr.randi_range(3, 4)
		var ad = vr.randi_range(2, 3)
		var horiz = side <= 1
		var w2 = aw if horiz else ad
		var h2 = ad if horiz else aw
		var px = vr.randi_range(1, int(max(1, cw - w2 - 1)))
		var py = vr.randi_range(1, int(max(1, ch - h2 - 1)))
		# Slide toward the building until flush against a straight edge.
		var ok = false
		for _slide in range(int(max(cw, ch))):
			var free = true
			var touch = true
			for yy in range(py, py + h2):
				for xx in range(px, px + w2):
					if mask[yy * cw + xx] == 1:
						free = false
			var tx0 = px
			var ty0 = py
			if side == 0:
				ty0 = py + h2
			elif side == 1:
				ty0 = py - 1
			elif side == 2:
				tx0 = px + w2
			else:
				tx0 = px - 1
			for tt in range(aw):
				var txx = tx0 + (tt if horiz else 0)
				var tyy = ty0 + (0 if horiz else tt)
				if txx < 0 or txx >= cw or tyy < 0 or tyy >= ch \
						or mask[tyy * cw + txx] != 1:
					touch = false
					break
			if free and touch:
				ok = true
				break
			if not free:
				break
			if side == 0:
				py += 1
			elif side == 1:
				py -= 1
			elif side == 2:
				px += 1
			else:
				px -= 1
			if px < 1 or py < 1 or px + w2 > cw - 1 or py + h2 > ch - 1:
				break
		if ok:
			_plan_fill_rect(mask, cw, ch, px, py, w2, h2, 1)
			_plan_proc_annex.append([Rect2(px, py, w2, h2), String(spec.get("cat", "storage"))])
			return


# Walled-bailey footprint (castles): the INHABITED RING - buildings
# leaning against the curtain wall, 3-4 cells deep - around an EMPTY
# court (outside the mask, so truly empty), with the KEEP as one big
# axis-centered block against the north wall facing the GATEHOUSE that
# pierces the south ring. Everything mirror-symmetric on the axis; the
# corner towers come from the normal towers pass in symmetric pairs.
func _plan_env_bailey(vr, mask: Array, cw: int, ch: int) -> void:
	var big = int(min(cw, ch)) >= 17
	# Per-side ring thickness: the north (keep side) runs deeper, the
	# flanks stay lean - a curtain of even width reads like a diagram.
	var ring_n = 3 + (vr.randi_range(1, 2) if big else vr.randi_range(0, 1))
	var ring_s = 3 + (1 if big and vr.randf() < 0.5 else 0)
	var ring_ew = 3 + (1 if big and vr.randf() < 0.35 else 0)
	# Salients (mirror-paired bastions bulging OUT of the curtain) need
	# an inset so they have somewhere to bulge into.
	var want_sal = big and vr.randf() < 0.7
	var pad = 2 if want_sal else 0
	# Three curtain silhouettes: the plain quadrangle, a keep-end that
	# TAPERS by mirrored steps, or the classic TWIN-COURT castle (wide
	# outer bailey south, narrower inner bailey north, a central range
	# of rooms between the two courts).
	var shape_roll = vr.randf()
	var courts = []
	var court = Rect2()
	if shape_roll < 0.35 or int(min(cw, ch)) < 16:
		_plan_fill_rect(mask, cw, ch, pad, pad, cw - pad * 2, ch - pad * 2, 1)
		court = Rect2(pad + ring_ew, pad + ring_n,
			cw - (pad + ring_ew) * 2, ch - pad * 2 - ring_n - ring_s)
		courts = [court]
	elif shape_roll < 0.65:
		# Tapered: the north (keep) end narrows by 1-2 mirrored steps.
		var steps = 1 + (1 if vr.randf() < 0.5 and ch >= 22 else 0)
		var t_in = vr.randi_range(2, 3)
		_plan_fill_rect(mask, cw, ch, pad, pad, cw - pad * 2, ch - pad * 2, 1)
		var inn = ch - pad * 2
		for st in range(steps):
			var sy = pad + int(round(float(inn) * (0.2 + 0.16 * float(st))))
			var cut_w = t_in * (steps - st)
			_plan_fill_rect(mask, cw, ch, pad, pad, cut_w, sy - pad, 0)
			_plan_fill_rect(mask, cw, ch, cw - pad - cut_w, pad, cut_w, sy - pad, 0)
		var wa_t = t_in * steps
		court = Rect2(pad + wa_t + ring_ew, pad + ring_n,
			cw - (pad + wa_t + ring_ew) * 2, ch - pad * 2 - ring_n - ring_s)
		courts = [court]
	else:
		# Twin courts: narrow inner bailey (north) over a wide outer
		# bailey (south), a 2-3 deep central range dividing the courts.
		var wa = vr.randi_range(2, int(max(2, (cw - pad * 2) / 5)))
		var ys = pad + int(round(float(ch - pad * 2) * (0.5 + vr.randf() * 0.08)))
		_plan_fill_rect(mask, cw, ch, pad, ys, cw - pad * 2, ch - pad - ys, 1)
		_plan_fill_rect(mask, cw, ch, pad + wa, pad, cw - (pad + wa) * 2, ys - pad, 1)
		var mid_t = vr.randi_range(2, 3)
		var court_n = Rect2(pad + wa + ring_ew, pad + ring_n,
			cw - (pad + wa + ring_ew) * 2, ys - pad - ring_n - int(ceil(mid_t / 2.0)))
		var court_s = Rect2(pad + ring_ew, ys + int(floor(mid_t / 2.0)),
			cw - (pad + ring_ew) * 2,
			ch - pad - ring_s - ys - int(floor(mid_t / 2.0)))
		_plan_fill_rect(mask, cw, ch, int(court_n.position.x), int(court_n.position.y),
			int(court_n.size.x), int(court_n.size.y), 0)
		_plan_fill_rect(mask, cw, ch, int(court_s.position.x), int(court_s.position.y),
			int(court_s.size.x), int(court_s.size.y), 0)
		court = court_s
		courts = [court_n, court_s]
	if courts.size() == 1:
		_plan_fill_rect(mask, cw, ch, int(court.position.x), int(court.position.y),
			int(court.size.x), int(court.size.y), 0)
	if want_sal:
		# 1-2 mirror pairs on the flanks, plus sometimes one centered on
		# the north wall (a projecting chapel or rear tower block).
		var n_pairs = vr.randi_range(1, 2)
		var used_sy = []
		for _sp in range(n_pairs):
			var sh2 = vr.randi_range(3, 5)
			var sy = vr.randi_range(pad + 2, ch - pad - ring_s - sh2 - 2)
			var clash_s = false
			for uy in used_sy:
				if abs(sy - int(uy)) < sh2 + 2:
					clash_s = true
					break
			if clash_s:
				continue
			used_sy.append(sy)
			_plan_fill_rect(mask, cw, ch, 0, sy, pad + 1, sh2, 1)
			_plan_fill_rect(mask, cw, ch, cw - pad - 1, sy, pad + 1, sh2, 1)
		if vr.randf() < 0.5:
			var nw2 = vr.randi_range(4, 6)
			if (nw2 % 2) != (cw % 2):
				nw2 += 1
			_plan_fill_rect(mask, cw, ch, int(cw / 2) - int(nw2 / 2), 0, nw2, pad + 1, 1)
	# Keep: axis-centered against the NORTH ring, filling back into the
	# court. Sized to leave real courtyard on three sides.
	# THE ENFILADE COMES FIRST: a castle is its Great Hall + Throne Room
	# axis, everything else is built around it. The keep is sized to
	# host it - at least 6 deep (hall 2 + a square-or-longer throne
	# nave) whenever the court physically allows, the whole inner
	# bailey on twin-court plans.
	var kc = courts[0]
	var kw = int(clamp(round(kc.size.x * (0.38 + vr.randf() * 0.1)), 4, kc.size.x - 4))
	if (kw % 2) != (cw % 2):
		kw = int(max(4, kw - 1))
	var kh = 6
	if courts.size() > 1:
		# Twin courts: the keep runs THROUGH the central range and juts
		# its Great Hall 2-3 cells into the big south court, facing the
		# gatehouse - the hall is the castle's front door to the throne,
		# never buried behind other rooms.
		var cs = courts[1]
		var prow = 2 + (1 if vr.randf() < 0.5 else 0)
		kh = int(cs.position.y) + prow - int(kc.position.y)
		kh = int(min(kh, int(cs.position.y + cs.size.y) - 3 - int(kc.position.y)))
	else:
		# Single court: deep, but ALWAYS leaving 3+ cells of open court
		# in front of the hall doors.
		var kh_want = int(max(6, round(kc.size.y * (0.5 + vr.randf() * 0.1))))
		kh = int(min(kh_want, int(kc.size.y) - 3))
		if kh < 6:
			kh = int(min(6, int(kc.size.y) - 2))
	kh = int(max(3, kh))
	var keep = Rect2(int(cw / 2) - int(kw / 2), int(kc.position.y), kw, kh)
	_plan_fill_rect(mask, cw, ch, int(keep.position.x), int(keep.position.y),
		int(keep.size.x), int(keep.size.y), 1)
	# Gatehouse: an axis-centered passage room crossing the SOUTH ring.
	var gw = 2 if cw % 2 == 0 else 3
	if vr.randf() < 0.4:
		gw += 2
	gw = int(min(gw, int(court.size.x) - 2))
	var gate = Rect2(int(cw / 2) - int(gw / 2), int(court.position.y + court.size.y), gw, ring_s + pad)
	# Galleries (55%): one-cell corridors hugging the court on the east,
	# west and south sides of the ring - the rooms behind open onto the
	# gallery, the gallery onto the court.
	var galleries = []
	if vr.randf() < 0.55:
		galleries.append(Rect2(int(court.position.x) - 1, int(court.position.y),
			1, int(court.size.y) + 1))
		galleries.append(Rect2(int(court.position.x + court.size.x), int(court.position.y),
			1, int(court.size.y) + 1))
		galleries.append(Rect2(int(court.position.x) - 1, int(court.position.y + court.size.y),
			int(court.size.x) + 2, 1))
	_plan_bailey = {"court": court, "courts": courts, "keep": keep, "gate": gate,
		"ring": ring_s, "galleries": galleries}


# Open-network footprint (sewers, caves, mines): scattered chambers
# joined by L tunnels, connected as a tree plus optional extra loops.
# Nothing wraps the whole thing: the silhouette IS the network.
func _plan_env_network(vr, mask: Array, cw: int, ch: int) -> void:
	var net = _plan_archetype.get("net", {})
	var n0 = 5
	var n1 = 9
	if net.has("n"):
		n0 = int(net["n"][0])
		n1 = int(net["n"][1])
	var sz0 = 1
	var sz1 = 3
	if net.has("sz"):
		sz0 = int(net["sz"][0])
		sz1 = int(net["sz"][1])
	var tw = int(net.get("tw", 1))
	var loops = int(net.get("loops", 0))
	var longish = bool(net.get("long", false))
	# Built networks (sewers, mines): chamber positions snap to a coarse
	# grid so every tunnel and wall lands square; organic ones (caves)
	# keep free positions.
	var gstep = int(net.get("grid", 0))
	# Density texture: most chambers pack around a few cluster centers,
	# and a few outliers sit alone near the edges at the end of a single
	# long tunnel.
	var n_clusters = int(net.get("clusters", 0))
	var n_out = int(net.get("outliers", 0))
	var n = vr.randi_range(n0, n1)
	# Sparse mode ("spread"): chambers must NOT touch - the void between
	# them is what makes a dungeon read as isolated rooms strung on long
	# passages. Placement is rejection-sampled with a clearance margin,
	# chamber size scales with the sketch, and when nothing fits any
	# more the network simply stops growing.
	var sparse = bool(net.get("spread", false))
	var placed_rects = []
	var main_rects = []
	var base_mn = int(min(cw, ch))
	var cl_centers = []
	for _c in range(n_clusters):
		cl_centers.append(Vector2(vr.randi_range(int(cw * 0.25), int(cw * 0.75)),
			vr.randi_range(int(ch * 0.25), int(ch * 0.75))))
	var centers = []
	var out_placed = 0
	for _i in range(n):
		var rx = vr.randi_range(sz0, sz1)
		var ry = vr.randi_range(sz0, sz1)
		if sparse:
			rx = int(min(rx, int(max(1, base_mn / 9))))
			ry = int(min(ry, int(max(1, base_mn / 9))))
		var cx = 0
		var cy = 0
		var is_out = _i >= n - n_out and n_out > 0
		var tries = 1
		if sparse:
			tries = 40
		var ok_pos = false
		for _try in range(tries):
			if is_out:
				# Outlier: hugging one of the four borders.
				var side = vr.randi_range(0, 3)
				if side == 0:
					cx = vr.randi_range(rx + 1, int(max(rx + 1, cw / 5)))
					cy = vr.randi_range(ry + 1, ch - ry - 2)
				elif side == 1:
					cx = vr.randi_range(int(min(cw - rx - 2, cw * 4 / 5)), cw - rx - 2)
					cy = vr.randi_range(ry + 1, ch - ry - 2)
				elif side == 2:
					cx = vr.randi_range(rx + 1, cw - rx - 2)
					cy = vr.randi_range(ry + 1, int(max(ry + 1, ch / 5)))
				else:
					cx = vr.randi_range(rx + 1, cw - rx - 2)
					cy = vr.randi_range(int(min(ch - ry - 2, ch * 4 / 5)), ch - ry - 2)
			elif not cl_centers.empty():
				var cc4 = cl_centers[_i % cl_centers.size()]
				var spread = int(max(3, min(cw, ch) / 6))
				cx = int(clamp(int(cc4.x) + vr.randi_range(-spread, spread), rx + 1, cw - rx - 2))
				cy = int(clamp(int(cc4.y) + vr.randi_range(-spread, spread), ry + 1, ch - ry - 2))
			else:
				cx = vr.randi_range(rx + 1, cw - rx - 2)
				cy = vr.randi_range(ry + 1, ch - ry - 2)
			if gstep > 1:
				cx = int(clamp(int(round(float(cx) / gstep)) * gstep, rx + 1, cw - rx - 2))
				cy = int(clamp(int(round(float(cy) / gstep)) * gstep, ry + 1, ch - ry - 2))
			if not sparse:
				ok_pos = true
				break
			var cand = Rect2(cx - rx, cy - ry, rx * 2 + 1, ry * 2 + 1)
			var grown = cand.grow(float(tw + 2))
			var hit = false
			for pr in placed_rects:
				if grown.intersects(pr):
					hit = true
					break
			if not hit:
				ok_pos = true
				break
		if sparse and not ok_pos:
			break
		var ch_rects = [Rect2(cx - rx, cy - ry, rx * 2 + 1, ry * 2 + 1)]
		if sparse and rx >= 2 and ry >= 2 and vr.randf() < 0.45:
			# Varied chamber silhouettes: a second box unions in -
			# crosses, Ts and stepped masses instead of plain boxes.
			var rx2 = vr.randi_range(1, rx - 1)
			var ry2 = ry + vr.randi_range(1, 2)
			if vr.randf() < 0.5:
				rx2 = rx + vr.randi_range(1, 2)
				ry2 = vr.randi_range(1, ry - 1)
			var ox = vr.randi_range(-1, 1)
			var oy = vr.randi_range(-1, 1)
			var r2 = Rect2(cx + ox - rx2, cy + oy - ry2, rx2 * 2 + 1, ry2 * 2 + 1)
			var ok2 = r2.position.x >= 1 and r2.position.y >= 1 \
					and r2.position.x + r2.size.x <= cw - 1 \
					and r2.position.y + r2.size.y <= ch - 1
			if ok2:
				var grown2 = r2.grow(float(tw + 2))
				for pr in placed_rects:
					if grown2.intersects(pr):
						ok2 = false
						break
			if ok2:
				ch_rects.append(r2)
		for rc in ch_rects:
			_plan_fill_rect(mask, cw, ch, int(rc.position.x), int(rc.position.y),
				int(rc.size.x), int(rc.size.y), 1)
			placed_rects.append(rc)
		if sparse:
			_plan_net_chambers.append(ch_rects)
			main_rects.append(ch_rects[0])
		centers.append(Vector2(cx, cy))
		if is_out:
			out_placed += 1
	if sparse and centers.size() >= 2:
		# Topology after Dungeondraft's own DungeonGenerator: Delaunay
		# over the chamber centers, an MST guarantees one connected
		# whole, and a fraction of the remaining short Delaunay edges
		# re-loops - room degrees land naturally between 1 and 4.
		var pts = PoolVector2Array()
		for c5 in centers:
			pts.append(c5)
		var tris = Geometry.triangulate_delaunay_2d(pts)
		var edges = {}
		if tris.size() >= 3:
			for ti in range(0, tris.size() - 2, 3):
				for tj in range(3):
					var ea = int(tris[ti + tj])
					var eb = int(tris[ti + ((tj + 1) % 3)])
					var ke2 = [int(min(ea, eb)), int(max(ea, eb))]
					edges[ke2] = centers[ea].distance_to(centers[eb])
		else:
			# Degenerate layout (collinear...): complete graph fallback.
			for i2 in range(centers.size()):
				for j2 in range(i2 + 1, centers.size()):
					edges[[i2, j2]] = centers[i2].distance_to(centers[j2])
		var in_mst = {0: true}
		var mst_edges = []
		while in_mst.size() < centers.size():
			var best_d = 1e18
			var best_e = null
			for ke in edges:
				var a5 = int(ke[0])
				var b5 = int(ke[1])
				if in_mst.has(a5) == in_mst.has(b5):
					continue
				if float(edges[ke]) < best_d:
					best_d = float(edges[ke])
					best_e = ke
			if best_e == null:
				break
			mst_edges.append(best_e)
			in_mst[int(best_e[0])] = true
			in_mst[int(best_e[1])] = true
		var ratio = float(net.get("connect", 0.25))
		var maxlink = float(base_mn) * 0.8
		var used = {}
		for ke in mst_edges:
			used[ke] = true
			_plan_net_corridor(vr, mask, cw, ch, main_rects[int(ke[0])],
				main_rects[int(ke[1])], centers[int(ke[0])], centers[int(ke[1])], tw)
		for ke in edges:
			if used.has(ke):
				continue
			if float(edges[ke]) > maxlink:
				continue
			if vr.randf() < ratio:
				_plan_net_corridor(vr, mask, cw, ch, main_rects[int(ke[0])],
					main_rects[int(ke[1])], centers[int(ke[0])], centers[int(ke[1])], tw)
		return
	var n_core = centers.size() - out_placed
	for i in range(1, centers.size()):
		var j = vr.randi_range(0, i - 1)
		if i >= n_core:
			# Outliers hang alone at the end of ONE long tunnel to the
			# nearest core chamber: dead-end pockets, never re-looped.
			var bd0 = 1e18
			for j0 in range(int(max(1, n_core))):
				var d0 = centers[i].distance_to(centers[j0])
				if d0 < bd0:
					bd0 = d0
					j = j0
		elif longish:
			# Mines favor the FARTHEST previous chamber: long straight drifts.
			var bd = -1.0
			for j2 in range(i):
				var d2 = centers[i].distance_to(centers[j2])
				if d2 > bd:
					bd = d2
					j = j2
		_plan_net_tunnel(vr, mask, cw, ch, centers[i], centers[j], tw)
	for _l in range(loops):
		# Loops only among the core: the outliers keep their single access.
		if n_core < 3:
			break
		var a = vr.randi_range(0, n_core - 1)
		var b = vr.randi_range(0, n_core - 1)
		if a != b:
			_plan_net_tunnel(vr, mask, cw, ch, centers[a], centers[b], tw)


# One corridor between two chambers, Dungeondraft-style: when the rooms
# face each other across a gap, a single straight passage at a random
# position inside the shared span; otherwise the L-tunnel.
func _plan_net_corridor(vr, mask: Array, cw: int, ch: int, ra: Rect2, rb: Rect2, ca: Vector2, cb: Vector2, tw: int) -> void:
	var ax1 = int(ra.position.x + ra.size.x)
	var bx1 = int(rb.position.x + rb.size.x)
	var ay1 = int(ra.position.y + ra.size.y)
	var by1 = int(rb.position.y + rb.size.y)
	var ox0 = int(max(ra.position.x, rb.position.x)) + 1
	var ox1 = int(min(ax1, bx1)) - 1
	var oy0 = int(max(ra.position.y, rb.position.y)) + 1
	var oy1 = int(min(ay1, by1)) - 1
	if ox1 - ox0 >= tw:
		var cxx = vr.randi_range(ox0, ox1 - tw)
		var ys = int(min(ay1, by1))
		var ye = int(max(ra.position.y, rb.position.y))
		if ye > ys:
			_plan_fill_rect(mask, cw, ch, cxx, ys, tw, ye - ys, 1)
			return
	if oy1 - oy0 >= tw:
		var cyy = vr.randi_range(oy0, oy1 - tw)
		var xs = int(min(ax1, bx1))
		var xe = int(max(ra.position.x, rb.position.x))
		if xe > xs:
			_plan_fill_rect(mask, cw, ch, xs, cyy, xe - xs, tw, 1)
			return
	_plan_net_tunnel(vr, mask, cw, ch, ca, cb, tw)


func _plan_net_tunnel(vr, mask: Array, cw: int, ch: int, a: Vector2, b: Vector2, tw: int) -> void:
	# L path, horizontal-first or vertical-first at random.
	var mid = Vector2(b.x, a.y)
	if vr.randf() < 0.5:
		mid = Vector2(a.x, b.y)
	for pair in [[a, mid], [mid, b]]:
		var p0 = pair[0]
		var p1 = pair[1]
		var x0 = int(min(p0.x, p1.x))
		var x1 = int(max(p0.x, p1.x))
		var y0 = int(min(p0.y, p1.y))
		var y1 = int(max(p0.y, p1.y))
		_plan_fill_rect(mask, cw, ch, x0, y0, x1 - x0 + tw, y1 - y0 + tw, 1)


func _plan_mask_mirror(mask: Array, cw: int, ch: int, fx: bool, fy: bool) -> void:
	if not fx and not fy:
		return
	var src = mask.duplicate()
	for y in range(ch):
		for x in range(cw):
			var sx = x
			var sy = y
			if fx:
				sx = cw - 1 - x
			if fy:
				sy = ch - 1 - y
			mask[y * cw + x] = src[sy * cw + sx]


# ── Circulation ─────────────────────────────────────────────────────────────

# Processional axis (temples, churches): entrance at the bottom, then a
# telescoping suite of axis-centered rooms shrinking with depth - long
# NAVE, narrower CHANCEL, small SANCTUARY at the far end - exactly the
# anatomy of real temple plans. The nave is the "hall" (the entrance
# door targets it); side blocks become symmetric chapels and vestries
# through the comb + interior symmetry.
func _plan_processional(vr, mask: Array, cw: int, ch: int) -> Dictionary:
	var out = {"leaves": [], "cats": []}
	if _plan_proc_suite != null:
		# The envelope WAS built around this exact suite: reuse it. The
		# annexes ride along as protected single rooms - BSP would carve
		# each transept arm into 4-6 rooms otherwise.
		out["leaves"].append(_plan_proc_suite[0])
		out["cats"].append("hall")
		out["leaves"].append(_plan_proc_suite[1])
		out["cats"].append("chancel")
		out["leaves"].append(_plan_proc_suite[2])
		out["cats"].append("sanctuary")
		for ax3 in _plan_proc_annex:
			out["leaves"].append(ax3[0])
			out["cats"].append(String(ax3[1]))
		return out
	for axg in _plan_proc_annex:
		out["leaves"].append(axg[0])
		out["cats"].append(String(axg[1]))
	# Mask bounding box + axis.
	var x0 = cw
	var x1 = -1
	var y0 = ch
	var y1 = -1
	for y in range(ch):
		for x in range(cw):
			if mask[y * cw + x] == 1:
				x0 = int(min(x0, x))
				x1 = int(max(x1, x))
				y0 = int(min(y0, y))
				y1 = int(max(y1, y))
	if x1 < 0 or y1 - y0 < 7:
		return out
	var bw = x1 - x0 + 1
	var bh = y1 - y0 + 1
	var axis = x0 + int(bw / 2)
	# Depth split: nave ~50%, chancel ~22%, sanctuary ~15%, the rest of
	# the depth (behind the sanctuary) is left to the side blocks.
	var nave_h = int(max(3, round(bh * (0.48 + vr.randf() * 0.1))))
	var chan_h = int(max(2, round(bh * (0.16 + vr.randf() * 0.06))))
	var sanc_h = int(max(2, round(bh * (0.11 + vr.randf() * 0.05))))
	if nave_h + chan_h + sanc_h > bh - 1:
		sanc_h = int(max(2, bh - 1 - nave_h - chan_h))
	var nave_w = int(clamp(round(bw * (0.52 + vr.randf() * 0.12)), 3, bw))
	# The suite must be symmetric under the interior mirror (x -> cw-1-x):
	# widths share the parity of the (symmetric) mask, or the mirror
	# shaves one column off every axis room.
	if (nave_w % 2) != (bw % 2):
		nave_w = int(min(nave_w + 1, bw))
	var chan_w = int(clamp(round(float(nave_w) * (0.6 + vr.randf() * 0.15)), 2, nave_w))
	var sanc_w = int(clamp(round(float(nave_w) * (0.4 + vr.randf() * 0.12)), 2, chan_w))
	# Widths share the axis parity so all three stay perfectly centered.
	if (nave_w % 2) != (chan_w % 2):
		chan_w += 1
	if (nave_w % 2) != (sanc_w % 2):
		sanc_w += 1
	var yb = y1 + 1
	out["leaves"].append(Rect2(axis - int(nave_w / 2), yb - nave_h, nave_w, nave_h))
	out["cats"].append("hall")
	out["leaves"].append(Rect2(axis - int(chan_w / 2), yb - nave_h - chan_h, chan_w, chan_h))
	out["cats"].append("chancel")
	out["leaves"].append(Rect2(axis - int(sanc_w / 2), yb - nave_h - chan_h - sanc_h, sanc_w, sanc_h))
	out["cats"].append("sanctuary")
	return out


func _plan_circulation(vr, mask: Array, cw: int, ch: int, area: int) -> Dictionary:
	var out = {"leaves": [], "cats": []}
	if bool(_plan_archetype.get("cells_exact", false)):
		# Prison: BUILT, not carved. A guard room on the south edge, a
		# spine corridor running north (plus a cross corridor on wide
		# footprints), and rows of exact 3x2 stalls laid as protected
		# leaves along every corridor. The BSP only gets the leftovers:
		# a couple of service rooms, if there is room at all.
		var bx0 = cw
		var bx1 = -1
		var by0 = ch
		var by1 = -1
		for yq in range(ch):
			for xq in range(cw):
				if mask[yq * cw + xq] == 1:
					bx0 = int(min(bx0, xq))
					bx1 = int(max(bx1, xq))
					by0 = int(min(by0, yq))
					by1 = int(max(by1, yq))
		if bx1 < 0:
			return out
		var axq = int((bx0 + bx1 + 1) / 2) + vr.randi_range(-2, 2)
		axq = int(clamp(axq, bx0 + 2, bx1 - 2))
		var gw2 = 4
		var gh2 = 3
		var groom = null
		for _gt in range(2):
			for dx2 in range(int(max(cw, 1))):
				for sgn in [1, -1]:
					var gx = axq - int(gw2 / 2) + sgn * dx2
					var gy = by1 - gh2 + 1
					if gx < 0 or gx + gw2 > cw or gy < 0:
						continue
					var full_g = true
					for yg in range(gy, gy + gh2):
						for xg in range(gx, gx + gw2):
							if mask[yg * cw + xg] != 1:
								full_g = false
					if full_g:
						groom = Rect2(gx, gy, gw2, gh2)
						break
				if groom != null:
					break
			if groom != null:
				break
			gw2 = 3
		if groom == null:
			groom = Rect2(axq - 1, by1 - 2, 3, 3)
		out["leaves"].append(groom)
		out["cats"].append("hall")
		# The WHOLE footprint is cell block: a horizontal collector
		# corridor above the guard room, vertical spines every 7 cells
		# (the exact module: 3-deep stalls + corridor + 3-deep stalls),
		# stalls filling every column wall to wall. Services only ever
		# exist in the mask's odd scraps.
		var coly = int(groom.position.y) - 1
		var corrs = []
		# Vertical spines first (their stall rows dominate the look),
		# every 7 cells - the exact 3+1+3 module.
		# The Rooms Seed drives the grid phasing: spine offset, spacing
		# and collector pitch all vary per interior reroll, so two
		# floors of one prison lay their blocks differently.
		var vpitch = 7 + vr.randi_range(0, 1)
		var sx0 = bx0 + 3 + vr.randi_range(0, int(max(0, min(3, bx1 - bx0 - 7))))
		if bx1 - bx0 + 1 < 8:
			sx0 = int((bx0 + bx1) / 2)
		var sxx2 = sx0
		while sxx2 <= bx1 - 2:
			corrs.append(Rect2(sxx2, by0, 1, int(max(1, coly - by0 + 1))))
			sxx2 += vpitch
		# Then a LATTICE of horizontal collectors: one right above the
		# guard room, more stacked north every 5-7 cells - corridors
		# everywhere, every block of cells framed by them.
		var hpitch = 5 + vr.randi_range(0, 2)
		var yy2 = coly
		while yy2 >= by0:
			corrs.append(Rect2(bx0, yy2, bx1 - bx0 + 1, 1))
			yy2 -= hpitch
		for cr in corrs:
			out["leaves"].append(cr)
			out["cats"].append("corridor")
		var claimed = [groom]
		for cr2 in corrs:
			claimed.append(cr2)
		for ci4 in range(corrs.size()):
			var cr3 = corrs[ci4]
			var cvert = cr3.size.x <= cr3.size.y
			var alen = int(cr3.size.y if cvert else cr3.size.x)
			var st = 0
			while st < alen - 1:
				var got_any = false
				for sside in [-1, 1]:
					var sr = Rect2()
					if cvert:
						var sxx = int(cr3.position.x) + (1 if sside > 0 else -3)
						sr = Rect2(sxx, int(cr3.position.y) + st, 3, 2)
					else:
						var syy = int(cr3.position.y) + (1 if sside > 0 else -3)
						sr = Rect2(int(cr3.position.x) + st, syy, 2, 3)
					if sr.position.x < 0 or sr.position.y < 0 \
							or sr.position.x + sr.size.x > cw \
							or sr.position.y + sr.size.y > ch:
						continue
					var full_s = true
					for ys in range(int(sr.position.y), int(sr.position.y + sr.size.y)):
						for xs in range(int(sr.position.x), int(sr.position.x + sr.size.x)):
							if mask[ys * cw + xs] != 1:
								full_s = false
					if not full_s:
						continue
					var clash4 = false
					for cl in claimed:
						if sr.intersects(cl):
							clash4 = true
							break
					if clash4:
						continue
					claimed.append(sr)
					out["leaves"].append(sr)
					out["cats"].append("bedroom")
					got_any = true
				st += 2 if got_any else 1
		return out
	if _plan_bailey != null:
		# Castle. The keep splits into the GREAT HALL on the court side
		# (where the ceremonial double door lands) and a rear band of
		# noble rooms against the north curtain - Solar, Chapel, War
		# Room. Small keeps stay one hall. The gatehouse is a protected
		# passage room; the courtyard itself is the circulation,
		# optionally doubled by one-cell galleries hugging it. The gate
		# comes LAST so its cells override the south gallery.
		var keep = _plan_bailey["keep"]
		var kw2 = int(keep.size.x)
		var kh2 = int(keep.size.y)
		if kw2 >= 4 and kh2 >= 6:
			var bx = int(keep.position.x)
			var by = int(keep.position.y)
			if true:
				# The throne room is IMPOSING and runs DEEP: a nave at
				# least as long as it is wide, filling the keep from the
				# north curtain down to the hall, flanked by the noble
				# rooms when the keep is wide enough. The hall spans the
				# full width on the court side; a grand bay joins the
				# two volumes into near-one room.
				var hall_h2 = int(clamp(round(kh2 * (0.35 + vr.randf() * 0.08)), 2, 4))
				if kh2 - hall_h2 < 3:
					hall_h2 = int(max(2, kh2 - 3))
				var th2 = kh2 - hall_h2
				var wt = kw2
				var wf2 = 0
				if kw2 >= 8:
					wf2 = 2
					if kw2 >= 11 and vr.randf() < 0.5:
						wf2 = 3
					wt = kw2 - wf2 * 2
				if wf2 > 0:
					var fl2 = ["chapel", "family"]
					if vr.randf() < 0.5:
						fl2.invert()
					out["leaves"].append(Rect2(bx, by, wf2, th2))
					out["cats"].append(fl2[0])
					out["leaves"].append(Rect2(bx + wf2 + wt, by, wf2, th2))
					out["cats"].append(fl2[1])
				out["leaves"].append(Rect2(bx + wf2, by, wt, th2))
				out["cats"].append("living")
				out["leaves"].append(Rect2(bx, by + th2, kw2, hall_h2))
				out["cats"].append("hall")
		elif kw2 >= 5 and kh2 >= 5:
			var bx = int(keep.position.x)
			var by = int(keep.position.y)
			if true:
				var hall_h = int(clamp(round(kh2 * (0.5 + vr.randf() * 0.12)), 3, kh2 - 2))
				var back_h = kh2 - hall_h
				var n_back = 2
				if kw2 % 2 == 1 or (kw2 >= 9 and vr.randf() < 0.6):
					n_back = 3
				if n_back == 2:
					var w1 = int(kw2 / 2)
					var bc2 = ["family", "chapel"]
					if vr.randf() < 0.5:
						bc2.invert()
					out["leaves"].append(Rect2(bx, by, w1, back_h))
					out["cats"].append(bc2[0])
					out["leaves"].append(Rect2(bx + w1, by, kw2 - w1, back_h))
					out["cats"].append(bc2[1])
				else:
					var wc = int(max(2, round(kw2 * 0.4)))
					if (wc % 2) != (kw2 % 2):
						wc += 1
					wc = int(min(wc, kw2 - 2))
					var wf = int((kw2 - wc) / 2)
					var fc3 = ["family", "study"]
					if vr.randf() < 0.5:
						fc3.invert()
					out["leaves"].append(Rect2(bx, by, wf, back_h))
					out["cats"].append(fc3[0])
					out["leaves"].append(Rect2(bx + wf, by, wc, back_h))
					out["cats"].append("chapel")
					out["leaves"].append(Rect2(bx + wf + wc, by, kw2 - wf - wc, back_h))
					out["cats"].append(fc3[1])
				out["leaves"].append(Rect2(bx, by + back_h, kw2, hall_h))
				out["cats"].append("hall")
		else:
			out["leaves"].append(keep)
			out["cats"].append("hall")
		for gal in _plan_bailey.get("galleries", []):
			out["leaves"].append(gal)
			out["cats"].append("corridor")
		out["leaves"].append(_plan_bailey["gate"])
		out["cats"].append("gatehouse")
		return out
	if bool(_plan_archetype.get("processional", false)):
		return _plan_processional(vr, mask, cw, ch)
	if bool(_plan_archetype.get("axial_corridor", false)):
		# Crypt level. Three ingredients: (1) THE central gallery, 1-4
		# cells wide, running the whole axis - the backbone; (2) one
		# main ritual hall astride the gallery (the gallery flows in and
		# out of it); (3) zigzag side galleries branching off toward the
		# walls instead of straight full-width crossings.
		var bx0 = cw
		var bx1 = -1
		var by0 = ch
		var by1 = -1
		for y2 in range(ch):
			for x2 in range(cw):
				if mask[y2 * cw + x2] == 1:
					bx0 = int(min(bx0, x2))
					bx1 = int(max(bx1, x2))
					by0 = int(min(by0, y2))
					by1 = int(max(by1, y2))
		if bx1 < 0:
			return out
		var bw2 = bx1 - bx0 + 1
		var bh2 = by1 - by0 + 1
		var cor_w = 1 + vr.randi_range(0, 3)
		if (cor_w % 2) != (bw2 % 2):
			cor_w = int(clamp(cor_w + 1, 1, 4))
			if (cor_w % 2) != (bw2 % 2):
				cor_w = int(max(1, cor_w - 2))
		var cor_x = bx0 + int((bw2 - cor_w) / 2)
		out["leaves"].append(Rect2(cor_x, by0, cor_w, bh2))
		out["cats"].append("corridor")
		# Main hall astride the axis, biased toward the far (north) end -
		# the crypt under the choir. Appended AFTER the gallery so its
		# cells override it: the gallery enters and leaves the hall.
		var hall_w = int(clamp(round(bw2 * 0.4), cor_w + 2, bw2 - 2))
		if (hall_w % 2) != (bw2 % 2):
			hall_w = int(max(cor_w + 2, hall_w - 1))
		var hall_h = vr.randi_range(3, int(max(3, min(5, bh2 - 4))))
		var hall_y = by0 + int(round(float(bh2) * (0.12 + vr.randf() * 0.3)))
		hall_y = int(clamp(hall_y, by0 + 1, by1 - hall_h))
		out["leaves"].append(Rect2(bx0 + int((bw2 - hall_w) / 2), hall_y, hall_w, hall_h))
		out["cats"].append("hall")
		# Zigzag branches, mirror pairs: out from the gallery, a step up
		# or down, then on toward the wall.
		var n_br = int(clamp(bh2 / 5, 2, 4))
		for bi in range(n_br):
			var byy = by0 + 2 + int(round(float(bh2 - 5) * float(bi) / float(max(1, n_br - 1))))
			byy = int(clamp(byy, by0 + 1, by1 - 1))
			var h1 = vr.randi_range(2, 4)
			var vv = vr.randi_range(2, 3)
			var vdir = -1 if vr.randf() < 0.5 else 1
			var byy2 = int(clamp(byy + vdir * vv, by0 + 1, by1 - 1))
			var lx1 = cor_x - h1
			# left side: out, step, out to the wall
			out["leaves"].append(Rect2(lx1, byy, h1, 1))
			out["cats"].append("corridor")
			if byy2 != byy:
				out["leaves"].append(Rect2(lx1, int(min(byy, byy2)), 1, int(abs(byy2 - byy)) + 1))
				out["cats"].append("corridor")
			out["leaves"].append(Rect2(bx0, byy2, int(max(1, lx1 - bx0 + 1)), 1))
			out["cats"].append("corridor")
			# right side: exact mirror
			var rx0 = cor_x + cor_w
			out["leaves"].append(Rect2(rx0, byy, h1, 1))
			out["cats"].append("corridor")
			var rvx = rx0 + h1 - 1
			if byy2 != byy:
				out["leaves"].append(Rect2(rvx, int(min(byy, byy2)), 1, int(abs(byy2 - byy)) + 1))
				out["cats"].append("corridor")
			out["leaves"].append(Rect2(rvx, byy2, int(max(1, bx1 - rvx + 1)), 1))
			out["cats"].append("corridor")
		return out
	var hall_scale = float(_plan_archetype.get("hall_scale", 1.0))
	var hall_force = bool(_plan_archetype.get("hall_force", false))
	# Small houses have no hall: living / bedroom / kitchen / bathroom come
	# first, the hall only appears on larger builds. Landmark archetypes
	# (temple, market...) force theirs whatever the size.
	if area < 40 and not (hall_force and area >= 16):
		return out
	# Hall anchored to a boundary cell and extending INWARD: at least 2 cells
	# deep from the entrance wall, with normal room proportions.
	var boundary = []
	for i in range(cw * ch):
		if mask[i] != 1:
			continue
		var y = i / cw
		var x = i - y * cw
		for di in range(4):
			var nb = [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]][di]
			if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch \
					or mask[nb[1] * cw + nb[0]] == 0:
				boundary.append([x, y, di])
				break
	if boundary.empty():
		return out
	var hall = null
	var hall_centered = bool(_plan_archetype.get("hall_centered", false))
	if hall_centered and not boundary.empty():
		# Landmark axis: prefer the boundary cell closest to the middle of
		# the bottom edge (ceremonial entrance), so the big hall sits on
		# the central axis instead of a random corner.
		var bc = -1
		var bcs = 1e18
		for bi in range(boundary.size()):
			var bb = boundary[bi]
			var sc3 = abs(float(bb[0]) - cw * 0.5) + (float(ch) - float(bb[1])) * 0.35
			if sc3 < bcs:
				bcs = sc3
				bc = bi
		if bc > 0:
			# Move it to the front: the first try lands on the axis, the
			# random retries stay available as fallback.
			var bv = boundary[bc]
			boundary.remove(bc)
			boundary.push_front(bv)
	if bool(_plan_archetype.get("hall_rect", false)):
		# The common room is THE room: the biggest clean rectangle the
		# footprint can hold - long AND wide, zero narrow spots by
		# construction - trimmed toward ~40% of the floor area and a
		# sane aspect, keeping its south edge (the entrance side).
		var mr = _plan_max_inscribed_rect(mask, cw, ch)
		if mr != null and mr.size.x >= 3 and mr.size.y >= 3:
			var target = max(12.0, float(area) * 0.4)
			var flip = false
			while mr.size.x * mr.size.y > target * 1.15 \
					or max(mr.size.x, mr.size.y) > min(mr.size.x, mr.size.y) * 2.0:
				if mr.size.x >= mr.size.y and mr.size.x > 3:
					if flip:
						mr.position.x += 1
					mr.size.x -= 1
					flip = not flip
				elif mr.size.y > 3:
					mr.position.y += 1
					mr.size.y -= 1
				else:
					break
			hall = mr
	if hall == null:
		for _try in range(12):
			var b = boundary[vr.randi_range(0, boundary.size() - 1)]
			if hall_centered and _try == 0:
				b = boundary[0]
			var depth = vr.randi_range(2, 4)
			var width = vr.randi_range(2, 4)
			if area >= 100:
				depth = vr.randi_range(3, 5)
				width = vr.randi_range(3, 5)
			var spine = false
			if bool(_plan_archetype.get("grand_rooms", false)) and area >= 300 \
					and hall_centered and int(b[2]) >= 2:
				# MANOR SPINE: the hall is a deep axial slab running from
				# the facade toward the heart of the plan (the reference
				# marble halls), not just a big square room - sized
				# directly, hall_scale skipped.
				depth = int(clamp(round(float(ch) * 0.5), 5, 10))
				width = vr.randi_range(4, 5)
				spine = true
			if hall_scale > 1.0 and not spine:
				# Landmark room: the hall grows into THE room of the building
				# (sanctuary, market floor, great reading room...), capped so
				# it can still fit inside the mask.
				depth = int(clamp(round(depth * hall_scale), 2, max(2, ch - 2)))
				width = int(clamp(round(width * hall_scale), 2, max(2, cw - 2)))
			var hx = 0
			var hy = 0
			var hw = width
			var hh = depth
			if int(b[2]) == 0:
				# Entrance to the left: extend right.
				hx = int(b[0])
				hy = int(clamp(int(b[1]) - width / 2, 0, ch - width))
				hw = depth
				hh = width
			elif int(b[2]) == 1:
				hx = int(b[0]) - depth + 1
				hy = int(clamp(int(b[1]) - width / 2, 0, ch - width))
				hw = depth
				hh = width
			elif int(b[2]) == 2:
				hx = int(clamp(int(b[0]) - width / 2, 0, cw - width))
				hy = int(b[1])
			else:
				hx = int(clamp(int(b[0]) - width / 2, 0, cw - width))
				hy = int(b[1]) - depth + 1
			if hx < 0 or hy < 0 or hx + hw > cw or hy + hh > ch:
				continue
			var inside = 0
			for y in range(hy, hy + hh):
				for x in range(hx, hx + hw):
					if mask[y * cw + x] == 1:
						inside += 1
			if inside == hw * hh:
				hall = Rect2(hx, hy, hw, hh)
				break
	if hall != null and area < 36:
		out["leaves"].append(hall)
		out["cats"].append("hall")
		return out
	# Circulation archetype, gated by Corridor Density. One uniform width
	# per corridor NETWORK (corridors never widen or narrow along the way),
	# and parallel strips keep a spacing of 2+ so they can never glue into
	# multi-wide blobs.
	if area >= 36:
		var wd = 1
		var p_wide = 0.25
		if bool(_plan_archetype.get("grand_rooms", false)):
			# Manor hallways are GALLERIES: wide, furnishable.
			p_wide = 0.65
		if area >= 200 and vr.randf() < p_wide:
			wd = 2
		out["wd"] = wd
		var opts = [[1.0, "spine"], [0.7 + _plan_corr * 0.8, "branch"]]
		if hall != null and _plan_corr < 0.6:
			opts.append([0.9, "central"])
		if area < 120 and _plan_corr < 0.35:
			opts.append([1.2 - _plan_corr * 2.0, "hub"])
		if cw >= 12 and ch >= 12 and _plan_corr > 0.3:
			opts.append([0.3 + _plan_corr * 0.9, "ring"])
		# The archetype's circulation philosophy overrides the density-driven
		# grammar: a monastery IS a cloister ring, a hospital IS a spine,
		# whatever the sliders say. Only physical feasibility still gates.
		var acirc = _plan_archetype.get("circ", null)
		if area >= 300 and _plan_archetype.has("circ_large"):
			# Big builds change circulation philosophy: a cottage hubs
			# around its common room, a manor runs hallways.
			acirc = _plan_archetype.get("circ_large", acirc)
		if acirc != null:
			var cfeas = {"spine": true, "branch": true, "central": hall != null,
				"hub": true, "ring": cw >= 12 and ch >= 12}
			var aopts = []
			for ck in acirc:
				if bool(cfeas.get(String(ck), false)):
					aopts.append([float(acirc[ck]), String(ck)])
			if not aopts.empty():
				opts = aopts
		var total = 0.0
		for o in opts:
			total += float(o[0])
		var pick = vr.randf() * total
		var arch = "spine"
		for o in opts:
			pick -= float(o[0])
			if pick <= 0.0:
				arch = String(o[1])
				break
		var used_x = {}
		var used_y = {}
		if arch == "hub":
			# Modern living-room hub: no hall, no corridor.
			return out
		elif arch == "central":
			# The hall alone distributes.
			pass
		elif arch == "ring":
			var inset = int(clamp(min(cw, ch) / 3, 3, 8))
			out["leaves"].append(Rect2(inset, inset, cw - inset * 2, wd))
			out["cats"].append("corridor")
			out["leaves"].append(Rect2(inset, ch - inset - wd, cw - inset * 2, wd))
			out["cats"].append("corridor")
			out["leaves"].append(Rect2(inset, inset, wd, ch - inset * 2))
			out["cats"].append("corridor")
			out["leaves"].append(Rect2(cw - inset - wd, inset, wd, ch - inset * 2))
			out["cats"].append("corridor")
			used_x[inset] = true
			used_x[cw - inset - wd] = true
			used_y[inset] = true
			used_y[ch - inset - wd] = true
		else:
			# Spine (full crossings) or branch (spine + partial stubs).
			var base = 0
			if hall != null:
				if cw >= ch:
					base = int(clamp(hall.position.y + hall.size.y / 2 - wd / 2, 1, ch - 1 - wd))
				else:
					base = int(clamp(hall.position.x + hall.size.x / 2 - wd / 2, 1, cw - 1 - wd))
			elif cw >= ch:
				base = vr.randi_range(int(ch / 3), int(ch * 2 / 3))
			else:
				base = vr.randi_range(int(cw / 3), int(cw * 2 / 3))
			var horiz = cw >= ch
			if horiz:
				out["leaves"].append(Rect2(0, base, cw, wd))
				used_y[base] = true
			else:
				out["leaves"].append(Rect2(base, 0, wd, ch))
				used_x[base] = true
			out["cats"].append("corridor")
			# Supply scales hard with Corridor Density: near-zero at 0,
			# a dense network at 1.
			# Fixed candidate superset: every random draw below happens
			# WHATEVER the density, so moving the slider on the same seed
			# only activates/deactivates strips instead of reshuffling.
			var target = lerp(0.4, 2.0 + float(area) / 25.0, _plan_corr)
			var u_extra = vr.randf()
			var n_act = int(floor(target))
			if u_extra < target - floor(target):
				n_act += 1
			var cands3 = []
			for i in range(12):
				var vs = (i % 2 == 0) == horiz
				var pos = 0
				var plen = 3
				if vs:
					pos = vr.randi_range(2, int(max(2, cw - 2 - wd)))
					plen = vr.randi_range(3, int(max(3, cw / 2)))
				else:
					pos = vr.randi_range(2, int(max(2, ch - 2 - wd)))
					plen = vr.randi_range(3, int(max(3, ch / 2)))
				var pup = vr.randf()
				var pml = vr.randf()
				var pside = vr.randf()
				cands3.append([vs, pos, pup, pml, pside, plen])
			var made = 0
			for cnd in cands3:
				if made >= n_act:
					break
				var vs2 = bool(cnd[0])
				var pos2 = int(cnd[1])
				if vs2:
					var okx = true
					for k in used_x:
						if abs(pos2 - int(k)) <= wd + 1:
							okx = false
							break
					if not okx:
						continue
					used_x[pos2] = true
					if arch == "branch" and horiz:
						if float(cnd[2]) < 0.5:
							out["leaves"].append(Rect2(pos2, 0, wd, base + wd))
						else:
							out["leaves"].append(Rect2(pos2, base, wd, ch - base))
						if float(cnd[3]) < _plan_corr * 0.5:
							var ey = 0
							if float(cnd[2]) >= 0.5:
								ey = ch - 1
							var lx0 = pos2
							if float(cnd[4]) < 0.5:
								lx0 = int(max(0, pos2 - int(cnd[5]) + 1))
							out["leaves"].append(Rect2(lx0, ey, int(cnd[5]), 1))
							out["cats"].append("corridor")
					else:
						out["leaves"].append(Rect2(pos2, 0, wd, ch))
				else:
					var oky = true
					for k in used_y:
						if abs(pos2 - int(k)) <= wd + 1:
							oky = false
							break
					if not oky:
						continue
					used_y[pos2] = true
					if arch == "branch" and not horiz:
						if float(cnd[2]) < 0.5:
							out["leaves"].append(Rect2(0, pos2, base + wd, wd))
						else:
							out["leaves"].append(Rect2(base, pos2, cw - base, wd))
						if float(cnd[3]) < _plan_corr * 0.5:
							var ex = 0
							if float(cnd[2]) >= 0.5:
								ex = cw - 1
							var ly0 = pos2
							if float(cnd[4]) < 0.5:
								ly0 = int(max(0, pos2 - int(cnd[5]) + 1))
							out["leaves"].append(Rect2(ex, ly0, 1, int(cnd[5])))
							out["cats"].append("corridor")
					else:
						out["leaves"].append(Rect2(0, pos2, cw, wd))
				out["cats"].append("corridor")
				made += 1
	# The hall is painted LAST: painting it first let the corridor spine
	# cut it in two, producing several "Hall" rooms.
	if hall != null and _plan_env_symx:
		# Symmetric envelope: the hall snaps onto the exact axis so the
		# centered entrance lands on it (kept only if the recentred rect
		# still fits inside the footprint).
		var chx = int(round((float(cw) - hall.size.x) * 0.5))
		if chx != int(hall.position.x):
			var okc = true
			for y in range(int(hall.position.y), int(hall.position.y + hall.size.y)):
				for x in range(chx, chx + int(hall.size.x)):
					if x < 0 or x >= cw or mask[y * cw + x] != 1:
						okc = false
						break
				if not okc:
					break
			if okc:
				hall.position.x = chx
	if hall != null and bool(_plan_archetype.get("grand_stair", false)) \
			and area >= int(_plan_archetype.get("stair_min_area", 300)):
		# MONUMENTAL STAIRCASE: a stair block glued to the hall's far
		# (north) end on the axis, facing the entrance - painted before
		# the hall so the hall wins any overlap.
		var sw2 = int(clamp(int(hall.size.x) - 2, 2, 4))
		var sx2 = int(round(hall.position.x + (hall.size.x - float(sw2)) * 0.5))
		var sy2 = int(hall.position.y) - 2
		if sy2 >= 0:
			var oks = true
			for y in range(sy2, sy2 + 2):
				for x in range(sx2, sx2 + sw2):
					if x < 0 or x >= cw or mask[y * cw + x] != 1:
						oks = false
						break
				if not oks:
					break
			if oks:
				out["leaves"].append(Rect2(sx2, sy2, sw2, 2))
				out["cats"].append("staircase")
	if hall != null:
		out["leaves"].append(hall)
		out["cats"].append("hall")
	return out


# ── Room irregularity ───────────────────────────────────────────────────────

func _plan_l_transfers(vr, rooms: Array, mask: Array, cw: int, ch: int, protected: Dictionary) -> void:
	# Transfers a corner quadrant of a room to an adjacent room: both become
	# L-shaped. Skips circulation.
	var infos = _plan_room_infos(rooms, cw, ch)
	for r in infos:
		if protected.has(int(r)):
			continue
		var inf = infos[r]
		if int(inf["cells"]) < 6 or inf["bw"] < 3 or inf["bh"] < 3:
			continue
		if vr.randf() > _plan_room_irr * 0.9:
			continue
		var qw = vr.randi_range(1, int(max(1, inf["bw"] / 2)))
		var qh = vr.randi_range(1, int(max(1, inf["bh"] / 2)))
		var corner = vr.randi_range(0, 3)
		var qx = int(inf["x0"])
		var qy = int(inf["y0"])
		if corner == 1 or corner == 3:
			qx = int(inf["x1"]) - qw + 1
		if corner == 2 or corner == 3:
			qy = int(inf["y1"]) - qh + 1
		# The quadrant must belong entirely to the room.
		var ok = true
		for y in range(qy, qy + qh):
			for x in range(qx, qx + qw):
				if rooms[y * cw + x] != int(r):
					ok = false
					break
			if not ok:
				break
		if not ok:
			continue
		# Receiver: the adjacent room sharing the most border with it.
		var borders = {}
		for y in range(qy, qy + qh):
			for x in range(qx, qx + qw):
				for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
					if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
						continue
					if nb[0] >= qx and nb[0] < qx + qw and nb[1] >= qy and nb[1] < qy + qh:
						continue
					var o = rooms[nb[1] * cw + nb[0]]
					if o >= 0 and o != int(r) and not _plan_corr_ids.has(int(o)):
						borders[o] = int(borders.get(o, 0)) + 1
		var best = -1
		var best_n = 0
		for o in borders:
			if int(borders[o]) > best_n:
				best_n = int(borders[o])
				best = o
		if best < 0:
			continue
		for y in range(qy, qy + qh):
			for x in range(qx, qx + qw):
				rooms[y * cw + x] = best


func _plan_interior_chamfers(vr, rooms: Array, mask: Array, runs: Array, cw: int, ch: int, acx: int, acy: int, out_segs: Array) -> void:
	# 45-degree chamfers on interior convex corners (a room's corner poking
	# into another room). Reuses the exterior bevel machinery.
	var corners = []
	for py in range(ch + 1):
		for px in range(cw + 1):
			var ids = []
			for c in [[px - 1, py - 1], [px, py - 1], [px - 1, py], [px, py]]:
				var v = -1
				if c[0] >= 0 and c[0] < cw and c[1] >= 0 and c[1] < ch and mask[c[1] * cw + c[0]] == 1:
					v = rooms[c[1] * cw + c[0]]
				ids.append(v)
			if ids[0] < 0 or ids[1] < 0 or ids[2] < 0 or ids[3] < 0:
				continue
			# Exactly one cell belongs to a different room than the 3 others.
			for k in range(4):
				var solo = ids[k]
				var others = []
				for j in range(4):
					if j != k:
						others.append(ids[j])
				if others[0] == others[1] and others[1] == others[2] and others[0] != solo:
					corners.append({"p": Vector2(px, py), "cell": k})
					break
	_plan_shuffle(vr, corners)
	var count = _plan_sround(vr, _plan_room_irr * float(corners.size()) * 0.8)
	for i in range(int(min(count, corners.size()))):
		var csize = 1
		if vr.randf() < _plan_room_irr * 0.4:
			csize = 2
		_plan_bevel_corner(vr, runs, corners[i], acx, acy, out_segs, csize, "int")


# Finds the run covering [span0, span1) on the given lattice line with no
# hole overlapping that span, or null.
func _plan_find_solid_run(runs: Array, vert: bool, line: int, span0: int, span1: int, ignore_openings: bool = false, wall_kind: String = ""):
	# Wall solidity across COLLINEAR runs: exterior runs are segmented
	# per interior room, so a span often crosses several runs - coverage
	# is checked on their union, or tower/bevel decisions would depend
	# on the Rooms Seed. With ignore_openings, door/open/window holes
	# don't break solidity (only structural cuts do).
	var need = []
	for c in range(span0, span1):
		need.append(false)
	var first = null
	for run in runs:
		if bool(run["vert"]) != vert:
			continue
		if wall_kind != "" and String(run["kind"]) != wall_kind:
			continue
		var r0 = 0
		var r1 = 0
		if vert:
			if int(run["x"]) != line:
				continue
			r0 = int(run["y0"])
			r1 = int(run["y1"])
		else:
			if int(run["y"]) != line:
				continue
			r0 = int(run["x0"])
			r1 = int(run["x1"])
		var o0 = int(max(span0, r0))
		var o1 = int(min(span1, r1))
		if o1 <= o0:
			continue
		for h in run["holes"]:
			var ht = String(h[2])
			if ignore_openings and (ht == "door" or ht == "open" or ht == "window"):
				continue
			var ha = float(r0) + float(h[0])
			var hb = ha + float(h[1])
			if ha < float(o1) and hb > float(o0):
				return null
		if first == null:
			first = run
		for c2 in range(o0, o1):
			need[c2 - span0] = true
	for c3 in need:
		if not c3:
			return null
	return first

func _plan_room_infos(rooms: Array, cw: int, ch: int) -> Dictionary:
	var infos = {}
	for i in range(cw * ch):
		var r = rooms[i]
		if r < 0:
			continue
		var y = i / cw
		var x = i - y * cw
		if not infos.has(r):
			infos[r] = {"cells": 0, "x0": x, "x1": x, "y0": y, "y1": y}
		var inf = infos[r]
		inf["cells"] = int(inf["cells"]) + 1
		inf["x0"] = int(min(int(inf["x0"]), x))
		inf["x1"] = int(max(int(inf["x1"]), x))
		inf["y0"] = int(min(int(inf["y0"]), y))
		inf["y1"] = int(max(int(inf["y1"]), y))
	for r in infos:
		var inf = infos[r]
		inf["bw"] = int(inf["x1"]) - int(inf["x0"]) + 1
		inf["bh"] = int(inf["y1"]) - int(inf["y0"]) + 1
	return infos


# ── Category assignment (Traditional profile) ──────────────────────────────

# Which side of the zoning axis a room sits on: +1 / -1, or 0 when it
# straddles the midline. The axis is the building's LONG side.
func _plan_wz_side(inf, axis_x: bool, mid: float) -> float:
	var c = 0.0
	if axis_x:
		c = (float(inf["x0"]) + float(inf["x1"])) * 0.5
	else:
		c = (float(inf["y0"]) + float(inf["y1"])) * 0.5
	if c > mid + 0.5:
		return 1.0
	if c < mid - 0.5:
		return -1.0
	return 0.0


func _plan_adjacent_pairs(rooms: Array, cw: int, ch: int) -> Dictionary:
	var pairs = {}
	for y in range(ch):
		for x in range(cw):
			var r = rooms[y * cw + x]
			if r < 0:
				continue
			for nb in [[x + 1, y], [x, y + 1]]:
				if nb[0] >= cw or nb[1] >= ch:
					continue
				var o = rooms[nb[1] * cw + nb[0]]
				if o >= 0 and o != r:
					pairs[str(int(min(r, o))) + "_" + str(int(max(r, o)))] = true
	return pairs


func _plan_is_adjacent(pairs: Dictionary, a: int, b: int) -> bool:
	return pairs.has(str(int(min(a, b))) + "_" + str(int(max(a, b))))


func _plan_assign_categories(vr, rooms: Array, cw: int, ch: int, circ_cat: Dictionary) -> Dictionary:
	var cats = {}
	for k in circ_cat:
		cats[int(k)] = String(circ_cat[k])
	var infos = _plan_room_infos(rooms, cw, ch)
	var pairs = _plan_adjacent_pairs(rooms, cw, ch)
	var hall_id = -1
	for k in cats:
		if cats[k] == "hall":
			hall_id = int(k)
	# Spatial features for gravity-driven assignment: exterior boundary
	# cells and hop depth from the hall (or the most exposed room).
	var ext_cells = {}
	var adj_lists = {}
	for i in range(cw * ch):
		var r0 = rooms[i]
		if r0 < 0:
			continue
		var y0 = i / cw
		var x0 = i - y0 * cw
		for nb in [[x0 - 1, y0], [x0 + 1, y0], [x0, y0 - 1], [x0, y0 + 1]]:
			var o0 = -1
			if nb[0] >= 0 and nb[0] < cw and nb[1] >= 0 and nb[1] < ch:
				o0 = rooms[nb[1] * cw + nb[0]]
			if o0 < 0:
				ext_cells[r0] = int(ext_cells.get(r0, 0)) + 1
			elif o0 != r0:
				if not adj_lists.has(r0):
					adj_lists[r0] = {}
				adj_lists[r0][o0] = true
	var depth_of = {}
	var seed_room = hall_id
	if seed_room < 0:
		var best_ext = -1
		for r0 in infos:
			if int(ext_cells.get(int(r0), 0)) > best_ext:
				best_ext = int(ext_cells.get(int(r0), 0))
				seed_room = int(r0)
	if seed_room >= 0:
		var dq = [seed_room]
		depth_of[seed_room] = 0
		var dqi = 0
		while dqi < dq.size():
			var cur = dq[dqi]
			dqi += 1
			if adj_lists.has(cur):
				for o0 in adj_lists[cur]:
					if not depth_of.has(int(o0)):
						depth_of[int(o0)] = int(depth_of[cur]) + 1
						dq.append(int(o0))
	var free = []
	for r in infos:
		if not cats.has(int(r)):
			free.append(int(r))
	if free.empty():
		return cats
	# Manual sort by size desc (sort_custom cannot capture the infos dict).
	for i in range(free.size()):
		for j in range(i + 1, free.size()):
			if int(infos[free[j]]["cells"]) > int(infos[free[i]]["cells"]):
				var tmp = free[i]
				free[i] = free[j]
				free[j] = tmp
	# Living room: the biggest; a hall-adjacent candidate only takes it when
	# nearly as big, and a facade-backed candidate beats a landlocked one.
	var living = free[0]
	if hall_id >= 0:
		for i in range(int(min(3, free.size()))):
			if _plan_is_adjacent(pairs, free[i], hall_id) \
					and float(infos[free[i]]["cells"]) >= float(infos[free[0]]["cells"]) * 0.85:
				living = free[i]
				break
	if int(ext_cells.get(living, 0)) == 0:
		for i in range(int(min(3, free.size()))):
			if int(ext_cells.get(free[i], 0)) > 0 \
					and float(infos[free[i]]["cells"]) >= float(infos[free[0]]["cells"]) * 0.85:
				living = free[i]
				break
	cats[living] = "living"
	free.erase(living)
	var program = _plan_archetype.get("program", null)
	# Small home: bedrooms first, then kitchen, then bathroom. Archetype
	# programs skip this residential shortcut: their wishlist handles
	# small builds too.
	if free.size() <= 4 and program == null:
		var bed_first = false
		var kitchen_done = false
		var bath_done = false
		for r in free:
			var cells = int(infos[r]["cells"])
			if cells <= 2:
				cats[r] = _plan_tiny_cat(vr, cells)
			elif not bed_first:
				cats[r] = "bedroom"
				bed_first = true
			elif not kitchen_done:
				cats[r] = "kitchen"
				kitchen_done = true
			elif cells <= 6 and not bath_done:
				cats[r] = "bathroom"
				bath_done = true
			else:
				cats[r] = "bedroom"
		return cats
	# WING ZONING (House & Manor): on large builds the service rooms
	# (kitchen, pantry, stores, laundry, servants) cluster in one wing
	# and the private rooms (bedrooms, baths) in the other, receptions
	# staying around the hall. The wing axis follows the building's
	# long side; which end is the service end is rolled per building.
	var wz_on = bool(_plan_archetype.get("wing_zoning", false)) \
			and not _plan_small_mode and free.size() >= 6
	var wz_axis_x = true
	var wz_mid = 0.0
	var wz_service = 1.0
	if wz_on:
		var bx0 = cw
		var bx1 = 0
		var by0 = ch
		var by1 = 0
		for r0 in infos:
			bx0 = int(min(bx0, int(infos[r0]["x0"])))
			bx1 = int(max(bx1, int(infos[r0]["x1"])))
			by0 = int(min(by0, int(infos[r0]["y0"])))
			by1 = int(max(by1, int(infos[r0]["y1"])))
		wz_axis_x = (bx1 - bx0) >= (by1 - by0)
		if wz_axis_x:
			wz_mid = float(bx0 + bx1) * 0.5
		else:
			wz_mid = float(by0 + by1) * 0.5
		if vr.randf() < 0.5:
			wz_service = -1.0
	# Companion pair (kitchen + dining by default): an adjacent pair among
	# the next candidates. Programs choose their own pair or none at all.
	var pair_cats = ["kitchen", "dining"]
	var want_pair = true
	if program != null:
		var pp = program.get("pair", null)
		if pp == null:
			want_pair = false
		else:
			pair_cats = [String(pp[0]), String(pp[1])]
	if want_pair and free.size() >= 2:
		# Under wing zoning every candidate pair in the window is scored
		# (both members on the service side wins); otherwise the first
		# adjacent pair is taken as before.
		var done = false
		var best_pi = -1
		var best_pj = -1
		var best_ps = -1000.0
		for i in range(int(min(4, free.size()))):
			for j in range(i + 1, int(min(5, free.size()))):
				if _plan_is_adjacent(pairs, free[i], free[j]):
					done = true
					if not wz_on:
						best_pi = i
						best_pj = j
						break
					var ps = _plan_wz_side(infos[free[i]], wz_axis_x, wz_mid) * wz_service \
							+ _plan_wz_side(infos[free[j]], wz_axis_x, wz_mid) * wz_service \
							+ vr.randf() * 0.2
					if ps > best_ps:
						best_ps = ps
						best_pi = i
						best_pj = j
			if done and not wz_on:
				break
		if done:
			var a = free[best_pi]
			var b = free[best_pj]
			# The kitchen takes the service-most of the two.
			if wz_on and _plan_wz_side(infos[b], wz_axis_x, wz_mid) * wz_service \
					> _plan_wz_side(infos[a], wz_axis_x, wz_mid) * wz_service:
				var tswap = a
				a = b
				b = tswap
			cats[a] = pair_cats[0]
			cats[b] = pair_cats[1]
			free.erase(a)
			free.erase(b)
		if not done:
			cats[free[0]] = pair_cats[0]
			free.remove(0)
			if not free.empty():
				cats[free[0]] = pair_cats[1]
				free.remove(0)
	elif want_pair and free.size() == 1:
		cats[free[0]] = pair_cats[0]
		free.remove(0)
	# Tiered wishlist driven by the house size (standard house, large family
	# home, mansion): each room takes the first pending wish matching its
	# size class. This replaces the old bathroom/storage alternation that
	# flooded big buildings.
	var n_total = free.size() + 3
	var wish = []
	if program != null:
		# The archetype's room program IS the wishlist: served in order by
		# the same gravity fill below (facades, depth, private clustering).
		# On SMALL buildings only the essentials survive: an archetype's
		# wish_small (e.g. an inn's kitchen + stores) replaces the full
		# program - no bunk room squeezing out the pantry.
		var wl = program.get("wish", [])
		if _plan_small_mode and program.has("wish_small"):
			wl = program.get("wish_small", wl)
		for pw in wl:
			wish.append([String(pw[0]), String(pw[1])])
	# [category, size class] with L: >14 cells, M: 7-14, S: 3-6.
	if program == null:
		wish.append(["bedroom", "M"])
		wish.append(["bathroom", "S"])
		wish.append(["bedroom", "M"])
		wish.append(["study", "M"])
		wish.append(["laundry", "S"])
		wish.append(["pantry", "S"])
		wish.append(["bedroom", "M"])
		wish.append(["bathroom", "S"])
		wish.append(["storage", "S"])
		if n_total >= 10:
			wish.push_front(["library", "L"])
			wish.append(["office", "M"])
			wish.append(["guest", "M"])
			wish.append(["workshop", "M"])
			wish.append(["bathroom", "S"])
			wish.append(["storage", "S"])
		if n_total >= 16:
			wish.push_front(["game", "L"])
			wish.push_front(["ballroom", "L"])
			wish.append(["music", "M"])
			wish.append(["gallery", "L"])
			wish.append(["gym", "M"])
			wish.append(["wine", "S"])
			wish.append(["servants", "M"])
			wish.append(["theater", "M"])
			wish.append(["lounge", "M"])
			wish.append(["breakfast", "S"])
	# Gravity-driven fill: wishes are served in order and each picks the
	# BEST remaining room for its category (facade lovers get facades,
	# service rooms sink inside, private rooms cluster deep and together).
	var overflow = ["craft", "hobby", "sewing", "linen", "coat", "laundry", "pantry"]
	var ov_i = 0
	var master_done = false
	var privates = []
	var pending = []
	for r in free:
		if int(infos[r]["cells"]) <= 2:
			cats[r] = _plan_tiny_cat(vr, int(infos[r]["cells"]))
		else:
			pending.append(r)
	for w in wish:
		if pending.empty():
			break
		var wcat = String(w[0])
		var wcls = String(w[1])
		var grp = _plan_cat_group(wcat)
		var best_r = -1
		var best_s = -1000000.0
		for r in pending:
			var cells = int(infos[r]["cells"])
			var cls = "S"
			if cells > 14:
				cls = "L"
			elif cells > 6:
				cls = "M"
			var sc = 0.0
			if cls == wcls:
				sc += 6.0
			elif (cls == "L" and wcls == "M") or (cls == "M" and wcls == "S") \
					or (cls == "M" and wcls == "L") or (cls == "S" and wcls == "M"):
				sc += 2.0
			else:
				continue
			var has_ext = int(ext_cells.get(r, 0)) > 0
			var d = int(depth_of.get(r, 1))
			if grp == "living" or grp == "dining" or grp == "bedroom" \
					or grp == "study" or grp == "kitchen":
				if has_ext:
					sc += 3.0
			elif grp == "storage" or grp == "closet":
				if not has_ext:
					sc += 2.5
			if grp == "bedroom" or grp == "bathroom":
				sc += float(d) * 0.8
				for pr in privates:
					if _plan_is_adjacent(pairs, r, pr):
						sc += 1.5
						if sc > 1000.0:
							break
			elif grp == "living" or grp == "kitchen" or grp == "dining":
				sc -= float(d) * 0.6
			if wz_on:
				# Service wing pull / private wing pull. "servants" lives
				# in the bedroom behavior group but is a service room.
				var side = _plan_wz_side(infos[r], wz_axis_x, wz_mid)
				if wcat == "servants" or wcat == "laundry" \
						or grp == "kitchen" or grp == "storage":
					sc += side * wz_service * 2.2
				elif grp == "bedroom" or grp == "bathroom":
					sc -= side * wz_service * 2.2
			sc += vr.randf() * 0.3
			if sc > best_s:
				best_s = sc
				best_r = r
		if best_r < 0:
			continue
		var cat_pick = wcat
		if cat_pick == "bedroom" and not master_done and n_total >= 8 and program == null:
			# Programs name their master explicitly; auto-promotion would
			# steal the first repeated cell/ward/dormitory.
			cat_pick = "master"
			master_done = true
		cats[best_r] = cat_pick
		var gsel = _plan_cat_group(cat_pick)
		if gsel == "bedroom" or gsel == "bathroom" or gsel == "closet":
			privates.append(best_r)
		pending.erase(best_r)
	# Leftovers. With a program: EVERY leftover becomes the archetype's
	# signature repeated room (cells, wards, dormitories, storage bays) -
	# the repetition is the identity. Without: deep rooms become bedrooms,
	# small ones rotate a diverse overflow pool.
	if program != null:
		var rep = program.get("repeat", ["bedroom", "M"])
		for r in pending:
			cats[r] = String(rep[0])
			privates.append(r)
	else:
		for r in pending:
			var cells2 = int(infos[r]["cells"])
			if cells2 > 6:
				var cp = "bedroom"
				if not master_done and n_total >= 8:
					cp = "master"
					master_done = true
				cats[r] = cp
				privates.append(r)
			else:
				cats[r] = String(overflow[ov_i % overflow.size()])
				ov_i += 1
	# Master fixups: a master bedroom requires a normal bedroom somewhere,
	# and a planned ensuite (master adjacent to the ONLY bathroom) requires
	# a second bathroom elsewhere.
	var master_r = -1
	var plain_beds = 0
	var baths = []
	for k2 in cats:
		var raw3 = String(cats[k2])
		if raw3 == "master":
			master_r = int(k2)
		elif _plan_cat_group(raw3) == "bedroom":
			plain_beds += 1
		if _plan_cat_group(raw3) == "bathroom":
			baths.append(int(k2))
	if master_r >= 0 and plain_beds == 0:
		cats[master_r] = "bedroom"
		master_r = -1
	# The master is always the biggest bedroom: swap with a bigger one.
	if master_r >= 0 and infos.has(master_r):
		var biggest = master_r
		for k4 in cats:
			if _plan_cat_group(String(cats[k4])) == "bedroom" and infos.has(int(k4)) \
					and int(infos[int(k4)]["cells"]) > int(infos[biggest]["cells"]):
				biggest = int(k4)
		if biggest != master_r:
			cats[master_r] = String(cats[biggest])
			cats[biggest] = "master"
			master_r = biggest
	if master_r >= 0 and baths.size() == 1 and _plan_is_adjacent(pairs, master_r, baths[0]):
		var conv = ["storage", "laundry", "closet", "linen", "coat", "craft", "hobby", "sewing", "pantry"]
		var done_conv = false
		for pass_adj in [false, true]:
			if done_conv:
				break
			for k3 in cats:
				if not infos.has(int(k3)):
					continue
				if conv.has(String(cats[k3])) \
						and int(infos[int(k3)]["cells"]) >= 2 \
						and (_plan_is_adjacent(pairs, int(k3), master_r) == pass_adj):
					cats[k3] = "bathroom"
					done_conv = true
					break
	# HALL GUARANTEE: hall_force archetypes always get their hall. When
	# the circulation could not seat one (thin-armed small footprints),
	# the biggest ordinary room is promoted to hall - the entrance,
	# window, kitchen-adjacency and open-circulation passes all follow
	# the category.
	if bool(_plan_archetype.get("hall_force", false)):
		var has_hall = false
		for rh in cats:
			if _plan_cat_group(String(cats[rh])) == "hall":
				has_hall = true
				break
		if not has_hall:
			var infos_g = _plan_room_infos(rooms, cw, ch)
			var big = -1
			var bigc = 0
			for rg in cats:
				if circ_cat.has(int(rg)):
					continue
				if not infos_g.has(int(rg)):
					continue
				var cg = int(infos_g[int(rg)]["cells"])
				if cg > bigc:
					bigc = cg
					big = int(rg)
			if big >= 0:
				cats[big] = "hall"
	return cats


func _plan_get_font():
	var theme = Global.get("Theme")
	if theme != null and theme.default_font != null:
		return theme.default_font
	if _tool_panel != null and is_instance_valid(_tool_panel):
		var f = _tool_panel.get_font("font", "Label")
		if f != null:
			return f
	return null


# Labels are rendered by scaling DOWN a large font: scaling a 14 px theme
# font up gives the pixelated look.
func _plan_get_font_big():
	if _plan_big_font != null:
		return _plan_big_font
	var f = _plan_get_font()
	if f == null:
		return null
	if f is DynamicFont:
		var d = f.duplicate()
		d.size = 60
		_plan_big_font = d
	else:
		_plan_big_font = f
	return _plan_big_font


func _update_labels_overlay() -> void:
	if _labels_item == null or not is_instance_valid(_labels_item):
		return
	var show = _map_data != null and bool(_map_data["visible"])
	_labels_item.visible = show
	if show:
		_labels_item.update()


# Live mapping of a label center while a selection floats: same transform
# the commit will apply, so labels visually follow the box.
func _lbl_live_transform(lp: Vector2):
	if _sel == null or not _sel_floating() or bool(_sel.get("copy", false)):
		return null
	var src = _sel["rect_tex"]
	var src_pos = src.position / _tex_scale
	var src_size = src.size / _tex_scale
	if lp.x < src_pos.x or lp.y < src_pos.y \
			or lp.x > src_pos.x + src_size.x or lp.y > src_pos.y + src_size.y:
		return null
	var src_c = src_pos + src_size * 0.5
	var wsc = _sel_sprite_scale() * _tex_scale
	var rot = float(_sel["rot"])
	var rel = lp - src_c
	return {"p": _sel["center"] + Vector2(rel.x * wsc.x, rel.y * wsc.y).rotated(rot),
		"rot": rot, "s": (wsc.x + wsc.y) * 0.5}


# Effective scale and rotation of a label: generated room labels fit
# their room box, free Text-tool labels carry an explicit pixel size
# (the shared font is 60 px).
func _lbl_metrics(lb: Dictionary, sz: Vector2) -> Array:
	var rot = float(lb.get("ang", 0.0))
	var sc = 1.0
	if bool(lb.get("free", false)) or not lb.has("w"):
		sc = float(lb.get("s", 1.0)) * float(lb.get("px", 60.0)) / 60.0
	else:
		var w = float(lb["w"])
		var h = float(lb["h"])
		# Pick the orientation that fits best (vertical suits corridors).
		var sc_h = min(h * 0.3 / sz.y, (w * 0.85) / sz.x)
		var sc_v = min(w * 0.3 / sz.y, (h * 0.85) / sz.x)
		if sc_v > sc_h * 1.2:
			rot -= PI * 0.5
			sc = sc_v
		else:
			sc = sc_h
		sc = min(sc, 1.1)
		sc *= float(lb.get("s", 1.0))
	return [sc, rot]


func _draw_labels(item) -> void:
	if _map_data == null:
		return
	var sk = _active_sketch()
	if sk == null or not sk.has("labels"):
		return
	var f = _plan_get_font_big()
	if f == null:
		return
	var show_gen = _plan_labels or (_tool_active and _mode == MODE_TEXT)
	var editing = -1
	if _txt_target is int and _txt_edit != null and is_instance_valid(_txt_edit) and _txt_edit.visible:
		editing = int(_txt_target)
	for li in range(sk["labels"].size()):
		var lb = sk["labels"][li]
		if li == editing:
			# The inline editor floats over it.
			continue
		if not bool(lb.get("free", false)) and not show_gen:
			# Room Labels OFF hides the GENERATED labels only: manual
			# texts stay.
			continue
		var txt = String(lb["t"])
		var sz = f.get_string_size(txt)
		if sz.x < 1.0 or sz.y < 1.0:
			continue
		var met = _lbl_metrics(lb, sz)
		var sc = float(met[0])
		var rot = float(met[1])
		var lpos = Vector2(float(lb["x"]), float(lb["y"]))
		var live = _lbl_live_transform(lpos)
		if live != null:
			lpos = live["p"]
			rot += float(live["rot"])
			sc *= float(live["s"])
		if sc <= 0.02:
			continue
		if _tool_active and (_mode == MODE_TEXT or _mode == MODE_PLAN) \
				and (li == _txt_sel or li == _lbl_hover):
			# Back to the IDENTITY transform first: the previous
			# label's transform is still active here, and warped every
			# highlight but the first one off-screen.
			item.draw_set_transform(Vector2(), 0.0, Vector2(1, 1))
			# Rotated selection RECTANGLE, same look as the Patch text
			# mods: thin blue box (hover: translucent white).
			var hw2 = sz.x * 0.5 * sc + 10.0
			var hh2 = sz.y * 0.55 * sc + 8.0
			var rcol = Color(0.25, 0.65, 1.0, 0.9) if li == _txt_sel else Color(1, 1, 1, 0.55)
			var cors = []
			for cv in [Vector2(-hw2, -hh2), Vector2(hw2, -hh2), Vector2(hw2, hh2), Vector2(-hw2, hh2)]:
				cors.append(lpos + cv.rotated(rot))
			if li == _txt_sel:
				item.draw_colored_polygon(PoolVector2Array(cors), Color(1, 1, 1, 0.06))
			for ci in range(4):
				item.draw_line(cors[ci], cors[(ci + 1) % 4], rcol, 1.5, true)
		item.draw_set_transform(lpos, rot, Vector2(sc, sc))
		var lcol = LABEL_COLOR
		if lb.has("col"):
			lcol = Color(String(lb["col"]))
		# Faux bold: the theme font has no bold face, a 1px double draw does.
		item.draw_string(f, Vector2(-sz.x * 0.5, sz.y * 0.3), txt, lcol)
		item.draw_string(f, Vector2(-sz.x * 0.5 + 1.2, sz.y * 0.3), txt, lcol)
		item.draw_string(f, Vector2(-sz.x * 0.5, sz.y * 0.3 + 1.2), txt, lcol)
	item.draw_set_transform(Vector2(), 0.0, Vector2(1, 1))


# ============================================================================
# Architectural archetypes
# ============================================================================
# One archetype = one architectural personality: slider presets (footprint
# oddity, room sizes, density, corridors, towers) plus a full renaming of
# the generated room categories, so the same engine produces a castle, a
# monastery or a sewer network with a recognizable identity.
#
# "labels" keys are either a category ("master", "wine") or a behavior
# group ("bedroom", "storage"): lookup goes category first, then the
# category's group, then the default residential name. "no_windows"
# strips every window from the emitted plan (underground archetypes).
const PLAN_ARCHETYPES = [
	{"id": "custom", "name": "Custom", "desc": "No preset: the sliders are yours."},
	{"id": "random", "name": "Random", "desc": "Rolls a random archetype (Custom included) at every generation."},
	{"id": "house", "name": "House & Manor",
		"desc": "Family dwelling: a hall you walk into, receptions around it, kitchen and stores in a service wing, bedrooms in the other.",
		"shapes": {"rect": 0.45, "L": 0.9, "D": 0.3, "T": 0.5, "U": 0.5, "wings": 0.8,
			"Z": 0.25, "J": 0.2, "Y": 0.2, "H": 0.7, "cross": 0.9, "courtyard": 0.35,
			"pavilions": 1.0},
		"massing": true,
		"sym_large": {"axis": "x", "chance": 0.55},
		"hall_force": true, "hall_scale": 1.5, "hall_entrance": true, "hall_centered": true,
		"open_circ": true, "bridge_corridors": true,
		"wing_zoning": true, "grand_rooms": true, "shapes_by_size": true,
		"grand_stair": true, "enfilade": true, "service_door": true,
		"accrete": {"bumps": 3, "notch": 0.6},
		"oriels": {"tries": 2, "chance": 0.75},
		"circ": {"hub": 1.0, "central": 0.5},
		"circ_large": {"branch": 1.0, "spine": 0.5, "ring": 0.35},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["lounge", "M"], ["master", "M"], ["study", "M"], ["pantry", "S"],
				["bathroom", "S"], ["storage", "S"], ["servants", "M"], ["library", "M"],
				["nursery", "M"], ["laundry", "S"], ["bathroom", "S"], ["wine", "S"]],
			"wish_small": [["pantry", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 2, "max": 8, "cpx": 0.55, "corr": 0.35, "orig": 0.45, "irr": 0.1, "towers": 0},
		"labels": {"hall": "Entrance Hall", "storage": "Cellar", "closet": "Nook",
			"pantry": "Pantry", "laundry": "Laundry", "wine": "Wine Cellar",
			"servants": "Servants' Room"}},
	{"id": "farm", "hidden": true, "name": "Farmstead",
		"desc": "Working farm: big barn spaces next to small living quarters, rambling outline.",
		"shapes": {"L": 1.0, "wings": 0.8, "rect": 0.4},
		"circ": {"hub": 1.0, "branch": 0.4},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["storage", "L"], ["workshop", "M"], ["bedroom", "M"], ["pantry", "S"],
				["laundry", "S"], ["bedroom", "M"], ["wine", "S"], ["bathroom", "S"]],
			"repeat": ["storage", "M"]},
		"sliders": {"min": 3, "max": 9, "cpx": 0.35, "corr": 0.15, "orig": 0.45, "irr": 0.3, "towers": 0},
		"labels": {"hall": "Farmyard Entry", "living": "Hearth Room", "dining": "Farm Kitchen",
			"kitchen": "Scullery", "study": "Tool Shed", "workshop": "Workshop",
			"storage": "Barn", "pantry": "Grain Store", "larder": "Smokehouse",
			"wine": "Root Cellar", "laundry": "Washhouse", "bedroom": "Bedroom",
			"servants": "Farmhand's Room", "closet": "Feed Store", "bathroom": "Privy",
			"gallery": "Hayloft", "ballroom": "Threshing Floor", "gym": "Stable"}},
	{"id": "inn", "name": "Inn & Tavern",
		"desc": "One big common room you walk straight into, kitchen and stores at hand, guest rooms beyond.",
		"shapes": {"L": 1.0, "Z": 0.8, "T": 0.8, "U": 0.6, "J": 0.6, "wings": 0.5, "H": 0.4, "courtyard": 0.4, "rect": 0.3},
		"hall_force": true, "hall_scale": 2.6, "hall_entrance": true, "hall_rect": true,
		"comb": [2, 3], "uniform_w": 3.0, "repeat_cluster": 1.2,
		"open_circ": true, "bridge_corridors": true, "kitchen_by_hall": true,
		"annex": {"cat": "stable", "chance": 0.45},
		"circ": {"branch": 1.0, "spine": 0.7},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["kitchen", "M"], ["storage", "M"], ["dorm", "L"], ["pantry", "S"],
				["wine", "S"], ["master", "M"], ["servants", "M"], ["lounge", "M"],
				["storage", "S"], ["bathroom", "S"], ["office", "S"]],
			"wish_small": [["storage", "M"], ["pantry", "S"]],
			"repeat": ["bedroom", "S"]},
		"sliders": {"min": 2, "max": 7, "cpx": 0.55, "corr": 0.5, "orig": 0.75, "irr": 0.1, "towers": 0},
		"labels": {"hall": "Common Room", "living": "Taproom", "dining": "Dining Nook",
			"lounge": "Snug", "sitting": "Card Room", "game": "Game Room", "family": "Snug",
			"kitchen": "Kitchen", "pantry": "Pantry", "wine": "Ale Cellar",
			"larder": "Cold Store", "breakfast": "Buttery", "bedroom": "Guest Room",
			"master": "Innkeeper's Room", "guest": "Guest Room",
			"servants": "Staff Quarters", "nursery": "Family Room", "bathroom": "Washroom",
			"study": "Private Booth", "office": "Innkeeper's Office", "storage": "Storeroom",
			"closet": "Linen Store", "workshop": "Brewery", "craft": "Brewing Room",
			"dorm": "Bunk Room", "stable": "Stable",
			"laundry": "Washhouse", "music": "Stage Corner", "corridor": "Hallway",
			"staircase": "Staircase"}},
	{"id": "manor", "hidden": true, "name": "Manor",
		"desc": "Country estate: reception rooms, private wing, service wing, one modest tower.",
		"shapes": {"rect": 0.5, "L": 0.6, "T": 0.5, "U": 0.6, "wings": 0.5},
		"circ": {"central": 0.7, "spine": 0.6, "branch": 0.5},
		"sliders": {"min": 3, "max": 10, "cpx": 0.5, "corr": 0.45, "orig": 0.5, "irr": 0.3, "towers": 1}},
	{"id": "palace", "hidden": true, "name": "Palace",
		"desc": "Grand ceremonial residence: vast state rooms, long galleries, stately symmetry.",
		"shapes": {"H": 1.0, "U": 0.8, "cross": 0.4, "courtyard": 0.6, "wings": 0.4},
		"hall_force": true, "hall_scale": 1.6,
		"sym": "x", "hall_centered": true,
		"circ": {"central": 1.2, "spine": 0.3},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["ballroom", "L"], ["gallery", "L"], ["music", "M"], ["lounge", "M"],
				["sitting", "M"], ["library", "M"], ["study", "M"], ["master", "M"],
				["guest", "M"], ["office", "M"], ["servants", "M"], ["nursery", "M"],
				["theater", "M"], ["wine", "S"], ["bathroom", "S"], ["bathroom", "S"]],
			"repeat": ["guest", "M"]},
		"sliders": {"min": 4, "max": 14, "cpx": 0.45, "corr": 0.55, "orig": 0.55, "irr": 0.2, "towers": 2},
		"labels": {"hall": "Grand Foyer", "living": "Throne Room", "family": "Royal Salon",
			"sitting": "Antechamber", "lounge": "Drawing Room", "ballroom": "Grand Ballroom",
			"gallery": "Hall of Mirrors", "music": "Music Salon", "theater": "Court Theater",
			"dining": "State Dining Hall", "breakfast": "Morning Room",
			"bedroom": "Royal Apartment", "master": "King's Chamber", "guest": "Ambassador's Suite",
			"nursery": "Royal Nursery", "servants": "Servants' Wing", "bathroom": "Royal Bath",
			"study": "Council Chamber", "office": "Chancellery", "library": "Royal Library",
			"kitchen": "Great Kitchen", "storage": "Treasury", "wine": "Royal Cellar",
			"closet": "Wardrobe", "staircase": "Grand Staircase", "corridor": "Gallery"}},
	{"id": "castle", "name": "Castle & Keep",
		"desc": "Fortified seat of power: great hall, barracks, armory, many towers, irregular walls.",
		"shapes": {"bailey": 1.0},
		"sym": "x",
		"comb": [3, 4], "comb_serve": true,
		"circ": {"branch": 1.0},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["storage", "M"], ["workshop", "M"], ["study", "M"], ["servants", "M"],
				["master", "M"], ["storage", "M"], ["family", "M"], ["guest", "M"],
				["wine", "S"], ["pantry", "S"], ["bathroom", "S"]],
			"repeat": ["guest", "M"]},
		"sliders": {"min": 3, "max": 8, "cpx": 0.4, "corr": 0.3, "orig": 0.35, "irr": 0.1, "towers": 6},
		"labels": {"hall": "Great Hall", "gatehouse": "Gatehouse", "chapel": "Chapel",
			"corridor": "Passage", "living": "Throne Room",
			"family": "Solar", "sitting": "Antechamber", "lounge": "Lord's Parlor",
			"ballroom": "Great Chamber", "gallery": "Long Gallery", "music": "Minstrels' Gallery",
			"game": "Trophy Room", "gym": "Training Hall", "theater": "Court Stage",
			"dining": "Feast Hall", "breakfast": "Buttery", "kitchen": "Kitchen",
			"pantry": "Pantry", "larder": "Larder", "wine": "Undercroft",
			"bedroom": "Chamber", "master": "Lord's Chamber", "guest": "Knight's Quarters",
			"nursery": "Children's Chamber", "servants": "Servants' Quarters",
			"bathroom": "Garderobe", "study": "War Room", "office": "Steward's Office",
			"library": "Scriptorium", "workshop": "Smithy", "craft": "Fletcher's Room",
			"sewing": "Weaving Room", "storage": "Armory", "laundry": "Washhouse",
			"mudroom": "Guard Post", "closet": "Alcove", "staircase": "Stairwell"}},
	{"id": "keep", "hidden": true, "name": "Keep & Fortress",
		"desc": "Compact military stronghold: thick practical rooms, garrison life, corner towers.",
		"shapes": {"rect": 1.0, "courtyard": 0.5, "D": 0.3},
		"circ": {"spine": 0.8, "branch": 0.6},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["gym", "L"], ["storage", "M"], ["study", "M"], ["master", "M"],
				["bedroom", "M"], ["office", "M"], ["workshop", "M"], ["storage", "M"],
				["bedroom", "M"], ["pantry", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 3, "max": 10, "cpx": 0.55, "corr": 0.5, "orig": 0.5, "irr": 0.25, "towers": 4},
		"labels": {"hall": "Gatehouse Hall", "corridor": "Passage", "living": "Mess Hall",
			"family": "Officers' Mess", "dining": "Mess Hall", "kitchen": "Field Kitchen",
			"bedroom": "Barracks Room", "master": "Commander's Quarters", "guest": "Officer's Room",
			"servants": "Recruits' Bunks", "bathroom": "Latrine", "study": "Map Room",
			"office": "Quartermaster's Office", "library": "Records Room", "workshop": "Smithy",
			"storage": "Armory", "pantry": "Rations Store", "wine": "Powder Store",
			"closet": "Kit Store", "staircase": "Stairwell", "gym": "Drill Hall",
			"gallery": "Wall Walk", "game": "Guard Room"}},
	{"id": "watchtower", "hidden": true, "name": "Watchtower",
		"desc": "Small garrison post: a handful of stacked rooms and lookout towers.",
		"shapes": {"rect": 1.0, "D": 0.5},
		"circ": {"hub": 1.0},
		"program": {"pair": null,
			"wish": [["kitchen", "S"], ["dining", "S"], ["study", "M"], ["master", "M"],
				["storage", "M"], ["pantry", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 2, "max": 6, "cpx": 0.5, "corr": 0.3, "orig": 0.3, "irr": 0.2, "towers": 3},
		"labels": {"hall": "Guard Room", "living": "Watch Room", "dining": "Mess",
			"kitchen": "Cookfire", "bedroom": "Bunks", "master": "Sergeant's Room",
			"study": "Signal Room", "storage": "Armory", "pantry": "Rations",
			"bathroom": "Latrine", "closet": "Kit Store", "staircase": "Stairwell",
			"corridor": "Walkway"}},
	{"id": "barracks", "hidden": true, "name": "Barracks",
		"desc": "Garrison housing: repeated dormitories on a strong corridor spine.",
		"shapes": {"rect": 1.0, "H": 0.4, "U": 0.4},
		"comb": [2, 3], "comb_serve": true,
		"circ": {"spine": 1.0},
		"program": {"pair": null,
			"wish": [["dining", "L"], ["kitchen", "M"], ["gym", "L"], ["master", "M"],
				["study", "M"], ["storage", "M"], ["bathroom", "S"], ["bathroom", "S"],
				["storage", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 3, "max": 8, "cpx": 0.7, "corr": 0.7, "orig": 0.25, "irr": 0.15, "towers": 1},
		"labels": {"hall": "Muster Hall", "corridor": "Corridor", "living": "Mess Hall",
			"dining": "Mess Hall", "kitchen": "Kitchen", "bedroom": "Dormitory",
			"master": "Captain's Quarters", "guest": "Officer's Room", "servants": "Recruits' Bunks",
			"bathroom": "Washroom", "study": "Duty Office", "storage": "Armory",
			"closet": "Kit Store", "gym": "Drill Hall", "staircase": "Stairwell"}},
	{"id": "prison", "name": "Prison & Barracks",
		"desc": "Controlled circulation: rows of identical cells on a central block corridor, a guard room you enter through, mess and barracks for the garrison.",
		"shapes": {"rect": 0.8, "L": 0.5, "T": 0.5, "H": 0.6, "courtyard": 0.4},
		"hall_entrance": true,
		"open_circ": true,
		"uniform_w": 3.0, "repeat_cluster": 1.4, "cells_exact": true,
		"seal_chance": 0.08,
		"circ": {"spine": 1.0, "ring": 0.3},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["dorm", "L"], ["armory", "M"], ["study", "M"], ["office", "S"],
				["master", "M"], ["nursery", "M"], ["storage", "S"], ["wine", "S"],
				["bathroom", "S"]],
			"wish_small": [["armory", "S"], ["office", "S"]],
			"repeat": ["bedroom", "S"]},
		"sliders": {"min": 2, "max": 6, "cpx": 0.8, "corr": 0.85, "orig": 0.25, "irr": 0.0, "towers": 2},
		"labels": {"hall": "Guard Room", "corridor": "Cell Block", "living": "Common Cell",
			"dining": "Mess Hall", "kitchen": "Mess Kitchen", "bedroom": "Cell",
			"dorm": "Barracks", "master": "Warden's Quarters", "guest": "Cell",
			"servants": "Guard Quarters", "bathroom": "Latrines",
			"study": "Interrogation Room", "office": "Records Office",
			"nursery": "Infirmary", "armory": "Armory", "storage": "Supply Room",
			"pantry": "Rations Store",
			"wine": "Oubliette", "closet": "Shackle Store", "workshop": "Smithy",
			"laundry": "Wash Room", "gym": "Exercise Yard", "staircase": "Stairwell"}},
	{"id": "temple", "name": "Church & Temple (Upper)",
		"desc": "Ceremonial axis: one vast sanctuary, processional spaces, minimal clutter.",
		"shapes": {"suite": 1.0},
		"hall_force": true, "hall_scale": 2.2,
		"sym": "x", "sym_interior": true, "hall_centered": true,
		"processional": true, "single_entrance": true,
		"circ": {"central": 1.0},
		"program": {"pair": null,
			"wish": [["library", "M"], ["music", "M"], ["family", "M"], ["study", "M"],
				["sitting", "M"], ["master", "M"], ["storage", "S"], ["bathroom", "S"],
				["kitchen", "S"]],
			"repeat": ["bedroom", "S"]},
		"sliders": {"min": 2, "max": 6, "cpx": 0.45, "corr": 0.3, "orig": 0.45, "irr": 0.0, "towers": 2},
		"labels": {"hall": "Nave", "chancel": "Chancel", "sanctuary": "Sanctuary",
			"transept": "Transept", "sacristy": "Sacristy",
			"corridor": "Ambulatory", "living": "Chapel",
			"family": "Shrine", "sitting": "Meditation Room", "gallery": "Processional Gallery",
			"ballroom": "Ceremonial Hall", "music": "Choir", "dining": "Offering Hall",
			"kitchen": "Preparation Room", "bedroom": "Priest's Cell", "master": "High Priest's Quarters",
			"guest": "Pilgrim's Room", "servants": "Acolytes' Cells", "bathroom": "Purification Bath",
			"study": "Vestry", "library": "Sacred Archive", "storage": "Reliquary",
			"wine": "Undercroft", "closet": "Vestment Store", "staircase": "Stairs",
			"theater": "Oracle Chamber"}},
	{"id": "temple_lower", "name": "Church & Temple (Lower)",
		"desc": "Crypt level: one long central gallery, burial chambers packed along the whole floor, no daylight.",
		"no_windows": true, "no_ext_doors": true, "seal_chance": 0.18,
		"sym": "x", "sym_interior": true, "axial_corridor": true,
		"shapes": {"suite": 1.0},
		"comb": [2, 3], "comb_serve": true,
		"circ": {"spine": 1.0},
		"sliders": {"min": 2, "max": 5, "cpx": 0.7, "corr": 1.0, "orig": 0.1, "irr": 0.0, "towers": 2},
		"program": {"pair": null,
			"wish": [["family", "M"], ["study", "M"], ["library", "M"], ["master", "M"],
				["dining", "S"], ["kitchen", "S"], ["guest", "M"], ["storage", "M"],
				["storage", "M"], ["wine", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "S"]},
		"labels": {"hall": "Antechamber", "corridor": "Central Gallery", "living": "Ritual Chamber",
			"family": "Shrine", "dining": "Offering Room", "kitchen": "Embalming Room",
			"bedroom": "Burial Chamber", "master": "Sarcophagus Vault", "guest": "Niche Gallery",
			"servants": "Servants' Tomb", "bathroom": "Purification Basin", "study": "Funerary Chapel",
			"library": "Epitaph Hall", "storage": "Ossuary", "wine": "Bone Well",
			"closet": "Urn Alcove", "staircase": "Descending Stair", "gallery": "Effigy Gallery"}},
	{"id": "monastery", "hidden": true, "name": "Monastery",
		"desc": "Cloistered life: chapel, chapter house, refectory, rows of monk cells around walks.",
		"shapes": {"courtyard": 1.2, "U": 0.6},
		"hall_force": true, "hall_scale": 1.3,
		"comb": [2, 2],
		"circ": {"ring": 1.0},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["study", "M"], ["library", "M"], ["family", "M"], ["master", "M"],
				["workshop", "M"], ["craft", "M"], ["storage", "M"], ["laundry", "S"],
				["bathroom", "S"]],
			"repeat": ["bedroom", "S"]},
		"sliders": {"min": 2, "max": 8, "cpx": 0.55, "corr": 0.7, "orig": 0.5, "irr": 0.15, "towers": 1},
		"labels": {"hall": "Chapter House", "corridor": "Cloister Walk", "living": "Chapel",
			"family": "Calefactory", "sitting": "Parlor", "dining": "Refectory",
			"kitchen": "Kitchen", "pantry": "Pantry", "wine": "Cellarium",
			"larder": "Buttery", "bedroom": "Monk's Cell", "master": "Abbot's Lodging",
			"guest": "Guest Cell", "servants": "Lay Brothers' Dorter", "bathroom": "Lavatorium",
			"study": "Scriptorium", "library": "Library", "workshop": "Brewery",
			"craft": "Herbarium", "storage": "Almonry", "laundry": "Laundry",
			"closet": "Vestry", "staircase": "Night Stairs", "music": "Choir"}},
	{"id": "crypt", "hidden": true, "name": "Crypt & Dungeon",
		"desc": "Underground complex: isolated chambers of varied shapes strung on long square-cut passages, one or two open entrances, no daylight.",
		"no_windows": true,
		"shapes": {"network": 1.0},
		"net": {"n": [6, 11], "sz": [2, 4], "tw": 1, "connect": 0.3, "grid": 4, "outliers": 2, "spread": true},
		"net_rooms": true,
		"open_ends": [1, 2],
		"hall_force": true, "hall_scale": 1.3,
		"enfilade": true, "enfilade_cats": ["family"],
		"circ": {"branch": 0.5, "spine": 0.3},
		"program": {"pair": null,
			"wish": [["family", "M"], ["study", "M"], ["library", "M"], ["master", "M"],
				["dining", "S"], ["kitchen", "S"], ["guest", "M"], ["storage", "M"],
				["storage", "M"], ["wine", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 3, "max": 12, "cpx": 0.35, "corr": 0.3, "orig": 0.6, "irr": 0.2, "towers": 0},
		"labels": {"hall": "Antechamber", "corridor": "Passage", "living": "Ritual Chamber",
			"family": "Shrine", "dining": "Offering Room", "kitchen": "Embalming Room",
			"bedroom": "Burial Chamber", "master": "Sarcophagus Vault", "guest": "Niche Gallery",
			"servants": "Servants' Tomb", "bathroom": "Purification Basin", "study": "Funerary Chapel",
			"library": "Epitaph Hall", "storage": "Ossuary", "wine": "Bone Well",
			"closet": "Urn Alcove", "staircase": "Descending Stair", "gallery": "Effigy Gallery"}},
	{"id": "library", "hidden": true, "name": "Library & Academy",
		"desc": "Halls of learning: grand reading room, stacks, studies and lecture rooms.",
		"shapes": {"rect": 0.7, "T": 0.5, "U": 0.5, "H": 0.4},
		"hall_force": true, "hall_scale": 1.7,
		"circ": {"central": 0.8, "spine": 0.6},
		"program": {"pair": null,
			"wish": [["library", "L"], ["theater", "L"], ["study", "M"], ["study", "M"],
				["office", "M"], ["gallery", "M"], ["master", "M"], ["sitting", "S"],
				["dining", "M"], ["kitchen", "S"], ["storage", "M"], ["bathroom", "S"]],
			"repeat": ["study", "M"]},
		"sliders": {"min": 3, "max": 12, "cpx": 0.5, "corr": 0.55, "orig": 0.4, "irr": 0.15, "towers": 1},
		"labels": {"hall": "Great Reading Room", "corridor": "Stack Aisle", "living": "Lecture Hall",
			"family": "Seminar Room", "sitting": "Reading Nook", "gallery": "Map Gallery",
			"dining": "Refectory", "kitchen": "Kitchen", "bedroom": "Scholar's Room",
			"master": "Headmaster's Study", "guest": "Visiting Fellow's Room", "servants": "Copyists' Room",
			"bathroom": "Washroom", "study": "Study Cell", "office": "Archivist's Office",
			"library": "Rare Books Vault", "workshop": "Bindery", "storage": "Archive",
			"closet": "Scroll Cabinet", "staircase": "Spiral Stair", "music": "Recital Room",
			"theater": "Auditorium"}},
	{"id": "wizard", "hidden": true, "name": "Wizard's Tower",
		"desc": "Vertical eccentric residence: laboratories, summoning rooms, many turrets, odd angles.",
		"shapes": {"circle": 1.0},
		"round_env": true,
		"circ": {"hub": 0.7, "central": 0.6},
		"program": {"pair": null,
			"wish": [["study", "L"], ["library", "M"], ["workshop", "M"], ["theater", "M"],
				["craft", "M"], ["sitting", "M"], ["family", "S"], ["master", "M"],
				["kitchen", "S"], ["bedroom", "S"], ["storage", "S"], ["wine", "S"],
				["bathroom", "S"]],
			"repeat": ["study", "M"]},
		"sliders": {"min": 2, "max": 7, "cpx": 0.6, "corr": 0.35, "orig": 0.8, "irr": 0.5, "towers": 0},
		"labels": {"hall": "Entry Rotunda", "corridor": "Winding Passage", "living": "Conjuring Hall",
			"family": "Familiar's Den", "sitting": "Divination Room", "gallery": "Artifact Gallery",
			"music": "Resonance Chamber", "game": "Puzzle Room", "dining": "Feast Nook",
			"kitchen": "Alchemical Kitchen", "bedroom": "Apprentice's Room", "master": "Archmage's Chamber",
			"guest": "Visitor's Cell", "servants": "Homunculus Closet", "bathroom": "Scrying Pool",
			"study": "Laboratory", "office": "Spell Registry", "library": "Arcane Library",
			"workshop": "Enchanting Workshop", "craft": "Wand Workshop", "storage": "Component Vault",
			"wine": "Potion Cellar", "closet": "Robe Closet", "staircase": "Spiral Stair",
			"theater": "Observatory"}},
	{"id": "guild", "hidden": true, "name": "Guild Hall",
		"desc": "Trade brotherhood seat: meeting hall, workshops, offices and members' rooms.",
		"shapes": {"rect": 0.8, "L": 0.6, "T": 0.4},
		"hall_force": true, "hall_scale": 1.4,
		"circ": {"central": 0.8, "spine": 0.5},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["family", "M"], ["lounge", "M"], ["workshop", "M"], ["office", "M"],
				["study", "M"], ["workshop", "M"], ["craft", "M"], ["library", "S"],
				["master", "M"], ["servants", "M"], ["storage", "M"], ["wine", "S"],
				["bathroom", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 3, "max": 9, "cpx": 0.6, "corr": 0.5, "orig": 0.45, "irr": 0.25, "towers": 0},
		"labels": {"hall": "Assembly Hall", "corridor": "Gallery", "living": "Members' Lounge",
			"family": "Council Room", "dining": "Banquet Hall", "kitchen": "Kitchen",
			"bedroom": "Member's Room", "master": "Guildmaster's Quarters", "guest": "Journeyman's Room",
			"servants": "Apprentices' Dorm", "bathroom": "Washroom", "study": "Ledger Room",
			"office": "Clerk's Office", "library": "Charter Room", "workshop": "Workshop",
			"craft": "Craft Room", "storage": "Strongroom", "wine": "Cellar",
			"closet": "Records Cabinet", "staircase": "Stairs", "game": "Gaming Room"}},
	{"id": "market", "hidden": true, "name": "Market Hall",
		"desc": "Covered trade: one big open floor ringed by stalls, counting rooms and stores.",
		"shapes": {"rect": 1.2},
		"hall_force": true, "hall_scale": 2.5,
		"hall_centered": true,
		"comb": [2, 2],
		"circ": {"hub": 1.0, "central": 0.5},
		"program": {"pair": null,
			"wish": [["dining", "M"], ["kitchen", "S"], ["study", "M"], ["office", "M"],
				["master", "M"], ["servants", "M"], ["gallery", "M"], ["wine", "S"],
				["pantry", "S"], ["bathroom", "S"]],
			"repeat": ["storage", "M"]},
		"sliders": {"min": 5, "max": 18, "cpx": 0.35, "corr": 0.25, "orig": 0.25, "irr": 0.15, "towers": 0},
		"labels": {"hall": "Market Floor", "corridor": "Stall Aisle", "living": "Auction Hall",
			"family": "Merchants' Lounge", "dining": "Food Court", "kitchen": "Cookshop",
			"bedroom": "Merchant's Room", "master": "Market Warden's Office", "servants": "Porters' Room",
			"bathroom": "Washroom", "study": "Counting Room", "office": "Toll Office",
			"storage": "Warehouse Bay", "pantry": "Cold Store", "wine": "Bonded Cellar",
			"closet": "Stall Store", "staircase": "Stairs", "gallery": "Upper Gallery"}},
	{"id": "warehouse", "hidden": true, "name": "Warehouse",
		"desc": "Pure storage: a rectangle of huge bays, a couple of offices, nothing fancy.",
		"shapes": {"rect": 1.0},
		"comb": [3, 4],
		"circ": {"hub": 1.0},
		"program": {"pair": null,
			"wish": [["office", "M"], ["study", "M"], ["master", "M"], ["bedroom", "S"],
				["servants", "M"], ["dining", "S"], ["bathroom", "S"]],
			"repeat": ["storage", "L"]},
		"sliders": {"min": 6, "max": 20, "cpx": 0.15, "corr": 0.1, "orig": 0.1, "irr": 0.1, "towers": 0},
		"labels": {"hall": "Loading Dock", "corridor": "Cargo Aisle", "living": "Storage Bay",
			"family": "Storage Bay", "dining": "Break Room", "kitchen": "Break Room",
			"bedroom": "Watchman's Room", "master": "Foreman's Office", "servants": "Porters' Room",
			"bathroom": "Washroom", "study": "Tally Office", "office": "Manifest Office",
			"storage": "Storage Bay", "wine": "Bonded Store", "closet": "Tool Store",
			"staircase": "Stairs", "gallery": "Storage Bay", "ballroom": "Storage Bay"}},
	{"id": "hospital", "hidden": true, "name": "Hospital & Infirmary",
		"desc": "Care under one roof: wards on a long spine, treatment rooms, apothecary.",
		"shapes": {"H": 1.0, "T": 0.6, "U": 0.5, "cross": 0.4},
		"comb": [3, 3], "comb_serve": true,
		"circ": {"spine": 1.0},
		"program": {"pair": ["kitchen", "dining"],
			"wish": [["study", "M"], ["study", "M"], ["workshop", "M"], ["office", "M"],
				["master", "M"], ["guest", "M"], ["library", "M"], ["servants", "M"],
				["bathroom", "M"], ["laundry", "S"], ["storage", "S"], ["storage", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 2, "max": 9, "cpx": 0.65, "corr": 0.9, "orig": 0.3, "irr": 0.1, "towers": 0},
		"labels": {"hall": "Reception Hall", "corridor": "Ward Corridor", "living": "Great Ward",
			"family": "Convalescent Room", "sitting": "Waiting Room", "dining": "Refectory",
			"kitchen": "Kitchen", "bedroom": "Patient Ward", "master": "Head Physician's Office",
			"guest": "Isolation Room", "servants": "Sisters' Quarters", "bathroom": "Bathhouse",
			"study": "Treatment Room", "office": "Physician's Study", "library": "Medical Library",
			"workshop": "Apothecary", "craft": "Herb Room", "storage": "Supply Room",
			"laundry": "Laundry", "wine": "Medicine Cellar", "closet": "Linen Store",
			"staircase": "Stairs"}},
	{"id": "bathhouse", "hidden": true, "name": "Bathhouse",
		"desc": "Public baths: pools of different heats, massage and steam rooms, changing rooms.",
		"shapes": {"rect": 0.8, "T": 0.5, "cross": 0.4, "courtyard": 0.4},
		"hall_force": true, "hall_scale": 1.8,
		"hall_centered": true,
		"comb": [2, 3],
		"circ": {"central": 1.0, "ring": 0.4},
		"program": {"pair": null,
			"wish": [["family", "L"], ["lounge", "L"], ["sitting", "M"], ["gym", "M"],
				["study", "M"], ["study", "M"], ["dining", "M"], ["kitchen", "S"],
				["master", "M"], ["servants", "M"], ["laundry", "S"], ["storage", "S"],
				["wine", "S"]],
			"repeat": ["bedroom", "S"]},
		"sliders": {"min": 3, "max": 10, "cpx": 0.5, "corr": 0.5, "orig": 0.4, "irr": 0.2, "towers": 0},
		"labels": {"hall": "Entrance Atrium", "corridor": "Colonnade", "living": "Great Pool",
			"family": "Warm Pool", "sitting": "Cold Plunge", "lounge": "Rest Hall",
			"gym": "Exercise Court", "dining": "Refreshment Room", "kitchen": "Kitchen",
			"bedroom": "Changing Room", "master": "Bathmaster's Office", "servants": "Attendants' Room",
			"bathroom": "Steam Room", "study": "Massage Room", "storage": "Towel Store",
			"laundry": "Laundry", "wine": "Oil Store", "closet": "Locker Room",
			"staircase": "Stairs", "gallery": "Mosaic Gallery"}},
	{"id": "thieves", "hidden": true, "name": "Thieves' Den",
		"desc": "Hidden hideout: crooked rooms, escape routes, stashes and a fighting pit.",
		"shapes": {"Z": 0.8, "J": 0.8, "L": 0.6, "rect": 0.3},
		"circ": {"branch": 1.0},
		"program": {"pair": null,
			"wish": [["game", "M"], ["study", "M"], ["office", "M"], ["workshop", "M"],
				["master", "M"], ["guest", "M"], ["servants", "M"], ["sitting", "S"],
				["kitchen", "S"], ["dining", "S"], ["storage", "M"], ["storage", "M"],
				["wine", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "M"]},
		"sliders": {"min": 2, "max": 7, "cpx": 0.7, "corr": 0.6, "orig": 0.7, "irr": 0.6, "towers": 0},
		"labels": {"hall": "Den", "corridor": "Escape Tunnel", "living": "Common Den",
			"family": "Boss's Table", "sitting": "Lookout Post", "game": "Fighting Pit",
			"dining": "Mess Corner", "kitchen": "Cookfire", "bedroom": "Bunk Room",
			"master": "Boss's Quarters", "guest": "Fence's Room", "servants": "Cutpurse Bunks",
			"bathroom": "Washbasin", "study": "Planning Room", "office": "Fence's Counter",
			"storage": "Stash Room", "wine": "Smuggler's Cache", "closet": "Loot Cabinet",
			"staircase": "Trapdoor Stair", "workshop": "Forgery Room"}},
	{"id": "ruins", "hidden": true, "name": "Ruins",
		"desc": "Collapsed structure: broken outline, misshapen chambers, half-buried halls.",
		"circ": {"branch": 0.8, "spine": 0.4},
		"sliders": {"min": 3, "max": 10, "cpx": 0.5, "corr": 0.4, "orig": 0.85, "irr": 0.8, "towers": 1},
		"labels": {"hall": "Fallen Hall", "corridor": "Rubble Passage", "living": "Collapsed Chamber",
			"family": "Broken Shrine", "dining": "Overgrown Court", "kitchen": "Sooty Hearth",
			"bedroom": "Ruined Chamber", "master": "Toppled Vault", "servants": "Crumbled Cells",
			"bathroom": "Dry Cistern", "study": "Faded Fresco Room", "library": "Scattered Archive",
			"storage": "Caved-in Store", "wine": "Sunken Cellar", "closet": "Choked Alcove",
			"staircase": "Broken Stair", "gallery": "Roofless Gallery", "ballroom": "Shattered Hall"}},
	{"id": "cave", "hidden": true, "name": "Cavern Lair",
		"desc": "Natural caves: organic bulging chambers flowing into each other through pinched necks, no doors, no daylight.",
		"no_windows": true,
		"wide_opens": true,
		"shapes": {"network": 1.0},
		"net": {"n": [5, 9], "sz": [2, 4], "tw": 2, "loops": 1},
		"circ": {"branch": 1.0},
		"program": {"pair": null,
			"wish": [["family", "M"], ["sitting", "M"], ["dining", "M"], ["kitchen", "S"],
				["study", "M"], ["library", "M"], ["master", "M"], ["guest", "M"],
				["servants", "M"], ["storage", "M"], ["wine", "S"], ["bathroom", "S"]],
			"repeat": ["bedroom", "S"]},
		"sliders": {"min": 3, "max": 12, "cpx": 0.5, "corr": 0.35, "orig": 0.95, "irr": 1.0, "towers": 0},
		"labels": {"hall": "Main Cavern", "corridor": "Winding Tunnel", "living": "Great Grotto",
			"family": "Nesting Chamber", "sitting": "Echo Chamber", "dining": "Feeding Ground",
			"kitchen": "Fire Pit", "bedroom": "Sleeping Alcove", "master": "Deep Chamber",
			"guest": "Side Grotto", "servants": "Warren", "bathroom": "Underground Pool",
			"study": "Crystal Chamber", "library": "Painted Cave", "storage": "Bone Pile",
			"wine": "Fungus Grove", "closet": "Crevice", "staircase": "Sinkhole",
			"gallery": "Stalactite Gallery", "ballroom": "Vaulted Cavern"}},
	{"id": "sewers", "hidden": true, "name": "Sewers",
		"desc": "Underground network: channels everywhere, junction chambers, multiple routes.",
		"no_windows": true,
		"shapes": {"network": 1.0},
		"net": {"n": [9, 14], "sz": [1, 3], "tw": 1, "loops": 4, "grid": 3, "clusters": 2, "outliers": 3},
		"circ": {"branch": 0.7, "ring": 0.5},
		"program": {"pair": null,
			"wish": [["family", "M"], ["study", "M"], ["workshop", "M"], ["office", "S"],
				["master", "M"], ["sitting", "S"], ["dining", "S"], ["kitchen", "S"],
				["storage", "M"], ["wine", "S"], ["bathroom", "S"]],
			"repeat": ["storage", "S"]},
		"sliders": {"min": 2, "max": 8, "cpx": 0.65, "corr": 1.0, "orig": 1.0, "irr": 0.7, "towers": 0},
		"labels": {"hall": "Junction Chamber", "corridor": "Sewer Channel", "living": "Main Cistern",
			"family": "Overflow Basin", "sitting": "Grate Room", "dining": "Refuse Pit",
			"kitchen": "Sluice Room", "bedroom": "Vagrant's Nook", "master": "Ratcatcher's Den",
			"servants": "Crawlspace", "bathroom": "Runoff Drain", "study": "Valve Room",
			"office": "Maintenance Post", "storage": "Silt Trap", "wine": "Forgotten Vault",
			"closet": "Pipe Recess", "staircase": "Access Shaft", "workshop": "Pump Room",
			"gallery": "Arched Gallery"}},
	{"id": "mine", "hidden": true, "name": "Mine",
		"desc": "Dug for ore: long tunnels, work faces, shaft rooms and ore stores, no daylight.",
		"no_windows": true,
		"shapes": {"network": 1.0},
		"net": {"n": [5, 9], "sz": [1, 3], "tw": 1, "loops": 0, "long": true, "grid": 4, "outliers": 2},
		"circ": {"branch": 1.0},
		"program": {"pair": null,
			"wish": [["family", "M"], ["family", "M"], ["dining", "M"], ["kitchen", "S"],
				["study", "M"], ["office", "S"], ["workshop", "M"], ["master", "M"],
				["servants", "M"], ["storage", "M"], ["storage", "M"], ["wine", "S"],
				["bathroom", "S"]],
			"repeat": ["family", "M"]},
		"sliders": {"min": 2, "max": 9, "cpx": 0.4, "corr": 1.0, "orig": 0.9, "irr": 0.6, "towers": 0},
		"labels": {"hall": "Mine Head", "corridor": "Tunnel", "living": "Main Gallery",
			"family": "Work Face", "sitting": "Rest Niche", "dining": "Miners' Mess",
			"kitchen": "Cookfire", "bedroom": "Bunk Cave", "master": "Foreman's Post",
			"servants": "Diggers' Bunks", "bathroom": "Sump", "study": "Assay Room",
			"office": "Tally Post", "storage": "Ore Store", "wine": "Flooded Level",
			"closet": "Tool Niche", "staircase": "Winch Shaft", "workshop": "Timber Shop",
			"gallery": "Crystal Vein"}}
]


func _on_plan_archetype_selected(idx: int) -> void:
	# idx is the dropdown POSITION; the table index rides in the item id
	# (hidden entries make the two diverge).
	if _plan_arch_dd == null or not is_instance_valid(_plan_arch_dd):
		return
	var tidx = _plan_arch_dd.get_item_id(idx)
	if tidx < 0 or tidx >= PLAN_ARCHETYPES.size():
		return
	var def = PLAN_ARCHETYPES[tidx]
	_plan_archetype = def
	# Sliders / Randomize / dividers follow the archetype.
	var is_custom = String(def.get("id", "")) == "custom"
	_apply_arch_ui_state()
	_update_button_visibility()
	if _plan_arch_dd != null and is_instance_valid(_plan_arch_dd):
		_plan_arch_dd.hint_tooltip = String(def.get("desc", ""))
	var sl = def.get("sliders", null)
	if sl == null and is_custom:
		# Back to Custom: factory defaults, so the last archetype's
		# preset never lingers invisibly in the freshly re-shown sliders.
		sl = {"min": 3, "max": 8, "cpx": 0.5, "corr": 0.5, "orig": 0.5,
			"irr": 0.3, "towers": 2}
	if sl == null:
		return
	# Presets go through the sliders themselves: the user sees the values
	# move and stays free to tweak them afterwards.
	var targets = [[_slider_plan_min, "min"], [_slider_plan_max, "max"],
		[_slider_plan_cpx, "cpx"], [_slider_plan_corr, "corr"],
		[_slider_plan_orig, "orig"], [_slider_plan_irr, "irr"],
		[_slider_plan_towers, "towers"]]
	for t in targets:
		if sl.has(t[1]) and t[0] != null and is_instance_valid(t[0]):
			t[0].value = float(sl[t[1]])


func _plan_cat_label(cat: String) -> String:
	# Archetype renaming first: exact category, then its behavior group.
	var amap = _plan_archetype.get("labels", null)
	if amap != null:
		if amap.has(cat):
			return String(amap[cat])
		var grp = _plan_cat_group(cat)
		if amap.has(grp):
			return String(amap[grp])
	var names = {"hall": "Hall", "corridor": "Corridor", "living": "Living Room",
		"dining": "Dining Room", "kitchen": "Kitchen", "bedroom": "Bedroom",
		"study": "Study", "bathroom": "Bathroom", "storage": "Storage",
		"closet": "Closet", "staircase": "Staircase",
		"family": "Family Room", "library": "Library", "music": "Music Room",
		"gallery": "Gallery", "ballroom": "Ballroom", "lounge": "Lounge",
		"game": "Game Room", "sitting": "Sitting Room", "office": "Office",
		"workshop": "Workshop", "craft": "Craft Room", "sewing": "Sewing Room",
		"hobby": "Hobby Room", "pantry": "Pantry", "laundry": "Laundry",
		"mudroom": "Mudroom", "linen": "Linen Closet", "coat": "Coat Closet",
		"larder": "Larder", "wine": "Wine Cellar", "guest": "Guest Bedroom",
		"master": "Master Bedroom", "nursery": "Nursery",
		"servants": "Servants' Quarters", "powder": "Powder Room",
		"breakfast": "Breakfast Nook", "gym": "Gym", "theater": "Home Theater"}
	return String(names.get(cat, cat.capitalize()))


# Behavior group of a category: doors/windows/towers rules apply per group,
# so the richer vocabulary reuses the existing tables.
func _plan_cat_group(cat: String) -> String:
	var g = {"living": "living", "family": "living", "library": "living",
		"music": "living", "gallery": "living", "ballroom": "living",
		"lounge": "living", "game": "living", "sitting": "living",
		"gym": "living", "theater": "living",
		"dining": "dining", "breakfast": "dining",
		"kitchen": "kitchen",
		"bedroom": "bedroom", "guest": "bedroom", "master": "bedroom",
		"nursery": "bedroom", "servants": "bedroom",
		"bathroom": "bathroom", "powder": "bathroom",
		"study": "study", "office": "study", "workshop": "study",
		"craft": "study", "sewing": "study", "hobby": "study",
		"storage": "storage", "pantry": "storage", "laundry": "storage",
		"mudroom": "storage", "larder": "storage", "wine": "storage",
		"closet": "closet", "linen": "closet", "coat": "closet",
		"staircase": "staircase", "hall": "hall", "corridor": "corridor"}
	return String(g.get(cat, cat))


func _plan_build_labels(rooms: Array, cw: int, ch: int, cats: Dictionary, acx: int, acy: int) -> Array:
	# Plain JSON-safe dicts (they persist in the map data): position at the
	# room's cell centroid (bbox centers land outside L-shaped rooms).
	var labels = []
	var infos = _plan_room_infos(rooms, cw, ch)
	var cx_sum = {}
	var cy_sum = {}
	for i in range(cw * ch):
		var r = rooms[i]
		if r < 0:
			continue
		var y = i / cw
		var x = i - y * cw
		cx_sum[r] = float(cx_sum.get(r, 0.0)) + float(x) + 0.5
		cy_sum[r] = float(cy_sum.get(r, 0.0)) + float(y) + 0.5
	for r in infos:
		if not cats.has(int(r)):
			continue
		if String(cats[int(r)]) == "corridor":
			continue
		var inf = infos[r]
		var n = int(inf["cells"])
		if n < 2:
			continue
		# Most interior cell (BFS distance to non-room cells), tie-broken
		# by the centroid: keeps labels off the walls of L-shaped rooms.
		var cgx = float(cx_sum[r]) / float(n)
		var cgy = float(cy_sum[r]) / float(n)
		var dist = {}
		var dq = []
		for i0 in range(cw * ch):
			if rooms[i0] != int(r):
				continue
			var y0 = i0 / cw
			var x0 = i0 - y0 * cw
			var edge0 = false
			for nb in [[x0 - 1, y0], [x0 + 1, y0], [x0, y0 - 1], [x0, y0 + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch \
						or rooms[nb[1] * cw + nb[0]] != int(r):
					edge0 = true
					break
			if edge0:
				dist[i0] = 0
				dq.append(i0)
		var qi0 = 0
		while qi0 < dq.size():
			var cur0 = dq[qi0]
			qi0 += 1
			var cy0 = cur0 / cw
			var cx0 = cur0 - cy0 * cw
			for nb in [[cx0 - 1, cy0], [cx0 + 1, cy0], [cx0, cy0 - 1], [cx0, cy0 + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var j0 = nb[1] * cw + nb[0]
				if rooms[j0] == int(r) and not dist.has(j0):
					dist[j0] = int(dist[cur0]) + 1
					dq.append(j0)
		var best_i0 = -1
		var best_k0 = -1000000.0
		for i0 in dist:
			var y1 = int(i0) / cw
			var x1 = int(i0) - y1 * cw
			var k0 = float(dist[i0]) * 100.0 - abs(float(x1) + 0.5 - cgx) - abs(float(y1) + 0.5 - cgy)
			if k0 > best_k0:
				best_k0 = k0
				best_i0 = int(i0)
		var bly = best_i0 / cw
		var blx = best_i0 - bly * cw
		# Center on the continuous free runs through the anchor: exact
		# centering on rectangles and on the local lobe of L-shaped rooms.
		var x0r = blx
		while x0r > 0 and rooms[bly * cw + x0r - 1] == int(r):
			x0r -= 1
		var x1r = blx
		while x1r < cw - 1 and rooms[bly * cw + x1r + 1] == int(r):
			x1r += 1
		var y0r = bly
		while y0r > 0 and rooms[(y0r - 1) * cw + blx] == int(r):
			y0r -= 1
		var y1r = bly
		while y1r < ch - 1 and rooms[(y1r + 1) * cw + blx] == int(r):
			y1r += 1
		labels.append({
			"t": _plan_cat_label(String(cats[int(r)])),
			"x": (float(acx) + float(x0r + x1r + 1) * 0.5) * CELL,
			"y": (float(acy) + float(y0r + y1r + 1) * 0.5) * CELL,
			"w": float(x1r - x0r + 1) * CELL,
			"h": float(y1r - y0r + 1) * CELL
		})
	return labels



# ── Doors: category-aware connection ────────────────────────────────────────

func _plan_opening_on_run(vr, run, type_s: String, want_wide: bool) -> bool:
	var len_r = _plan_run_len(run)
	if len_r < 1:
		return false
	var w = 1
	if want_wide and len_r >= 4:
		w = 2
	if len_r - w <= 2:
		var cpos = stepify(float(len_r - w) * 0.5, 0.5)
		if _plan_try_hole(run, cpos, w, type_s):
			return true
	var lo = 0
	var hi = len_r - w
	if len_r > w + 1:
		lo = 1
		hi = len_r - w - 1
	if hi < lo:
		lo = 0
		hi = len_r - w
	for _try in range(4):
		if _plan_try_hole(run, float(vr.randi_range(lo, hi)), w, type_s):
			return true
	return false


func _plan_edge_open(vr, edge, type_s: String, want_wide: bool) -> bool:
	# Longest run first, but every run of the boundary gets a chance (the
	# longest one may be eaten by tower/bevel cuts).
	var rr = edge["runs"].duplicate()
	for i in range(rr.size()):
		for j in range(i + 1, rr.size()):
			if _plan_run_len(rr[j]) > _plan_run_len(rr[i]):
				var tmp = rr[i]
				rr[i] = rr[j]
				rr[j] = tmp
	for run in rr:
		if _plan_opening_on_run(vr, run, type_s, want_wide):
			return true
	return false


func _plan_connect_rooms(vr, runs: Array, rooms: Array, cw: int, ch: int, cats: Dictionary) -> Dictionary:
	var stats = {"repairs": 0, "open": 0}
	# Adjacency by room pair with the runs of each shared boundary.
	var adj = {}
	var neighbors = {}
	var room_set = {}
	for i in range(cw * ch):
		if rooms[i] >= 0:
			room_set[rooms[i]] = true
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var key = str(run["a"]) + "_" + str(run["b"])
		if not adj.has(key):
			adj[key] = {"a": int(run["a"]), "b": int(run["b"]), "runs": []}
			if not neighbors.has(int(run["a"])):
				neighbors[int(run["a"])] = []
			if not neighbors.has(int(run["b"])):
				neighbors[int(run["b"])] = []
			neighbors[int(run["a"])].append(adj[key])
			neighbors[int(run["b"])].append(adj[key])
		adj[key]["runs"].append(run)
	# Door budget per category: private/technical rooms get a single door.
	var caps = {"bedroom": 1, "bathroom": 1, "storage": 1, "closet": 1, "staircase": 1}
	var door_cnt = {}
	# Entrance: an exterior door into the hall (else living, else anything),
	# guaranteed.
	var entry_pref = ["hall", "living", "corridor", "kitchen"]
	var placed_entry = false
	for pref in entry_pref:
		if placed_entry:
			break
		var cands = []
		for run in runs:
			if String(run["kind"]) != "ext":
				continue
			var inner = int(max(int(run["a"]), int(run["b"])))
			if _plan_cat_group(String(cats.get(inner, ""))) == pref and _plan_run_len(run) >= 1:
				cands.append(run)
		_plan_shuffle(vr, cands)
		for run in cands:
			if _plan_opening_on_run(vr, run, "door", vr.randf() < 0.3):
				var inner2 = int(max(int(run["a"]), int(run["b"])))
				door_cnt[inner2] = int(door_cnt.get(inner2, 0)) + 1
				placed_entry = true
				break
		# The hall MUST get the entrance when it exists: force it rather
		# than falling through to another category.
		if pref == "hall" and not placed_entry and not cands.empty():
			var hl = cands[0]
			for run in cands:
				if _plan_run_len(run) > _plan_run_len(hl):
					hl = run
			_plan_forced_door(hl)
			placed_entry = true
	if not placed_entry:
		var longest = null
		for run in runs:
			if String(run["kind"]) == "ext":
				if longest == null or _plan_run_len(run) > _plan_run_len(longest):
					longest = run
		if longest != null:
			_plan_forced_door(longest)
	# Extra exterior doors: living rooms first, halls, corridors less often;
	# other rooms only once one of those already opens outside.
	var extra_doors = 0
	if _plan_complexity > 0.35 and vr.randf() < 0.5:
		extra_doors += 1
	if _plan_complexity > 0.75 and vr.randf() < 0.4:
		extra_doors += 1
	for _i in range(extra_doors):
		var pool = []
		for run in runs:
			if String(run["kind"]) != "ext" or _plan_run_len(run) < 2:
				continue
			var inner3 = int(max(int(run["a"]), int(run["b"])))
			var c3 = _plan_cat_group(String(cats.get(inner3, "")))
			if c3 == "living":
				pool.append(run)
				pool.append(run)
			elif c3 == "hall":
				pool.append(run)
				pool.append(run)
			elif c3 == "corridor":
				pool.append(run)
		if pool.empty():
			break
		_plan_opening_on_run(vr, pool[vr.randi_range(0, pool.size() - 1)], "door", false)
	# Connection waves: rooms attach to already-connected hosts; private and
	# technical rooms are never used as passages.
	var hosts = {"hall": true, "corridor": true, "living": true, "dining": true, "kitchen": true, "study": true}
	# Where each private/technical category may open (falls back to hosts).
	var host_rules = {
		"bathroom": {"corridor": true, "bedroom": true, "living": true},
		"closet": {"corridor": true, "hall": true, "bedroom": true, "living": true},
		"storage": {"corridor": true, "hall": true, "kitchen": true},
		"staircase": {"corridor": true, "hall": true, "living": true},
		"bedroom": {"corridor": true, "hall": true, "living": true, "dining": true},
		"dining": {"kitchen": true, "hall": true, "living": true, "corridor": true},
		"kitchen": {"corridor": true, "hall": true, "dining": true, "living": true},
		"study": {"corridor": true, "hall": true, "living": true, "dining": true}
	}
	var open_pairs = {"living_dining": 0.7, "dining_kitchen": 0.6, "hall_living": 0.5}
	var connected = {}
	var host_load = {}
	for r in room_set:
		var c = _plan_cat_group(String(cats.get(int(r), "")))
		if c == "hall" or c == "corridor":
			connected[int(r)] = true
	# Hub linking: a hall next to a corridor ALWAYS opens on it; the living
	# room opens on most adjacent corridors.
	for key in adj:
		var e0 = adj[key]
		var ga = _plan_cat_group(String(cats.get(int(e0["a"]), "")))
		var gb = _plan_cat_group(String(cats.get(int(e0["b"]), "")))
		var link = false
		if (ga == "hall" and gb == "corridor") or (ga == "corridor" and gb == "hall"):
			link = true
		elif (ga == "living" and gb == "corridor") or (ga == "corridor" and gb == "living"):
			link = vr.randf() < 0.7
		if not link:
			continue
		var has_door0 = false
		for run in e0["runs"]:
			for h in run["holes"]:
				var t0 = String(h[2])
				if t0 == "door" or t0 == "open":
					has_door0 = true
					break
			if has_door0:
				break
		if has_door0:
			continue
		if not _plan_edge_open(vr, e0, "door", vr.randf() < 0.4):
			_plan_forced_door(e0["runs"][0])
	# Kitchen and dining directly linked whenever they touch.
	var kd_k = -1
	var kd_d = -1
	for r in room_set:
		var g0 = _plan_cat_group(String(cats.get(int(r), "")))
		if g0 == "kitchen":
			kd_k = int(r)
		elif g0 == "dining":
			kd_d = int(r)
	if kd_k >= 0 and kd_d >= 0:
		for e0 in neighbors.get(kd_k, []):
			var oth0b = int(e0["b"])
			if oth0b == kd_k:
				oth0b = int(e0["a"])
			if oth0b != kd_d:
				continue
			var has0 = false
			for run in e0["runs"]:
				for h in run["holes"]:
					var t0b = String(h[2])
					if t0b == "door" or t0b == "open":
						has0 = true
						break
				if has0:
					break
			if not has0:
				if not _plan_edge_open(vr, e0, "open" if vr.randf() < 0.6 else "door", vr.randf() < 0.6):
					_plan_forced_door(e0["runs"][0])
				door_cnt[kd_k] = int(door_cnt.get(kd_k, 0)) + 1
				door_cnt[kd_d] = int(door_cnt.get(kd_d, 0)) + 1
			break
	# Ensuite: a master bedroom adjacent to a bathroom very likely opens on
	# it directly (the assignment guarantees a second bathroom elsewhere).
	var master_id2 = -1
	for r in room_set:
		if String(cats.get(int(r), "")) == "master":
			master_id2 = int(r)
	if master_id2 >= 0 and vr.randf() < 0.8:
		for e0 in neighbors.get(master_id2, []):
			var oth0 = int(e0["b"])
			if oth0 == master_id2:
				oth0 = int(e0["a"])
			if _plan_cat_group(String(cats.get(oth0, ""))) != "bathroom":
				continue
			if _plan_edge_open(vr, e0, "door", false):
				connected[oth0] = true
				door_cnt[oth0] = int(door_cnt.get(oth0, 0)) + 1
				door_cnt[master_id2] = int(door_cnt.get(master_id2, 0)) + 1
			break
	if connected.empty():
		for r in room_set:
			connected[int(r)] = true
			break
	for _wave in range(room_set.size() + 2):
		var progress = false
		for r in room_set:
			if connected.has(int(r)):
				continue
			if not neighbors.has(int(r)):
				continue
			var rc = _plan_cat_group(String(cats.get(int(r), "")))
			var best_e = null
			var best_rank = -1
			for e in neighbors[int(r)]:
				var other = int(e["b"])
				if other == int(r):
					other = int(e["a"])
				if not connected.has(other):
					continue
				var oc = _plan_cat_group(String(cats.get(other, "")))
				var allowed = hosts.has(oc)
				if host_rules.has(rc):
					allowed = host_rules[rc].has(oc)
				if not allowed:
					continue
				# The host with the most REMAINING distribution capacity
				# wins: connections spread across hubs instead of chaining
				# through the first public room found.
				var rank = _plan_cap(oc) - int(host_load.get(other, 0))
				if rank > best_rank:
					best_rank = rank
					best_e = e
			if best_e == null:
				continue
			var other2 = int(best_e["b"])
			if other2 == int(r):
				other2 = int(best_e["a"])
			var oc2 = _plan_cat_group(String(cats.get(other2, "")))
			var pk = rc + "_" + oc2
			var pk2 = oc2 + "_" + rc
			var type_s = "door"
			if (open_pairs.has(pk) and vr.randf() < float(open_pairs[pk])) \
					or (open_pairs.has(pk2) and vr.randf() < float(open_pairs[pk2])):
				type_s = "open"
				stats["open"] = int(stats["open"]) + 1
			if _plan_edge_open(vr, best_e, type_s, type_s == "open"):
				connected[int(r)] = true
				door_cnt[int(r)] = int(door_cnt.get(int(r), 0)) + 1
				door_cnt[other2] = int(door_cnt.get(other2, 0)) + 1
				host_load[other2] = int(host_load.get(other2, 0)) + 1
				if rc == "bedroom" and (oc2 == "corridor" or oc2 == "hall"):
					stats["bed_corr"] = int(stats.get("bed_corr", 0)) + 1
				progress = true
		if not progress:
			break
	# Repairs: anything still isolated gets a forced door to any connected
	# neighbor; legal pairs first, anything as a last resort.
	for _wave2 in range(room_set.size() + 2):
		var progress2 = false
		for r in room_set:
			if connected.has(int(r)) or not neighbors.has(int(r)):
				continue
			var cand_edges = []
			for e0 in neighbors[int(r)]:
				var oth = int(e0["b"])
				if oth == int(r):
					oth = int(e0["a"])
				if not connected.has(oth):
					continue
				if _plan_pair_forbidden(cats, int(r), oth):
					continue
				if _plan_pair_ok(cats, int(r), oth):
					cand_edges.push_front(e0)
				else:
					cand_edges.push_back(e0)
			for e in cand_edges:
				var other3 = int(e["b"])
				if other3 == int(r):
					other3 = int(e["a"])
				if not connected.has(other3):
					continue
				if _plan_edge_open(vr, e, "door", false):
					connected[int(r)] = true
					stats["repairs"] = int(stats["repairs"]) + 1
					progress2 = true
					break
				else:
					var best2 = null
					for run in e["runs"]:
						if best2 == null or _plan_run_len(run) > _plan_run_len(best2):
							best2 = run
					if best2 != null:
						_plan_forced_door(best2)
						connected[int(r)] = true
						stats["repairs"] = int(stats["repairs"]) + 1
						progress2 = true
						break
			if connected.has(int(r)):
				continue
		if not progress2:
			break
	# Circulation loops between public rooms, respecting the door caps.
	var loops = int(round(_plan_complexity * float(room_set.size()) * 0.35))
	var keys = adj.keys()
	_plan_shuffle(vr, keys)
	for key in keys:
		if loops <= 0:
			break
		var e2 = adj[key]
		var ca = _plan_cat_group(String(cats.get(int(e2["a"]), "")))
		var cb = _plan_cat_group(String(cats.get(int(e2["b"]), "")))
		if not hosts.has(ca) or not hosts.has(cb):
			continue
		if int(door_cnt.get(int(e2["a"]), 0)) >= int(caps.get(ca, 99)) \
				or int(door_cnt.get(int(e2["b"]), 0)) >= int(caps.get(cb, 99)):
			continue
		if _plan_edge_open(vr, e2, "door", false):
			door_cnt[int(e2["a"])] = int(door_cnt.get(int(e2["a"]), 0)) + 1
			door_cnt[int(e2["b"])] = int(door_cnt.get(int(e2["b"]), 0)) + 1
			loops -= 1
	# Final guarantee: GLOBAL reachability. Every room must reach the
	# exterior through the actual door graph, not merely own a door.
	stats["repairs"] = int(stats["repairs"]) + _plan_reachability_repair(runs, room_set)
	# And the interior must form a SINGLE communicating whole: two wings
	# each opening outside but not into each other are stitched together.
	stats["repairs"] = int(stats["repairs"]) + _plan_unify_interior(vr, runs, room_set, cats)
	# Deep room chains get flattened toward distribution nodes.
	stats["repairs"] = int(stats["repairs"]) + _plan_flatten_chains(runs, cats)
	# ABSOLUTE guarantee: no room without any opening. Legal pairs first,
	# non-forbidden next, anything as the very last resort.
	for r in room_set:
		var opens = 0
		for run in runs:
			if int(run["a"]) != int(r) and int(run["b"]) != int(r):
				continue
			for h in run["holes"]:
				var tg = String(h[2])
				if tg == "door" or tg == "open":
					opens += 1
		if opens > 0:
			continue
		var tiers = [[], [], []]
		for e in neighbors.get(int(r), []):
			var oth = int(e["b"])
			if oth == int(r):
				oth = int(e["a"])
			if _plan_pair_ok(cats, int(r), oth):
				tiers[0].append(e)
			elif not _plan_pair_forbidden(cats, int(r), oth):
				tiers[1].append(e)
			else:
				tiers[2].append(e)
		var placed_g = false
		for tier in tiers:
			for e in tier:
				if _plan_edge_open(vr, e, "door", false):
					placed_g = true
					break
			if placed_g:
				break
		if not placed_g and neighbors.has(int(r)) and neighbors[int(r)].size() > 0:
			_plan_forced_door(neighbors[int(r)][0]["runs"][0])
		stats["repairs"] = int(stats["repairs"]) + 1
	# A bathroom opening on a bedroom (master included) is entered ONLY
	# through that bedroom. Before sealing the bathroom, the bedroom is
	# guaranteed its own non-bathroom door so the pair never gets isolated.
	for r in room_set:
		if _plan_cat_group(String(cats.get(int(r), ""))) != "bathroom":
			continue
		var partner = -1
		for run in runs:
			if String(run["kind"]) != "int":
				continue
			var ra = int(run["a"])
			var rb = int(run["b"])
			var oth3 = -1
			if ra == int(r):
				oth3 = rb
			elif rb == int(r):
				oth3 = ra
			else:
				continue
			if _plan_cat_group(String(cats.get(oth3, ""))) != "bedroom":
				continue
			for h in run["holes"]:
				var tg2 = String(h[2])
				if tg2 == "door" or tg2 == "open":
					partner = oth3
					break
			if partner >= 0:
				break
		if partner < 0:
			continue
		# The bedroom needs a door that is not the bathroom.
		var bed_ok = false
		for run in runs:
			var ra4 = int(run["a"])
			var rb4 = int(run["b"])
			if ra4 != partner and rb4 != partner:
				continue
			var oth4 = rb4
			if rb4 == partner:
				oth4 = ra4
			if String(run["kind"]) == "int" and oth4 == int(r):
				continue
			for h in run["holes"]:
				var tg4 = String(h[2])
				if tg4 == "door" or tg4 == "open":
					bed_ok = true
					break
			if bed_ok:
				break
		if not bed_ok:
			var tiers2 = [[], []]
			for e in neighbors.get(partner, []):
				var oth5 = int(e["b"])
				if oth5 == partner:
					oth5 = int(e["a"])
				if oth5 == int(r):
					continue
				if _plan_pair_ok(cats, partner, oth5):
					tiers2[0].append(e)
				elif not _plan_pair_forbidden(cats, partner, oth5):
					tiers2[1].append(e)
			for tier in tiers2:
				for e in tier:
					if _plan_edge_open(vr, e, "door", false):
						bed_ok = true
						break
				if bed_ok:
					break
			if not bed_ok:
				# No legal outlet for the bedroom: keep the bathroom open.
				continue
		for run in runs:
			var ra2 = int(run["a"])
			var rb2 = int(run["b"])
			if ra2 != int(r) and rb2 != int(r):
				continue
			if String(run["kind"]) == "int" and (ra2 == partner or rb2 == partner):
				continue
			var kept_e = []
			for h in run["holes"]:
				var tg3 = String(h[2])
				if tg3 == "door" or tg3 == "open":
					continue
				kept_e.append(h)
			run["holes"] = kept_e
	# Staircases and tiny rooms (closets, powder rooms...) are strictly
	# single-opening: extras are removed (no pass-through 1x1 boxes).
	var cell_count = {}
	for i in range(cw * ch):
		if rooms[i] >= 0:
			cell_count[rooms[i]] = int(cell_count.get(rooms[i], 0)) + 1
	for r in room_set:
		if _plan_cat_group(String(cats.get(int(r), ""))) != "staircase" \
				and int(cell_count.get(int(r), 99)) > 2:
			continue
		var kept_one = false
		for run in runs:
			if int(run["a"]) != int(r) and int(run["b"]) != int(r):
				continue
			var kept_h2 = []
			for h in run["holes"]:
				var t3 = String(h[2])
				if t3 == "door" or t3 == "open":
					if kept_one:
						continue
					kept_one = true
				kept_h2.append(h)
			run["holes"] = kept_h2
	# A corridor must serve at least 3 connections for real. Runs AFTER the
	# ensuite/staircase removals (they were deleting doors this pass had
	# placed), with a forced fallback when clean placement fails.
	for r in room_set:
		if _plan_cat_group(String(cats.get(int(r), ""))) != "corridor":
			continue
		var served = 0
		var cands2 = []
		for e in neighbors.get(int(r), []):
			var oth = int(e["b"])
			if oth == int(r):
				oth = int(e["a"])
			var hd = false
			for run in e["runs"]:
				for h in run["holes"]:
					var t = String(h[2])
					if t == "door" or t == "open":
						hd = true
						break
				if hd:
					break
			if hd:
				served += 1
			elif not _plan_pair_forbidden(cats, int(r), oth):
				if _plan_pair_ok(cats, int(r), oth) and int(door_cnt.get(oth, 0)) == 0:
					cands2.push_front(e)
				else:
					cands2.push_back(e)
		for e in cands2:
			if served >= 3:
				break
			if _plan_edge_open(vr, e, "door", false):
				served += 1
			else:
				_plan_forced_door(e["runs"][0])
				served += 1
			stats["repairs"] = int(stats["repairs"]) + 1
	# The kitchen MUST be linked to dining, a corridor, the hall or the
	# living room (a lone bathroom link is never its only entry).
	for r in room_set:
		if _plan_cat_group(String(cats.get(int(r), ""))) != "kitchen":
			continue
		var good = false
		for run in runs:
			if String(run["kind"]) != "int":
				continue
			var ra = int(run["a"])
			var rb = int(run["b"])
			var oth = -1
			if ra == int(r):
				oth = rb
			elif rb == int(r):
				oth = ra
			else:
				continue
			var og = _plan_cat_group(String(cats.get(oth, "")))
			if og != "dining" and og != "corridor" and og != "hall" and og != "living":
				continue
			for h in run["holes"]:
				var tk = String(h[2])
				if tk == "door" or tk == "open":
					good = true
					break
			if good:
				break
		if good:
			continue
		var tiers3 = [[], []]
		for e in neighbors.get(int(r), []):
			var oth2 = int(e["b"])
			if oth2 == int(r):
				oth2 = int(e["a"])
			var og2 = _plan_cat_group(String(cats.get(oth2, "")))
			if og2 == "dining" or og2 == "corridor" or og2 == "hall":
				tiers3[0].append(e)
			elif og2 == "living":
				tiers3[1].append(e)
		var done_k = false
		for tier in tiers3:
			for e in tier:
				if _plan_edge_open(vr, e, "door", false):
					done_k = true
					break
				else:
					_plan_forced_door(e["runs"][0])
					done_k = true
					break
			if done_k:
				break
		if done_k:
			stats["repairs"] = int(stats["repairs"]) + 1
	# Never two openings between the same pair of rooms: duplicates are
	# removed, the "open" (or first) one wins.
	_plan_dedup_pair_openings(runs)
	# Doors on both sides of a corridor face each other when possible.
	_plan_align_corridor_doors(runs, cats)
	return stats


func _plan_dedup_pair_openings(runs: Array) -> void:
	var seen = {}
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var key = str(int(min(int(run["a"]), int(run["b"])))) + "_" \
			+ str(int(max(int(run["a"]), int(run["b"]))))
		if not seen.has(key):
			seen[key] = []
		for h in run["holes"]:
			var t = String(h[2])
			if t == "door" or t == "open":
				seen[key].append([run, h])
	for key in seen:
		var lst = seen[key]
		if lst.size() <= 1:
			continue
		var keep = 0
		for i in range(lst.size()):
			if String(lst[i][1][2]) == "open":
				keep = i
				break
		for i in range(lst.size()):
			if i == keep:
				continue
			lst[i][0]["holes"].erase(lst[i][1])


# For each corridor, doors on opposite walls are moved face to face when a
# legal aligned position exists (purely cosmetic, best effort).
func _plan_align_corridor_doors(runs: Array, cats: Dictionary) -> void:
	var by_corr = {}
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		var ci = -1
		if _plan_cat_group(String(cats.get(int(run["a"]), ""))) == "corridor":
			ci = int(run["a"])
		elif _plan_cat_group(String(cats.get(int(run["b"]), ""))) == "corridor":
			ci = int(run["b"])
		if ci < 0:
			continue
		if not by_corr.has(ci):
			by_corr[ci] = []
		by_corr[ci].append(run)
	var moves = 0
	for ci in by_corr:
		var lst = by_corr[ci]
		for i in range(lst.size()):
			var r1 = lst[i]
			for h1 in r1["holes"]:
				if String(h1[2]) != "door":
					continue
				var p1 = float(h1[0])
				var w1 = float(h1[1])
				if bool(r1["vert"]):
					p1 += float(r1["y0"])
				else:
					p1 += float(r1["x0"])
				for j in range(lst.size()):
					if moves >= 12:
						return
					if j == i:
						continue
					var r2 = lst[j]
					if bool(r2["vert"]) != bool(r1["vert"]):
						continue
					var line1 = 0
					var line2 = 0
					var o2 = 0.0
					if bool(r1["vert"]):
						line1 = int(r1["x"])
						line2 = int(r2["x"])
						o2 = float(r2["y0"])
					else:
						line1 = int(r1["y"])
						line2 = int(r2["y"])
						o2 = float(r2["x0"])
					var gap = int(abs(line2 - line1))
					if gap < 1 or gap > 2:
						continue
					# r2 must span the aligned position.
					var len2 = float(_plan_run_len(r2))
					if p1 < o2 or p1 + w1 > o2 + len2:
						continue
					# Already an aligned door there?
					var aligned = false
					var off_door = -1
					for k in range(r2["holes"].size()):
						var h2 = r2["holes"][k]
						if String(h2[2]) != "door":
							continue
						var p2 = float(h2[0])
						if bool(r2["vert"]):
							p2 += float(r2["y0"])
						else:
							p2 += float(r2["x0"])
						if abs(p2 - p1) <= 0.25:
							aligned = true
							break
						off_door = k
					if aligned or off_door < 0:
						continue
					# Move the off door face to face, restore on failure.
					var saved = r2["holes"][off_door]
					r2["holes"].remove(off_door)
					if _plan_try_hole(r2, p1 - o2, float(saved[1]), "door"):
						moves += 1
					else:
						r2["holes"].append(saved)
					break


# Rooms only reachable after long chains are re-connected directly to an
# adjacent hub at a lower depth; private capped rooms have their old chain
# door removed once the hub door is in (a door MOVE, not an addition).
func _plan_flatten_chains(runs: Array, cats: Dictionary) -> int:
	var repairs = 0
	for _pass in range(4):
		var edges = {}
		var ext_rooms = []
		var bounds = {}
		for run in runs:
			var a = int(run["a"])
			var b = int(run["b"])
			var has_door = false
			for h in run["holes"]:
				var t = String(h[2])
				if t == "door" or t == "open":
					has_door = true
					break
			if String(run["kind"]) == "ext":
				if has_door:
					ext_rooms.append(int(max(a, b)))
				continue
			var key = str(int(min(a, b))) + "_" + str(int(max(a, b)))
			if not bounds.has(key):
				bounds[key] = []
			bounds[key].append(run)
			if has_door:
				if not edges.has(a):
					edges[a] = []
				if not edges.has(b):
					edges[b] = []
				edges[a].append(b)
				edges[b].append(a)
		var depth = {}
		var queue = []
		for r0 in ext_rooms:
			if not depth.has(int(r0)):
				depth[int(r0)] = 0
				queue.append(int(r0))
		var qi = 0
		while qi < queue.size():
			var r1 = queue[qi]
			qi += 1
			if edges.has(r1):
				for o in edges[r1]:
					if not depth.has(int(o)):
						depth[int(o)] = int(depth[r1]) + 1
						queue.append(int(o))
		# The deepest room at depth >= 4 with an adjacent shallower hub.
		var worst = -1
		var worst_d = 3
		for r2 in depth:
			if int(depth[r2]) > worst_d:
				worst_d = int(depth[r2])
				worst = int(r2)
		if worst < 0:
			return repairs
		var target = -1
		var target_score = -1000
		for key in bounds:
			var ids = key.split("_")
			var oa = int(ids[0])
			var ob = int(ids[1])
			var oth = -1
			if oa == worst:
				oth = ob
			elif ob == worst:
				oth = oa
			else:
				continue
			if _plan_cap(_plan_cat_group(String(cats.get(oth, "")))) < 4:
				continue
			var od = int(depth.get(oth, 99))
			if od > worst_d - 2:
				continue
			# Legal pairs strongly preferred; shallower hubs next.
			var tsc = -od
			if _plan_pair_ok(cats, worst, oth):
				tsc += 100
			if tsc > target_score:
				target_score = tsc
				target = oth
		if target < 0:
			return repairs
		# Place the hub door, then for capped private rooms remove the old
		# chain door (toward a neighbor at equal or greater depth).
		var key2 = str(int(min(worst, target))) + "_" + str(int(max(worst, target)))
		var placed = false
		for run in bounds[key2]:
			if _plan_try_hole(run, stepify((float(_plan_run_len(run)) - 1.0) * 0.5, 0.5), 1.0, "door"):
				placed = true
				break
		if not placed:
			_plan_forced_door(bounds[key2][0])
			placed = true
		var grp = _plan_cat_group(String(cats.get(worst, "")))
		if _plan_cap(grp) == 0 and edges.has(worst):
			for o2 in edges[worst]:
				if int(depth.get(int(o2), 99)) < worst_d:
					continue
				var key3 = str(int(min(worst, int(o2)))) + "_" + str(int(max(worst, int(o2))))
				if not bounds.has(key3):
					continue
				var removed = false
				for run2 in bounds[key3]:
					var kept_h = []
					for h2 in run2["holes"]:
						var t2 = String(h2[2])
						if not removed and (t2 == "door" or t2 == "open"):
							removed = true
							continue
						kept_h.append(h2)
					run2["holes"] = kept_h
					if removed:
						break
				if removed:
					break
		repairs += 1
	return repairs


func _plan_unify_interior(vr, runs: Array, room_set: Dictionary, cats: Dictionary) -> int:
	var repairs = 0
	for _pass in range(16):
		# Components of the INTERIOR door graph only.
		var comp = {}
		var next_c = 0
		var edges = {}
		for run in runs:
			if String(run["kind"]) != "int":
				continue
			var has_door = false
			for h in run["holes"]:
				var t = String(h[2])
				if t == "door" or t == "open":
					has_door = true
					break
			if not has_door:
				continue
			var a = int(run["a"])
			var b = int(run["b"])
			if not edges.has(a):
				edges[a] = []
			if not edges.has(b):
				edges[b] = []
			edges[a].append(b)
			edges[b].append(a)
		for r in room_set:
			if comp.has(int(r)):
				continue
			var queue = [int(r)]
			comp[int(r)] = next_c
			var qi = 0
			while qi < queue.size():
				var cur = queue[qi]
				qi += 1
				if edges.has(cur):
					for o in edges[cur]:
						if not comp.has(int(o)):
							comp[int(o)] = next_c
							queue.append(int(o))
			next_c += 1
		if next_c <= 1:
			return repairs
		# Best interior boundary linking two different components: legal
		# pairs first, then the longest wall.
		var best = null
		var best_rank = -1
		for run in runs:
			if String(run["kind"]) != "int":
				continue
			var a2 = int(run["a"])
			var b2 = int(run["b"])
			if int(comp.get(a2, -1)) == int(comp.get(b2, -2)):
				continue
			if _plan_pair_forbidden(cats, a2, b2):
				continue
			var rank = _plan_run_len(run)
			if _plan_pair_ok(cats, a2, b2):
				rank += 1000
			if rank > best_rank:
				best_rank = rank
				best = run
		if best == null:
			return repairs
		if not _plan_opening_on_run(vr, best, "door", false):
			_plan_forced_door(best)
		repairs += 1
	return repairs


# Builds the door graph (rooms + an implicit exterior node) and forces doors
# until every room is reachable from outside.
func _plan_reachability_repair(runs: Array, room_set: Dictionary) -> int:
	var repairs = 0
	for _pass in range(room_set.size() + 2):
		# Reachable set: BFS from rooms with an exterior door/opening.
		var reach = {}
		var queue = []
		var edges = {}
		for run in runs:
			var has_door = false
			for h in run["holes"]:
				var t = String(h[2])
				if t == "door" or t == "open":
					has_door = true
					break
			if not has_door:
				continue
			var a = int(run["a"])
			var b = int(run["b"])
			if String(run["kind"]) == "ext":
				var inner = int(max(a, b))
				if not reach.has(inner):
					reach[inner] = true
					queue.append(inner)
			else:
				if not edges.has(a):
					edges[a] = []
				if not edges.has(b):
					edges[b] = []
				edges[a].append(b)
				edges[b].append(a)
		var qi = 0
		while qi < queue.size():
			var r = queue[qi]
			qi += 1
			if edges.has(r):
				for o in edges[r]:
					if not reach.has(int(o)):
						reach[int(o)] = true
						queue.append(int(o))
		var missing = []
		for r in room_set:
			if not reach.has(int(r)):
				missing.append(int(r))
		if missing.empty():
			return repairs
		# Force one door from an unreachable room toward the reachable set
		# (interior boundary preferred, exterior wall as fallback).
		var fixed = false
		for r in missing:
			var best_int = null
			var best_ext = null
			for run in runs:
				if int(run["a"]) != r and int(run["b"]) != r:
					continue
				if String(run["kind"]) == "int":
					var other = int(run["a"])
					if other == r:
						other = int(run["b"])
					if reach.has(other):
						if best_int == null or _plan_run_len(run) > _plan_run_len(best_int):
							best_int = run
				else:
					if best_ext == null or _plan_run_len(run) > _plan_run_len(best_ext):
						best_ext = run
			var target = best_int
			if target == null:
				target = best_ext
			if target != null:
				_plan_forced_door(target)
				repairs += 1
				fixed = true
				break
		if not fixed:
			return repairs
	return repairs


# ── Windows per category ────────────────────────────────────────────────────

func _plan_room_windows(vr, runs: Array, rooms: Array, cw: int, ch: int, cats: Dictionary, area_cells: int) -> int:
	var probs = {"living": 1.0, "bedroom": 1.0, "dining": 0.9, "kitchen": 0.85,
		"study": 0.8, "hall": 0.5, "bathroom": 0.35, "corridor": 0.25,
		"storage": 0.1, "closet": 0.0, "staircase": 0.05}
	var infos = _plan_room_infos(rooms, cw, ch)
	# Exterior runs grouped by their interior room.
	var by_room = {}
	var longest = null
	for run in runs:
		if String(run["kind"]) != "ext":
			continue
		if longest == null or _plan_run_len(run) > _plan_run_len(longest):
			longest = run
		var inner = int(max(int(run["a"]), int(run["b"])))
		if not by_room.has(inner):
			by_room[inner] = []
		by_room[inner].append(run)
	var placed = 0
	for r in by_room:
		var cat = _plan_cat_group(String(cats.get(int(r), "living")))
		var p = float(probs.get(cat, 0.5))
		if p <= 0.0 or not infos.has(int(r)):
			continue
		var cells = int(infos[int(r)]["cells"])
		var target = 1
		if cat == "living" or cat == "dining" or cat == "hall":
			target = int(clamp(1 + cells / 10, 1, 4))
		elif cat == "bedroom" or cat == "kitchen" or cat == "study":
			target = int(clamp(1 + cells / 16, 1, 2))
		if vr.randf() > p and cat != "bedroom" and cat != "living" and cat != "hall":
			continue
		var rr = by_room[r]
		_plan_shuffle(vr, rr)
		var got = 0
		for run in rr:
			if got >= target:
				break
			var len_r = _plan_run_len(run)
			var wl = int(clamp(1 + cells / 14, 1, int(min(4, max(1, len_r - 2)))))
			if len_r <= 2:
				if len_r == 2 and _plan_try_hole(run, 0.5, 1.0, "window"):
					got += 1
					placed += 1
				continue
			for _try in range(4):
				var lo = 1
				var hi = len_r - wl - 1
				if hi < lo:
					lo = 0
					hi = len_r - wl
				if _plan_try_hole(run, float(vr.randi_range(lo, int(max(lo, hi)))), wl, "window"):
					got += 1
					placed += 1
					break
	# A building always has at least one window.
	if placed == 0 and longest != null:
		var len_l = _plan_run_len(longest)
		var wl2 = int(min(2, max(1, len_l - 2)))
		if _plan_try_hole(longest, stepify(float(len_l - wl2) * 0.5, 0.5), wl2, "window"):
			placed = 1
	return placed


# ── Realism score ───────────────────────────────────────────────────────────

# Clips segments against the tower circles (world px): the part inside a
# circle is removed so diagonals and walls end exactly on the arc.
# Clips axis-aligned wall segments against the bevel triangles: an
# interior wall ending on a chamfered corner would otherwise poke
# through the diagonal. The diagonal crosses integer lattice points, so
# the clip is exact. Bevel cut edges themselves stop AT the triangle
# border and are untouched.
func _plan_clip_seg_tris(segs: Array, acx: int, acy: int) -> Array:
	if _plan_bevel_tris.empty():
		return segs
	var out = []
	for sg in segs:
		var parts = [[sg[0], sg[1]]]
		for tri in _plan_bevel_tris:
			var px = float(acx + int(tri[0])) * CELL
			var py = float(acy + int(tri[1])) * CELL
			var k = int(tri[2])
			var b = float(int(tri[3])) * CELL
			var sv = 1.0 if (k == 0 or k == 1) else -1.0
			var sh = 1.0 if (k == 0 or k == 2) else -1.0
			var next_p = []
			for pr in parts:
				var p0 = pr[0]
				var p1 = pr[1]
				if abs(p1.x - p0.x) < 1.0:
					# Vertical wall in the triangle's x band - but ONLY
					# if it actually ABUTS the chamfered corner edge
					# (one end on the y=py cut line). Unrelated walls
					# merely crossing the band (small or concave
					# footprints) must never be touched: clipping them
					# ate whole exterior wall stretches.
					var dx = (px - p0.x) * sh
					if dx <= 1.0 or dx >= b - 1.0:
						next_p.append(pr)
						continue
					var depth = b - dx
					var band0 = min(py, py - sv * depth)
					var band1 = max(py, py - sv * depth)
					_plan_seg_minus_band(p0, p1, false, band0, band1, next_p)
				elif abs(p1.y - p0.y) < 1.0:
					var dy = (py - p0.y) * sv
					if dy <= 1.0 or dy >= b - 1.0:
						next_p.append(pr)
						continue
					var depth2 = b - dy
					var band2 = min(px, px - sh * depth2)
					var band3 = max(px, px - sh * depth2)
					_plan_seg_minus_band(p0, p1, true, band2, band3, next_p)
				else:
					next_p.append(pr)
			parts = next_p
		for pr2 in parts:
			if pr2[0].distance_to(pr2[1]) > 4.0:
				out.append(pr2)
	return out


# Subtracts the [b0, b1] band (on x if along_x, else on y) from an
# axis-aligned segment, appending the surviving pieces.
func _plan_seg_minus_band(p0: Vector2, p1: Vector2, along_x: bool, b0: float, b1: float, out: Array) -> void:
	var a0 = p0.x if along_x else p0.y
	var a1 = p1.x if along_x else p1.y
	var lo = min(a0, a1)
	var hi = max(a0, a1)
	if hi <= b0 or lo >= b1:
		out.append([p0, p1])
		return
	var lo_p = p0 if a0 <= a1 else p1
	var hi_p = p1 if a0 <= a1 else p0
	if lo < b0:
		var cut0 = Vector2(b0, lo_p.y) if along_x else Vector2(lo_p.x, b0)
		out.append([lo_p, cut0])
	if hi > b1:
		var cut1 = Vector2(b1, hi_p.y) if along_x else Vector2(hi_p.x, b1)
		out.append([cut1, hi_p])


func _plan_clip_segs_to_arcs(segs: Array, arcs: Array) -> Array:
	if arcs.empty():
		return segs
	var out = []
	for seg in segs:
		# Axis-aligned walls are already handled by the quadrant-aware
		# carve: clipping them again would re-open the walls it kept.
		if abs(seg[1].x - seg[0].x) < 1.0 or abs(seg[1].y - seg[0].y) < 1.0:
			out.append(seg)
			continue
		var parts = [seg]
		for a in arcs:
			var c = a["c"]
			var r = float(a["r"])
			var next_parts = []
			for pr in parts:
				var p0 = pr[0]
				var p1 = pr[1]
				var tag = []
				if pr.size() > 2:
					tag = [pr[2]]
				var d = p1 - p0
				var f = p0 - c
				var qa = d.dot(d)
				if qa < 0.0001:
					next_parts.append(pr)
					continue
				var qb = 2.0 * f.dot(d)
				var qc = f.dot(f) - r * r
				var disc = qb * qb - 4.0 * qa * qc
				if disc <= 0.0:
					next_parts.append(pr)
					continue
				var sq = sqrt(disc)
				var t0 = clamp((-qb - sq) / (2.0 * qa), 0.0, 1.0)
				var t1 = clamp((-qb + sq) / (2.0 * qa), 0.0, 1.0)
				if t1 - t0 < 0.001:
					next_parts.append(pr)
					continue
				if t0 > 0.01:
					next_parts.append([p0, p0 + d * t0] + tag)
				if t1 < 0.99:
					next_parts.append([p0 + d * t1, p1] + tag)
			parts = next_parts
		for pr in parts:
			if pr[0].distance_to(pr[1]) > 8.0:
				out.append(pr)
	return out


# Small footprints, towers and bevels leave two reads-as-a-glitch
# artifacts after all the carving: AXIS wall stubs floating alone (or
# poking past the shell with one loose end), and openings whose host
# wall was carved away. Both are cleaned here, in place.
# - An endpoint is "anchored" when it touches another wall / opening
#   endpoint, lands ON another wall's body, or sits on a tower arc.
# - A wall with a loose end is trimmed back to its last real contact;
#   with no contact at all (and short), it is dropped entirely.
# - A window / door with no collinear wall support left is dropped.
# Point on the ARC, not merely on the circle: a wall end sitting in
# the arc's angular GAP (the tower mouth) is disconnected even though
# its radius matches.
func _plan_on_arc(a: Dictionary, p: Vector2, tol: float) -> bool:
	if abs(p.distance_to(a["c"]) - float(a["r"])) > tol:
		return false
	if not a.has("a0"):
		return true
	var span = fposmod(float(a["a1"]) - float(a["a0"]), TAU)
	if span < 0.001:
		span = TAU
	var d = fposmod((p - a["c"]).angle() - float(a["a0"]), TAU)
	# A point sitting EXACTLY on the a0 lip can land at TAU - epsilon
	# instead of 0 (float dust in fposmod): both ends of the wrap are
	# inside the sweep.
	return d <= span + 0.05 or d >= TAU - 0.05


# Nearest point ON the swept part of the arc.
func _plan_arc_closest(a: Dictionary, p: Vector2) -> Vector2:
	var vc = p - a["c"]
	if vc.length() < 1.0:
		vc = Vector2(1, 0)
	var ang = vc.angle()
	if a.has("a0"):
		var a0 = float(a["a0"])
		var span = fposmod(float(a["a1"]) - a0, TAU)
		if span < 0.001:
			span = TAU
		var d = fposmod(ang - a0, TAU)
		if d > span:
			# Off the sweep: snap to the nearer arc END.
			if d - span < TAU - d:
				ang = a0 + span
			else:
				ang = a0
	return a["c"] + Vector2(cos(ang), sin(ang)) * float(a["r"])


# Nearest attachable point for a loose end: another wall / opening
# endpoint, or the closest swept point of an arc (skip_arc excluded -
# an arc end must never bridge onto its own arc or seal its own mouth).
func _plan_bridge_target(p: Vector2, self_ref, anchors: Array, arcs: Array, skip_arc = null, long_walls: bool = false):
	# Wall-to-wall links stay SHORT (long ones would seal intended
	# open entrance gaps); links to an ARC may reach further - the
	# tower carve digs holes of two-three cells and an arc is never a
	# deliberate opening on the wall line.
	var best_q = null
	var best_d = CELL * 1.7
	if long_walls:
		# The SOURCE is an arc lip: the link itself involves an arc,
		# so the long reach applies to wall endpoints too (the lip of
		# the recurring field case sat 2.0 cells under its corner -
		# 77 px past the short cap).
		best_d = CELL * 3.2
	for anc in anchors:
		if anc[2] == self_ref:
			continue
		for oe in [anc[0], anc[1]]:
			var d = p.distance_to(oe)
			if d > 8.0 and d < best_d:
				best_d = d
				best_q = oe
	var best_da = CELL * 3.2
	var best_qa = null
	for a in arcs:
		if a == skip_arc:
			continue
		var q = _plan_arc_closest(a, p)
		var d2 = p.distance_to(q)
		if d2 > 8.0 and d2 < best_da:
			best_da = d2
			best_qa = q
	# The arc wins whenever it is the closer of the two.
	if best_qa != null and (best_q == null or best_da < best_d):
		return best_qa
	return best_q


func _plan_bridge_gaps(segs: Array, arcs: Array, wins: Array, doors: Array) -> void:
	var anchors = []
	for grp in [segs, wins, doors]:
		for sg in grp:
			anchors.append([sg[0], sg[1], sg])
	var links = []
	var linked_pts = []
	# Walls AND openings reach out: the gap often sits right below a
	# door whose far side lost its wall.
	for grp2 in [segs, wins, doors]:
		for sg2 in grp2:
			if abs(sg2[1].x - sg2[0].x) >= 1.0 and abs(sg2[1].y - sg2[0].y) >= 1.0:
				continue
			if sg2[0].distance_to(sg2[1]) < 4.0:
				continue
			for ei in range(2):
				var p = sg2[ei]
				if _plan_stub_anchored(p, sg2, anchors, arcs):
					continue
				# One link per neighbourhood: a fresh link's endpoints
				# anchor everything around them, or clustered loose
				# ends each spawn their own zigzag.
				var near_link = false
				for lp in linked_pts:
					if lp.distance_to(p) < 10.0:
						near_link = true
						break
				if near_link:
					continue
				var bq = _plan_bridge_target(p, sg2, anchors, arcs)
				if bq != null:
					links.append([p, bq])
					linked_pts.append(p)
					linked_pts.append(bq)
	# Arc ENDS reach out too: a tower mouth whose walls fell short
	# leaves the whole arc hanging free.
	for a in arcs:
		if not a.has("a0"):
			continue
		var span = fposmod(float(a["a1"]) - float(a["a0"]), TAU)
		if span < 0.001:
			continue
		for ae in [float(a["a0"]), float(a["a0"]) + span]:
			var p2 = a["c"] + Vector2(cos(ae), sin(ae)) * float(a["r"])
			var anch = false
			var anch_by = null
			for anc2 in anchors:
				if anc2[0].distance_to(p2) < 8.0 or anc2[1].distance_to(p2) < 8.0 \
						or _plan_pt_on_seg(p2, anc2[0], anc2[1], 6.0):
					anch = true
					anch_by = [anc2[0], anc2[1]]
					break
			if anch:
				continue
			var near_link2 = false
			for lp2 in linked_pts:
				if lp2.distance_to(p2) < 10.0:
					near_link2 = true
					break
			if near_link2:
				continue
			var bq2 = _plan_bridge_target(p2, null, anchors, arcs, a, true)
			if bq2 != null:
				links.append([p2, bq2])
				linked_pts.append(p2)
				linked_pts.append(bq2)
	for lk in links:
		segs.append(lk)


# One side inside the room grid, the other outside: the segment sits
# on the shell. rooms == -1 reads as outside (every inside cell is
# room-assigned by the fill passes before emit).
func _plan_seg_is_ext(sg, rooms_g: Array, acx: int, acy: int, cw: int, ch: int) -> bool:
	var mid = (sg[0] + sg[1]) * 0.5
	var dirv = (sg[1] - sg[0]).normalized()
	var n = Vector2(-dirv.y, dirv.x)
	var ins = 0
	for sgn in [-1.0, 1.0]:
		var p = mid + n * (CELL * 0.6 * sgn)
		var cx = int(floor(p.x / CELL)) - acx
		var cy = int(floor(p.y / CELL)) - acy
		if cx >= 0 and cy >= 0 and cx < cw and cy < ch \
				and int(rooms_g[cy * cw + cx]) >= 0:
			ins += 1
	return ins == 1


# Cuts a one-cell doorway dead-center into the longest EXTERIOR axis
# wall and records the door segment.
func _plan_emergency_door(segs: Array, doors: Array, rooms_g: Array, acx: int, acy: int, cw: int, ch: int) -> void:
	var best = -1
	var best_len = 0.0
	for si in range(segs.size()):
		var sg = segs[si]
		if abs(sg[1].x - sg[0].x) >= 1.0 and abs(sg[1].y - sg[0].y) >= 1.0:
			continue
		if not _plan_seg_is_ext(sg, rooms_g, acx, acy, cw, ch):
			continue
		var l = sg[0].distance_to(sg[1])
		if l > best_len:
			best_len = l
			best = si
	if best < 0 or best_len < CELL * 2.0:
		return
	var sg2 = segs[best]
	var mid = (sg2[0] + sg2[1]) * 0.5
	var dirv = (sg2[1] - sg2[0]).normalized()
	var a = mid - dirv * CELL * 0.5
	var b = mid + dirv * CELL * 0.5
	var p1 = sg2[1]
	segs[best] = [sg2[0], a]
	segs.append([b, p1])
	doors.append([a, b])


func _plan_trim_stubs(segs: Array, arcs: Array, wins: Array, doors: Array) -> void:
	# ANCHOR SNAPSHOT: every segment of every orientation (diagonals
	# included - walls legitimately END on chamfer diagonals) plus the
	# openings. All decisions are taken against this frozen picture,
	# then applied: no cascade where trimming one wall unanchors the
	# next around the whole shell.
	var anchors = []
	for grp in [segs, wins, doors]:
		for sg in grp:
			anchors.append([sg[0], sg[1], sg])
	var drops = []
	var trims = []
	for si in range(segs.size()):
		var sg2 = segs[si]
		var horiz = abs(sg2[1].y - sg2[0].y) < 1.0
		var vert = abs(sg2[1].x - sg2[0].x) < 1.0
		if not horiz and not vert:
			continue
		var seg_len = sg2[0].distance_to(sg2[1])
		if seg_len < 4.0:
			continue
		var loose = []
		for ei in range(2):
			if not _plan_stub_anchored(sg2[ei], sg2, anchors, arcs):
				loose.append(ei)
		if loose.empty():
			continue
		if loose.size() == 2:
			# Fully floating: only ever true for SHORT debris.
			if seg_len < CELL * 2.1:
				drops.append(si)
			continue
		var ei2 = int(loose[0])
		var pin = sg2[1 - ei2]
		var dirv = (sg2[ei2] - pin) / seg_len
		var best_t = -1.0
		for anc in anchors:
			if anc[2] == sg2:
				continue
			for cnd in _plan_seg_contacts(pin, sg2[ei2], [anc[0], anc[1]]):
				var t = (cnd - pin).dot(dirv)
				if t > 8.0 and t < seg_len - 4.0 and t > best_t:
					best_t = t
		for a in arcs:
			var fo = pin - a["c"]
			var r = float(a["r"])
			var qb = 2.0 * fo.dot(dirv)
			var qc = fo.dot(fo) - r * r
			var disc = qb * qb - 4.0 * qc
			if disc > 0.0:
				for sgn in [-1.0, 1.0]:
					var t2 = (-qb + sgn * sqrt(disc)) * 0.5
					# Up to seg_len + 4: a wall DYING exactly on the
					# circle is a contact, not a stub (the trim then
					# resolves to a no-op at the endpoint itself).
					if t2 > 8.0 and t2 < seg_len + 4.0 and t2 > best_t:
						best_t = min(t2, seg_len)
		if best_t > 0.0 and seg_len - best_t < CELL * 2.05:
			# Only a SHORT overhang past the last contact is a poke:
			# anything longer is a real wall stretch, left alone.
			trims.append([si, ei2, pin + dirv * best_t])
		elif best_t < 0.0 and seg_len < CELL * 2.1:
			drops.append(si)
	for tr in trims:
		segs[int(tr[0])][int(tr[1])] = tr[2]
	drops.sort()
	drops.invert()
	for di in drops:
		segs.remove(int(di))
	# Openings whose host wall disappeared float in the air: drop them.
	for grp2 in [wins, doors]:
		for oi in range(grp2.size() - 1, -1, -1):
			if not _plan_opening_supported(grp2[oi], segs):
				grp2.remove(oi)


func _plan_stub_anchored(p: Vector2, self_sg, anchors: Array, arcs: Array) -> bool:
	for anc in anchors:
		if anc[2] == self_sg:
			continue
		# Endpoint-to-endpoint or endpoint-on-body both anchor.
		if anc[0].distance_to(p) < 8.0 or anc[1].distance_to(p) < 8.0:
			return true
		if _plan_pt_on_seg(p, anc[0], anc[1], 6.0):
			return true
	for a in arcs:
		if _plan_on_arc(a, p, 12.0):
			return true
	return false


func _plan_pt_on_seg(p: Vector2, a: Vector2, b: Vector2, tol: float) -> bool:
	var ab = b - a
	var l = ab.length()
	if l < 1.0:
		return false
	var t = (p - a).dot(ab) / (l * l)
	if t < -0.01 or t > 1.01:
		return false
	return (a + ab * t).distance_to(p) < tol


# Contact points of the [pin, pe] run with another axis segment:
# perpendicular crossing point, or the other's endpoints when they lie
# on the run.
func _plan_seg_contacts(pin: Vector2, pe: Vector2, other) -> Array:
	var out = []
	for oe in [other[0], other[1]]:
		if _plan_pt_on_seg(oe, pin, pe, 4.0):
			out.append(oe)
	var run_h = abs(pe.y - pin.y) < 1.0
	var oth_h = abs(other[1].y - other[0].y) < 1.0
	if run_h != oth_h:
		var cross = Vector2(other[0].x, pin.y) if run_h else Vector2(pin.x, other[0].y)
		if _plan_pt_on_seg(cross, pin, pe, 4.0) and _plan_pt_on_seg(cross, other[0], other[1], 4.0):
			out.append(cross)
	return out


func _plan_opening_supported(op, segs: Array) -> bool:
	var oh = abs(op[1].y - op[0].y) < 1.0
	for sg in segs:
		var sh = abs(sg[1].y - sg[0].y) < 1.0
		if sh != oh:
			continue
		# Same line and touching / adjacent along it.
		if oh:
			if abs(sg[0].y - op[0].y) > 4.0:
				continue
			var lo = min(sg[0].x, sg[1].x) - 8.0
			var hi = max(sg[0].x, sg[1].x) + 8.0
			if max(op[0].x, op[1].x) >= lo and min(op[0].x, op[1].x) <= hi:
				return true
		else:
			if abs(sg[0].x - op[0].x) > 4.0:
				continue
			var lo2 = min(sg[0].y, sg[1].y) - 8.0
			var hi2 = max(sg[0].y, sg[1].y) + 8.0
			if max(op[0].y, op[1].y) >= lo2 and min(op[0].y, op[1].y) <= hi2:
				return true
	return false


# Diagonal segments left unconnected after all the cutting float in the
# air and read as glitches: drop them. Axis-aligned walls always stay.
func _plan_prune_diagonals(segs: Array, arcs: Array, wins: Array = [], doors: Array = []) -> Array:
	var walls = []
	for sg in segs:
		if abs(sg[1].x - sg[0].x) < 1.0 or abs(sg[1].y - sg[0].y) < 1.0:
			walls.append(sg)
	# Openings count as anchors too: a door or window punched right next
	# to a chamfered corner leaves a gap in the WALL segments, but the
	# wall line is still there - pruning the diagonal for it cascaded
	# into missing exterior stretches.
	for op in wins:
		walls.append(op)
	for op in doors:
		walls.append(op)
	# Alcove halves live or die as a pair: a lone half is a glitch.
	var alc_groups = {}
	for sg in segs:
		if sg.size() > 2 and not (abs(sg[1].x - sg[0].x) < 1.0 or abs(sg[1].y - sg[0].y) < 1.0):
			var tg = String(sg[2])
			if not alc_groups.has(tg):
				alc_groups[tg] = []
			alc_groups[tg].append(sg)
	var valid_tags = {}
	for tg in alc_groups:
		var g = alc_groups[tg]
		if g.size() != 2:
			continue
		var ok = true
		for sg in g:
			if not (_plan_pt_anchored(sg[0], walls, arcs, sg) or _plan_pt_anchored(sg[1], walls, arcs, sg)):
				ok = false
				break
		if ok:
			valid_tags[tg] = true
	# Chained chamfers: two bevel diagonals meeting tip-to-tip (staircase
	# corners) anchor each OTHER, not a wall. An endpoint therefore also
	# counts as anchored when it touches the endpoint of another diagonal
	# that itself has at least one wall/arc anchor - a continuous
	# wall->diag->diag->wall chain survives, while fully floating chains
	# are still pruned.
	var dinfo = []
	for sg in segs:
		if abs(sg[1].x - sg[0].x) < 1.0 or abs(sg[1].y - sg[0].y) < 1.0:
			continue
		if sg.size() > 2:
			continue
		dinfo.append([sg, _plan_pt_anchored(sg[0], walls, arcs, sg),
			_plan_pt_anchored(sg[1], walls, arcs, sg)])
	var out = []
	for sg in segs:
		if abs(sg[1].x - sg[0].x) < 1.0 or abs(sg[1].y - sg[0].y) < 1.0:
			out.append([sg[0], sg[1]])
			continue
		if sg.size() > 2:
			if valid_tags.has(String(sg[2])):
				out.append([sg[0], sg[1]])
			continue
		var a0 = _plan_pt_anchored(sg[0], walls, arcs, sg)
		var a1 = _plan_pt_anchored(sg[1], walls, arcs, sg)
		if not a0:
			a0 = _plan_pt_on_diag_end(sg[0], dinfo, sg)
		if not a1:
			a1 = _plan_pt_on_diag_end(sg[1], dinfo, sg)
		if a0 and a1:
			out.append([sg[0], sg[1]])
	return out


# True when pt coincides with an endpoint of ANOTHER diagonal that has
# at least one wall/arc anchor of its own.
func _plan_pt_on_diag_end(pt: Vector2, dinfo: Array, self_sg) -> bool:
	for d in dinfo:
		if d[0] == self_sg:
			continue
		if not (bool(d[1]) or bool(d[2])):
			continue
		if pt.distance_to(d[0][0]) < 4.0 or pt.distance_to(d[0][1]) < 4.0:
			return true
	return false


func _plan_pt_anchored(p: Vector2, walls: Array, arcs: Array, self_seg) -> bool:
	for w in walls:
		if w == self_seg:
			continue
		var q = Geometry.get_closest_point_to_segment_2d(p, w[0], w[1])
		if q.distance_to(p) < 10.0:
			return true
	for a in arcs:
		if abs(p.distance_to(a["c"]) - float(a["r"])) < 10.0:
			return true
	return false


func _plan_score(runs: Array, rooms: Array, cw: int, ch: int, cats: Dictionary, stats: Dictionary, win_count: int, area_cells: int) -> float:
	var score = 10.0
	score -= float(stats["repairs"]) * 2.0
	score += float(int(stats["open"])) * 0.5
	score += float(int(stats.get("bed_corr", 0))) * 1.0
	var infos = _plan_room_infos(rooms, cw, ch)
	var pairs = _plan_adjacent_pairs(rooms, cw, ch)
	# Door graph: edges, door counts, exterior-doored rooms, exterior wall
	# length per room.
	var edges = {}
	var door_cnt = {}
	var ext_len = {}
	var ext_doors = []
	for run in runs:
		var a = int(run["a"])
		var b = int(run["b"])
		var has_door = false
		for h in run["holes"]:
			var t = String(h[2])
			if t == "door" or t == "open":
				has_door = true
				break
		if String(run["kind"]) == "ext":
			var inner = int(max(a, b))
			ext_len[inner] = int(ext_len.get(inner, 0)) + _plan_run_len(run)
			if has_door:
				ext_doors.append(inner)
				door_cnt[inner] = int(door_cnt.get(inner, 0)) + 1
		elif has_door:
			if not edges.has(a):
				edges[a] = []
			if not edges.has(b):
				edges[b] = []
			edges[a].append(b)
			edges[b].append(a)
			door_cnt[a] = int(door_cnt.get(a, 0)) + 1
			door_cnt[b] = int(door_cnt.get(b, 0)) + 1
	# Privacy depth: BFS from the entrance over the real door graph, scored
	# against the expected depth of each group (1 level of tolerance).
	var depth = {}
	var queue = []
	for r0 in ext_doors:
		if not depth.has(int(r0)):
			depth[int(r0)] = 0
			queue.append(int(r0))
	var qi = 0
	while qi < queue.size():
		var r1 = queue[qi]
		qi += 1
		if edges.has(r1):
			for o in edges[r1]:
				if not depth.has(int(o)):
					depth[int(o)] = int(depth[r1]) + 1
					queue.append(int(o))
	var exp_depth = {"hall": 0, "corridor": 1, "living": 1, "dining": 2, "kitchen": 2,
		"study": 2, "storage": 2, "bedroom": 3, "bathroom": 3, "closet": 3, "staircase": 2}
	var kitchen_id = -1
	var dining_id = -1
	var master_id = -1
	var privates = []
	for r in infos:
		var raw = String(cats.get(int(r), ""))
		var cat = _plan_cat_group(raw)
		if cat == "kitchen":
			kitchen_id = int(r)
		elif cat == "dining":
			dining_id = int(r)
		if raw == "master":
			master_id = int(r)
		if cat == "bedroom" or cat == "bathroom" or cat == "closet":
			privates.append(int(r))
		# Privacy depth match.
		if depth.has(int(r)) and exp_depth.has(cat):
			var dd = abs(int(depth[int(r)]) - int(exp_depth[cat]))
			if dd > 1:
				score -= float(dd - 1) * 0.6
		# Proportions, weighted by room importance.
		if cat != "corridor" and int(infos[r]["cells"]) > 4:
			var ratio = float(max(int(infos[r]["bw"]), int(infos[r]["bh"]))) \
				/ float(max(1, min(int(infos[r]["bw"]), int(infos[r]["bh"]))))
			if ratio > 3.5:
				var wgt = 2.0
				if cat == "living" or cat == "dining" or cat == "bedroom":
					wgt = 3.0
				elif cat == "storage" or cat == "closet":
					wgt = 0.8
				score -= wgt
		# Exterior wall allocation: facade-deserving rooms landlocked is bad,
		# service rooms tucked inside is good.
		var el = int(ext_len.get(int(r), 0))
		if cat == "living" and el == 0:
			score -= 3.0
		elif (cat == "dining" or cat == "bedroom" or cat == "study" or cat == "kitchen") and el == 0:
			score -= 2.0
		elif (cat == "closet" or cat == "storage" or cat == "staircase") and el == 0:
			score += 0.5
		# Terminal rooms must not become passages.
		if cat == "bedroom" or cat == "bathroom" or cat == "closet" \
				or cat == "storage" or cat == "staircase":
			var dc = int(door_cnt.get(int(r), 0))
			if dc > 1:
				score -= float(dc - 1) * 1.5
		# Furniture feasibility: a room must plausibly hold its furniture.
		var need_w = 0
		var need_h = 0
		if cat == "living":
			need_w = 3
			need_h = 3
		elif cat == "bedroom" or cat == "dining":
			need_w = 2
			need_h = 3
		elif cat == "kitchen":
			need_w = 2
			need_h = 2
		elif cat == "bathroom":
			need_w = 1
			need_h = 2
		if need_w > 0 and not _plan_rect_fits(rooms, cw, ch, int(r), need_w, need_h) \
				and not _plan_rect_fits(rooms, cw, ch, int(r), need_h, need_w):
			score -= 2.0
	# Companions: rooms that belong together should touch.
	if kitchen_id >= 0 and dining_id >= 0 and _plan_is_adjacent(pairs, kitchen_id, dining_id):
		score += 3.0
	# The dining room comes first, the kitchen behind it.
	if kitchen_id >= 0 and dining_id >= 0 and depth.has(kitchen_id) and depth.has(dining_id):
		if int(depth[kitchen_id]) < int(depth[dining_id]):
			score -= 2.0
		elif int(depth[dining_id]) < int(depth[kitchen_id]):
			score += 1.0
	for r in infos:
		var raw2 = String(cats.get(int(r), ""))
		if raw2 == "pantry" and kitchen_id >= 0 and _plan_is_adjacent(pairs, int(r), kitchen_id):
			score += 1.5
		elif raw2 == "bathroom" and master_id >= 0 and _plan_is_adjacent(pairs, int(r), master_id):
			score += 2.0
		elif (raw2 == "closet" or raw2 == "linen") and master_id >= 0 and _plan_is_adjacent(pairs, int(r), master_id):
			score += 1.0
		elif raw2 == "workshop":
			for r2 in infos:
				if String(cats.get(int(r2), "")) == "storage" and _plan_is_adjacent(pairs, int(r), int(r2)):
					score += 1.0
					break
	# Day/night separation: private rooms clustering together is rewarded,
	# a bedroom glued to the kitchen is not.
	var priv_adj = 0
	for i in range(privates.size()):
		for j in range(i + 1, privates.size()):
			if _plan_is_adjacent(pairs, privates[i], privates[j]):
				priv_adj += 1
	score += float(min(priv_adj, 5)) * 0.4
	if kitchen_id >= 0:
		for r in privates:
			if _plan_cat_group(String(cats.get(r, ""))) == "bedroom" \
					and _plan_is_adjacent(pairs, r, kitchen_id):
				score -= 1.0
	# Corridor presence must follow the Corridor Density slider: at high
	# density a corridor-less variant is heavily punished.
	if _plan_corr >= 0.35:
		var has_corr = false
		for r in infos:
			if _plan_cat_group(String(cats.get(int(r), ""))) == "corridor":
				has_corr = true
				break
		if has_corr:
			score += _plan_corr * 3.0
		else:
			score -= _plan_corr * 6.0
	# Distribution efficiency: high branching from hubs, shallow depths.
	var n_rooms = 0
	var depth_sum = 0
	var direct = 0
	for r in infos:
		var g = _plan_cat_group(String(cats.get(int(r), "")))
		if g == "hall" or g == "corridor":
			continue
		n_rooms += 1
		var d2 = int(depth.get(int(r), 3))
		depth_sum += d2
		if d2 >= 4:
			score -= 1.0
		# Directly served by a distribution node?
		var served = d2 <= 0
		if edges.has(int(r)):
			for o in edges[int(r)]:
				if _plan_cap(_plan_cat_group(String(cats.get(int(o), "")))) >= 4:
					served = true
					break
		if served:
			direct += 1
		elif d2 >= 2 and edges.has(int(r)):
			# Reached only through ordinary rooms.
			var only_ordinary = true
			for o in edges[int(r)]:
				if int(depth.get(int(o), 99)) < d2 \
						and _plan_cap(_plan_cat_group(String(cats.get(int(o), "")))) > 0:
					only_ordinary = false
					break
			if only_ordinary:
				score -= 1.0
	if n_rooms > 0:
		var mean_d = float(depth_sum) / float(n_rooms)
		if mean_d > 2.2:
			score -= (mean_d - 2.2) * 2.0
		score += float(direct) / float(n_rooms) * 3.0
	# Window adequacy: roughly one window per 9 cells of floor.
	var target_w = float(area_cells) / 9.0
	score -= abs(float(win_count) - target_w) * 0.2
	score += _plan_score_archetype(infos, pairs, cats, area_cells)
	return score


# Archetype-driven scoring: derived entirely from the program (no extra
# data). Rewards what makes each archetype recognizable - many uniform
# signature rooms sitting on the circulation, and a landmark hall that
# really dominates the floor area. The best of the interior variants
# then LOOKS like the archetype instead of merely being named like it.
func _plan_score_archetype(infos: Dictionary, pairs: Dictionary, cats: Dictionary, area_cells: int) -> float:
	if _plan_archetype.empty():
		return 0.0
	var sc = 0.0
	var program = _plan_archetype.get("program", null)
	if program != null:
		var rep_grp = _plan_cat_group(String(program.get("repeat", ["bedroom", "M"])[0]))
		var reps = []
		var corr_rooms = []
		for r in cats:
			var g = _plan_cat_group(String(cats[r]))
			if g == rep_grp and infos.has(int(r)):
				reps.append(int(r))
			elif g == "corridor" or g == "hall":
				corr_rooms.append(int(r))
		if reps.size() >= 3:
			# The repetition exists: reward the count...
			sc += 1.5 + float(min(reps.size(), 10)) * 0.3
			# ...and its uniformity (low relative size spread).
			var mean = 0.0
			for r2 in reps:
				mean += float(infos[r2]["cells"])
			mean /= float(reps.size())
			var varr = 0.0
			for r3 in reps:
				var dv = float(infos[r3]["cells"]) - mean
				varr += dv * dv
			var rel = sqrt(varr / float(reps.size())) / max(mean, 1.0)
			# Archetypes wanting a strictly even signature wing (inn
			# guest rooms) raise uniform_w: spread hurts a lot more.
			sc -= rel * 4.0 * float(_plan_archetype.get("uniform_w", 1.0))
			# Signature rooms belong ON the circulation.
			for r4 in reps:
				var on_circ = false
				for cr in corr_rooms:
					if _plan_is_adjacent(pairs, r4, cr):
						on_circ = true
						break
				if on_circ:
					sc += 0.5
				else:
					sc -= 0.7
			# Clustered signature wing: repeats want to sit TOGETHER (an
			# inn's guest wing), never scattered across the plan.
			var cl_w = float(_plan_archetype.get("repeat_cluster", 0.0))
			if cl_w > 0.0:
				for ri in range(reps.size()):
					var buddies = 0
					for rj in range(reps.size()):
						if ri != rj and _plan_is_adjacent(pairs, int(reps[ri]), int(reps[rj])):
							buddies += 1
					if buddies > 0:
						sc += 0.3 * cl_w
					else:
						sc -= 0.8 * cl_w
	if bool(_plan_archetype.get("hall_rect", false)):
		# The common room must stay LONG AND WIDE, no narrow throat: a
		# variant whose hall lost its clean proportions is punished.
		for rh2 in cats:
			if _plan_cat_group(String(cats[rh2])) != "hall":
				continue
			if not infos.has(int(rh2)):
				continue
			var ih = infos[int(rh2)]
			var bwh = float(int(ih["bw"]))
			var bhh = float(int(ih["bh"]))
			if bwh < 1.0 or bhh < 1.0:
				continue
			var fill_h = float(int(ih["cells"])) / (bwh * bhh)
			if fill_h < 0.82:
				sc -= 3.0
			if max(bwh, bhh) > min(bwh, bhh) * 2.2:
				sc -= 2.0
	if bool(_plan_archetype.get("kitchen_by_hall", false)):
		# The kitchen serves the common room DIRECTLY: a variant whose
		# kitchen does not touch the hall is heavily punished.
		var halls_k = []
		var kitchens_k = []
		for rk in cats:
			var gk = _plan_cat_group(String(cats[rk]))
			if gk == "hall":
				halls_k.append(int(rk))
			elif gk == "kitchen":
				kitchens_k.append(int(rk))
		if not kitchens_k.empty() and not halls_k.empty():
			var touch_k = false
			for kk in kitchens_k:
				for hk in halls_k:
					if _plan_is_adjacent(pairs, kk, hk):
						touch_k = true
						break
				if touch_k:
					break
			if touch_k:
				sc += 1.5
			else:
				sc -= 5.0
	var hs = float(_plan_archetype.get("hall_scale", 1.0))
	if hs > 1.0:
		var hall_cells = 0
		for r5 in cats:
			if String(cats[r5]) == "hall" and infos.has(int(r5)):
				hall_cells = int(max(hall_cells, int(infos[int(r5)]["cells"])))
		var share = float(hall_cells) / float(max(area_cells, 1))
		var want = clamp(0.055 * hs, 0.08, 0.3)
		if hall_cells == 0:
			sc -= 4.0
		elif share >= want:
			sc += 3.0
		elif share < want * 0.5:
			sc -= 2.5
		else:
			sc += 3.0 * (share - want * 0.5) / (want * 0.5)
	return sc


# Does a solid w x h block of the given room exist anywhere in it?
func _plan_rect_fits(rooms: Array, cw: int, ch: int, r: int, w: int, h: int) -> bool:
	for y in range(ch - h + 1):
		for x in range(cw - w + 1):
			if rooms[y * cw + x] != r:
				continue
			var ok = true
			for yy in range(y, y + h):
				for xx in range(x, x + w):
					if rooms[yy * cw + xx] != r:
						ok = false
						break
				if not ok:
					break
			if ok:
				return true
	return false


# Axis intervals of [a, b) excluding the corridor bands along that axis.
func _plan_intervals(a: int, b: int, corridors: Array, horizontal_axis: bool) -> Array:
	var cuts = []
	for c in corridors:
		var c0 = int(c.position.x)
		var c1 = int(c.position.x + c.size.x)
		if not horizontal_axis:
			c0 = int(c.position.y)
			c1 = int(c.position.y + c.size.y)
		# Only bands that don't span the whole axis are cuts.
		if c1 - c0 < b - a:
			cuts.append([c0, c1])
	cuts.sort_custom(self, "_plan_hole_sort")
	var out = []
	var pos = a
	for c in cuts:
		if c[0] > pos:
			out.append([pos, c[0]])
		pos = int(max(pos, c[1]))
	if pos < b:
		out.append([pos, b])
	if out.empty():
		out.append([a, b])
	return out


func _plan_zeroed_ints(n: int) -> Array:
	var out = []
	out.resize(n)
	for i in range(n):
		out[i] = 0
	return out


func _plan_fill_rect(mask: Array, cw: int, ch: int, x: int, y: int, w: int, h: int, v: int) -> void:
	var x1 = int(clamp(x + w, 0, cw))
	var y1 = int(clamp(y + h, 0, ch))
	var x0 = int(clamp(x, 0, cw))
	var y0 = int(clamp(y, 0, ch))
	for yy in range(y0, y1):
		for xx in range(x0, x1):
			mask[yy * cw + xx] = v


func _plan_erode_thin(mask: Array, cw: int, ch: int) -> void:
	# Removes 1-cell-wide protrusions: inside cells with 3+ orthogonal
	# outside neighbors are eroded until stable (kills bumps and thin
	# fingers sticking out of the footprint).
	for _pass in range(10):
		var marks = []
		for i in range(cw * ch):
			if mask[i] != 1:
				continue
			var y = i / cw
			var x = i - y * cw
			var outsiders = 0
			for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch \
						or mask[nb[1] * cw + nb[0]] == 0:
					outsiders += 1
			if outsiders >= 3:
				marks.append(i)
		if marks.empty():
			break
		for i in marks:
			mask[i] = 0


# A corridor keeps ONE width all along: any (wd+1) x (wd+1) solid corridor
# block is a bulge, whose best-connected cell is given back to an adjacent
# room (or a fresh room id when the bulge is interior).
func _plan_merge_touching_corridors(rooms: Array, cw: int, ch: int, protected: Dictionary, circ_cat: Dictionary) -> bool:
	var changed = false
	for _pass in range(12):
		var pair = null
		for y in range(ch):
			if pair != null:
				break
			for x in range(cw):
				var r = rooms[y * cw + x]
				if r < 0 or not _plan_corr_ids.has(r):
					continue
				for nb in [[x + 1, y], [x, y + 1]]:
					if nb[0] >= cw or nb[1] >= ch:
						continue
					var o = rooms[nb[1] * cw + nb[0]]
					if o >= 0 and o != r and _plan_corr_ids.has(o):
						pair = [int(min(r, o)), int(max(r, o))]
						break
				if pair != null:
					break
		if pair == null:
			break
		for i in range(cw * ch):
			if rooms[i] == pair[1]:
				rooms[i] = pair[0]
		protected.erase(pair[1])
		circ_cat.erase(pair[1])
		_plan_corr_ids.erase(pair[1])
		changed = true
	return changed


# A non-corridor room whose only neighbors are corridors/outside annexes
# the corridor cells separating it from the nearest normal room across.
func _plan_fix_isolated_rooms(rooms: Array, cw: int, ch: int, protected: Dictionary, circ_cat: Dictionary) -> bool:
	var changed = false
	for _pass in range(4):
		var infos = _plan_room_infos(rooms, cw, ch)
		var fixed = false
		for r in infos:
			if _plan_corr_ids.has(int(r)) or protected.has(int(r)):
				continue
			var has_room_nb = false
			for i in range(cw * ch):
				if rooms[i] != int(r):
					continue
				var y = i / cw
				var x = i - y * cw
				for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
					if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
						continue
					var o = rooms[nb[1] * cw + nb[0]]
					if o >= 0 and o != int(r) and not _plan_corr_ids.has(o):
						has_room_nb = true
						break
				if has_room_nb:
					break
			if has_room_nb:
				continue
			# Annex: shortest corridor crossing (1-2 cells) reaching a room.
			var best = null
			for i in range(cw * ch):
				if rooms[i] != int(r):
					continue
				var y2 = i / cw
				var x2 = i - y2 * cw
				for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
					var cells = []
					var cx = x2 + d[0]
					var cy = y2 + d[1]
					var ok = false
					for _step in range(2):
						if cx < 0 or cx >= cw or cy < 0 or cy >= ch:
							break
						var o2 = rooms[cy * cw + cx]
						if o2 >= 0 and _plan_corr_ids.has(o2):
							cells.append(cy * cw + cx)
							cx += d[0]
							cy += d[1]
							continue
						if o2 >= 0 and o2 != int(r) and not protected.has(o2):
							ok = true
						break
					if ok and cells.size() > 0 and (best == null or cells.size() < best.size()):
						best = cells
			if best != null:
				for idx in best:
					rooms[idx] = int(r)
				fixed = true
				changed = true
		if not fixed:
			break
	return changed


# Minimum room count for the floor area: small homes (single BSP leaf
# under eff_max) collapsed into one big living room. The biggest room is
# re-split with a max FORCED below its larger dimension (the generic cap
# of big/3 never triggered "must" on 10x10-or-less homes), falling back
# to a split-min of 2 when room_min cannot cut the room at all.
func _plan_min_room_count(rng, mask: Array, rooms: Array, cw: int, ch: int, protected: Dictionary, circ_cat: Dictionary, area_cells: int, bsp_min: int) -> Array:
	var want_rooms = int(clamp(area_cells / 15, 2, 7))
	# Tiny structures are content with ONE room (this pass force-splits
	# down to min_s = 2 to reach its quota, silently undoing every
	# upstream size floor - the 4x4 cottages cut into four closets came
	# from HERE, not from the main BSP).
	if area_cells <= 32:
		want_rooms = 1
	elif area_cells <= 60:
		want_rooms = int(min(want_rooms, 2))
	for _mr in range(4):
		var infos_m = _plan_room_infos(rooms, cw, ch)
		var n_free = 0
		var biggest_m = -1
		var big_sz = 0
		for rm in infos_m:
			if protected.has(int(rm)):
				continue
			n_free += 1
			if int(infos_m[rm]["cells"]) > big_sz:
				big_sz = int(infos_m[rm]["cells"])
				biggest_m = int(rm)
		if n_free >= want_rooms or biggest_m < 0 or big_sz < 8:
			break
		var inf_m = infos_m[biggest_m]
		var dim_max = int(max(int(inf_m["bw"]), int(inf_m["bh"])))
		var min_s = bsp_min
		if dim_max < min_s * 2:
			min_s = 2
		if dim_max < min_s * 2:
			break
		var forced_max = int(max(min_s, dim_max - 1))
		var leaves_m = []
		_plan_bsp(rng, Rect2(int(inf_m["x0"]), int(inf_m["y0"]), int(inf_m["bw"]), int(inf_m["bh"])),
			min_s, forced_max, leaves_m)
		if leaves_m.size() < 2:
			break
		var nid = 0
		for i3 in range(cw * ch):
			if rooms[i3] >= nid:
				nid = rooms[i3] + 1
		for li2 in range(leaves_m.size()):
			var lr2 = leaves_m[li2]
			for y5 in range(int(lr2.position.y), int(lr2.position.y + lr2.size.y)):
				for x5 in range(int(lr2.position.x), int(lr2.position.x + lr2.size.x)):
					if x5 >= 0 and x5 < cw and y5 >= 0 and y5 < ch \
							and rooms[y5 * cw + x5] == biggest_m:
						rooms[y5 * cw + x5] = nid + li2
		rooms = _plan_relabel_remap(mask, rooms, cw, ch, protected, circ_cat)
	return rooms


func _plan_refresh_corr_ids(circ_cat: Dictionary) -> void:
	_plan_corr_ids = {}
	for k in circ_cat:
		if String(circ_cat[k]) == "corridor":
			_plan_corr_ids[int(k)] = true


func _plan_enforce_corridor_width(rooms: Array, cw: int, ch: int, protected: Dictionary, circ_cat: Dictionary, wd: int) -> bool:
	var bs = wd + 1
	var next_id = 0
	for i in range(cw * ch):
		if rooms[i] >= next_id:
			next_id = rooms[i] + 1
	var changed = false
	for _pass in range(60):
		var fixed = false
		for y in range(ch - bs + 1):
			for x in range(cw - bs + 1):
				var r0 = rooms[y * cw + x]
				if r0 < 0 or not protected.has(r0):
					continue
				if String(circ_cat.get(r0, "corridor")) != "corridor":
					continue
				var solid = true
				for yy in range(y, y + bs):
					for xx in range(x, x + bs):
						if rooms[yy * cw + xx] != r0:
							solid = false
							break
					if not solid:
						break
				if not solid:
					continue
				# Give back the block cell with the most room neighbors.
				var best_i = -1
				var best_o = -1
				var best_n = -1
				for yy in range(y, y + bs):
					for xx in range(x, x + bs):
						var counts = {}
						for nb in [[xx - 1, yy], [xx + 1, yy], [xx, yy - 1], [xx, yy + 1]]:
							if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
								continue
							var o = rooms[nb[1] * cw + nb[0]]
							if o >= 0 and o != r0 and not _plan_corr_ids.has(int(o)):
								counts[o] = int(counts.get(o, 0)) + 1
						for o in counts:
							if int(counts[o]) > best_n:
								best_n = int(counts[o])
								best_o = int(o)
								best_i = yy * cw + xx
				if best_i < 0:
					# Fully interior block: later passes expose it as the
					# outer cells get reassigned; never spawn island rooms.
					continue
				rooms[best_i] = best_o
				changed = true
				fixed = true
		if not fixed:
			break
	return changed


func _plan_dissolve_useless_corridors(rooms: Array, cw: int, ch: int, protected: Dictionary, circ_cat: Dictionary) -> void:
	# 1. Two corridors must never sit side by side: adjacent corridor
	# components are merged into one.
	for _pass in range(4):
		var merged_any = false
		var corr = []
		for r in protected:
			if String(circ_cat.get(int(r), "corridor")) == "corridor":
				corr.append(int(r))
		for i in range(corr.size()):
			for j in range(i + 1, corr.size()):
				var a = corr[i]
				var b = corr[j]
				var touch = false
				for idx in range(cw * ch):
					if rooms[idx] != a:
						continue
					var y = idx / cw
					var x = idx - y * cw
					for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
						if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
							continue
						if rooms[nb[1] * cw + nb[0]] == b:
							touch = true
							break
					if touch:
						break
				if touch:
					for idx in range(cw * ch):
						if rooms[idx] == b:
							rooms[idx] = a
					protected.erase(b)
					circ_cat.erase(b)
					merged_any = true
					break
			if merged_any:
				break
		if not merged_any:
			break
	# 2. A corridor must be long and thin AND serve at least 3 rooms; blobby
	# chunks become normal rooms, underused strips dissolve into a neighbor.
	var infos = _plan_room_infos(rooms, cw, ch)
	var to_clear = []
	var to_merge = []
	for r in protected:
		# This is a CORRIDOR tribunal: halls, gatehouses, transepts and
		# every other special protected room are none of its business.
		# (The gatehouse flanked by two gallery stubs has exactly 2
		# neighbors and got dissolved as a "useless corridor" - walling
		# castles shut.)
		if String(circ_cat.get(int(r), "corridor")) != "corridor":
			continue
		var borders = {}
		for i in range(cw * ch):
			if rooms[i] != int(r):
				continue
			var y = i / cw
			var x = i - y * cw
			for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var o = rooms[nb[1] * cw + nb[0]]
				if o >= 0 and o != int(r):
					borders[o] = int(borders.get(o, 0)) + 1
		if borders.size() < 3:
			to_merge.append(r)
			continue
		# A corridor ring wrapped around a SINGLE room is forbidden: the
		# enclosed room would touch nothing but this corridor and have no
		# exterior at all.
		var enclosed = 0
		for r2 in infos:
			if int(r2) == int(r) or protected.has(int(r2)):
				continue
			var only_this = true
			var has_ext = false
			for i3 in range(cw * ch):
				if rooms[i3] != int(r2):
					continue
				var y4 = i3 / cw
				var x4 = i3 - y4 * cw
				for nb in [[x4 - 1, y4], [x4 + 1, y4], [x4, y4 - 1], [x4, y4 + 1]]:
					var o4 = -1
					if nb[0] >= 0 and nb[0] < cw and nb[1] >= 0 and nb[1] < ch:
						o4 = rooms[nb[1] * cw + nb[0]]
					if o4 < 0:
						has_ext = true
					elif o4 != int(r2) and o4 != int(r):
						only_this = false
			if only_this and not has_ext:
				enclosed += 1
		if enclosed == 1:
			to_merge.append(r)
			continue
		if infos.has(int(r)):
			# Corridor-shaped = made of thin (1-2 wide) stretches. Cell
			# thinness instead of the bounding box: an L-shaped or ring
			# corridor has a fat bbox yet is a perfectly fine corridor.
			var thin_n = 0
			var tot_n = 0
			for i2 in range(cw * ch):
				if rooms[i2] != int(r):
					continue
				tot_n += 1
				var y3 = i2 / cw
				var x3 = i2 - y3 * cw
				var l3 = x3 > 0 and rooms[i2 - 1] == int(r)
				var r3 = x3 < cw - 1 and rooms[i2 + 1] == int(r)
				var u3 = y3 > 0 and rooms[i2 - cw] == int(r)
				var d3 = y3 < ch - 1 and rooms[i2 + cw] == int(r)
				var lr2 = 0
				if l3:
					lr2 += 1
				if r3:
					lr2 += 1
				var ud2 = 0
				if u3:
					ud2 += 1
				if d3:
					ud2 += 1
				# Thin along one axis (possibly 2-wide along the other).
				if lr2 == 0 or ud2 == 0 or min(int(infos[int(r)]["bw"]), int(infos[int(r)]["bh"])) <= 2:
					thin_n += 1
			if tot_n < 3 or float(thin_n) / float(max(1, tot_n)) < 0.8:
				# Not corridor-shaped: keep the room, drop the label.
				to_clear.append(r)
	for r in to_merge:
		var borders2 = {}
		for i in range(cw * ch):
			if rooms[i] != int(r):
				continue
			var y = i / cw
			var x = i - y * cw
			for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var o = rooms[nb[1] * cw + nb[0]]
				if o >= 0 and o != int(r):
					borders2[o] = int(borders2.get(o, 0)) + 1
		var best = -1
		var best_n = 0
		for o in borders2:
			if int(borders2[o]) > best_n:
				best_n = int(borders2[o])
				best = o
		if best >= 0:
			for i in range(cw * ch):
				if rooms[i] == int(r):
					rooms[i] = best
		protected.erase(r)
		circ_cat.erase(r)
	for r in to_clear:
		protected.erase(r)
		circ_cat.erase(r)


# Open partial walls (room dividers) for small buildings: a wall stub along
# a lattice line inside a single room, anchored to an existing wall at one
# end and open at the other.
func _plan_keep_main_component(mask: Array, cw: int, ch: int) -> void:
	# Keeps only the largest connected component of the footprint.
	var labels = _plan_zeroed_ints(cw * ch)
	var next_l = 0
	var sizes = []
	for i in range(cw * ch):
		if mask[i] == 1 and labels[i] == 0:
			next_l += 1
			var count = 0
			var stack = [i]
			labels[i] = next_l
			while not stack.empty():
				var idx = stack.pop_back()
				count += 1
				var y = idx / cw
				var x = idx - y * cw
				for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
					if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
						continue
					var j = nb[1] * cw + nb[0]
					if mask[j] == 1 and labels[j] == 0:
						labels[j] = next_l
						stack.append(j)
			sizes.append(count)
	if next_l == 0:
		# Degenerate footprint: fall back to the full rectangle.
		for i in range(cw * ch):
			mask[i] = 1
		return
	if next_l == 1:
		return
	var best = 1
	for li in range(2, next_l + 1):
		if sizes[li - 1] > sizes[best - 1]:
			best = li
	for i in range(cw * ch):
		if mask[i] == 1 and labels[i] != best:
			mask[i] = 0


func _plan_bsp(rng, rect: Rect2, min_s: int, max_s: int, out: Array) -> void:
	var w = int(rect.size.x)
	var h = int(rect.size.y)
	if w <= 0 or h <= 0:
		return
	var can_x = w >= min_s * 2
	var can_y = h >= min_s * 2
	var must = w > max_s or h > max_s or w * h > max_s * max_s
	# Rooms must stay under a 3:1 ratio (corridors are not BSP leaves, so
	# they stay exempt). 1-wide bands are left to fix_thin.
	if min(w, h) >= 2 and max(w, h) > min(w, h) * 3:
		must = true
	var want = rng.randf() < 0.4 + _plan_complexity * 0.5
	if (not can_x and not can_y) or (not must and not want):
		out.append(rect)
		return
	var split_x = can_x
	if can_x and can_y:
		if w > h:
			split_x = true
		elif h > w:
			split_x = false
		else:
			split_x = rng.randf() < 0.5
	elif not can_x:
		split_x = false
	if split_x:
		var sx = rng.randi_range(min_s, w - min_s)
		_plan_bsp(rng, Rect2(rect.position, Vector2(sx, h)), min_s, max_s, out)
		_plan_bsp(rng, Rect2(rect.position + Vector2(sx, 0), Vector2(w - sx, h)), min_s, max_s, out)
	else:
		var sy = rng.randi_range(min_s, h - min_s)
		_plan_bsp(rng, Rect2(rect.position, Vector2(w, sy)), min_s, max_s, out)
		_plan_bsp(rng, Rect2(rect.position + Vector2(0, sy), Vector2(w, h - sy)), min_s, max_s, out)


func _plan_label_components(mask: Array, leaf_id: Array, cw: int, ch: int) -> Dictionary:
	# Final room ids: connected components of same-leaf masked cells.
	# Also records which leaf each component came from.
	var rooms = _plan_zeroed_ints(cw * ch)
	for i in range(cw * ch):
		rooms[i] = -1
	var comp_leaf = []
	var next_r = -1
	for i in range(cw * ch):
		if mask[i] == 1 and rooms[i] == -1:
			next_r += 1
			var lid = leaf_id[i]
			comp_leaf.append(lid)
			var stack = [i]
			rooms[i] = next_r
			while not stack.empty():
				var idx = stack.pop_back()
				var y = idx / cw
				var x = idx - y * cw
				for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
					if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
						continue
					var j = nb[1] * cw + nb[0]
					if mask[j] == 1 and rooms[j] == -1 and leaf_id[j] == lid:
						rooms[j] = next_r
						stack.append(j)
	return {"rooms": rooms, "leaf": comp_leaf}


# References almost never show four rooms meeting at one point: at each
# "+" junction one room donates its full edge strip to the neighbor
# across the crossing wall, offsetting the two colinear walls by one
# cell - the "+" becomes two staggered Ts, reference-style.
func _plan_break_cross_junctions(rooms: Array, cw: int, ch: int, protected: Dictionary, min_cells: int) -> void:
	for y in range(1, ch):
		for x in range(1, cw):
			var tl = rooms[(y - 1) * cw + (x - 1)]
			var tr = rooms[(y - 1) * cw + x]
			var bl = rooms[y * cw + (x - 1)]
			var br = rooms[y * cw + x]
			if tl < 0 or tr < 0 or bl < 0 or br < 0:
				continue
			if tl == tr or tl == bl or tr == br or bl == br or tl == br or tr == bl:
				continue
			if _plan_cj_shift(rooms, cw, ch, protected, min_cells, br, tr, 0):
				continue
			if _plan_cj_shift(rooms, cw, ch, protected, min_cells, tr, br, 1):
				continue
			if _plan_cj_shift(rooms, cw, ch, protected, min_cells, bl, tl, 0):
				continue
			if _plan_cj_shift(rooms, cw, ch, protected, min_cells, tl, bl, 1):
				continue
			if _plan_cj_shift(rooms, cw, ch, protected, min_cells, br, bl, 2):
				continue
			if _plan_cj_shift(rooms, cw, ch, protected, min_cells, bl, br, 3):
				continue


# One edge strip of the donor room moves to the receiver across it.
# edge: 0 = donor's top row (receiver above), 1 = bottom row, 2 = left
# column, 3 = right column. Only applies when the WHOLE strip borders
# the receiver, so no new jogs appear along the shifted wall.
func _plan_cj_shift(rooms: Array, cw: int, ch: int, protected: Dictionary, min_cells: int, donor: int, recv: int, edge: int) -> bool:
	if protected.has(int(donor)) or protected.has(int(recv)):
		return false
	var x0 = cw
	var x1 = -1
	var y0 = ch
	var y1 = -1
	var n = 0
	for i in range(cw * ch):
		if rooms[i] != donor:
			continue
		n += 1
		var y = i / cw
		var x = i - y * cw
		x0 = int(min(x0, x))
		x1 = int(max(x1, x))
		y0 = int(min(y0, y))
		y1 = int(max(y1, y))
	if n <= 0:
		return false
	var dx = 0
	var dy = 0
	if edge == 0:
		dy = -1
	elif edge == 1:
		dy = 1
	elif edge == 2:
		dx = -1
	else:
		dx = 1
	if dy != 0 and y1 - y0 + 1 < 3:
		return false
	if dx != 0 and x1 - x0 + 1 < 3:
		return false
	var ey = y0
	if edge == 1:
		ey = y1
	var ex = x0
	if edge == 3:
		ex = x1
	var strip = []
	for i in range(cw * ch):
		if rooms[i] != donor:
			continue
		var y = i / cw
		var x = i - y * cw
		if (dy != 0 and y == ey) or (dx != 0 and x == ex):
			strip.append(i)
	if strip.size() < 2 or n - strip.size() < min_cells:
		return false
	for i in strip:
		var y = i / cw
		var x = i - y * cw
		var nx = x + dx
		var ny = y + dy
		if nx < 0 or nx >= cw or ny < 0 or ny >= ch:
			return false
		if rooms[ny * cw + nx] != recv:
			return false
	for i in strip:
		rooms[i] = recv
	return true


# Staircase borders (2+ successive jogs between two ordinary rooms)
# flatten to the median line; a single L-jog is a legitimate feature
# and stays. Transfers roll back if either room ends up disconnected
# or under the size floor.
func _plan_straighten_walls(rooms: Array, cw: int, ch: int, protected: Dictionary, min_cells: int) -> void:
	var pairs = {}
	for i in range(cw * ch):
		var r = rooms[i]
		if r < 0:
			continue
		var y = i / cw
		var x = i - y * cw
		if x + 1 < cw:
			var o = rooms[i + 1]
			if o >= 0 and o != r:
				pairs[[int(min(r, o)), int(max(r, o))]] = true
		if y + 1 < ch:
			var o2 = rooms[i + cw]
			if o2 >= 0 and o2 != r:
				pairs[[int(min(r, o2)), int(max(r, o2))]] = true
	for kp in pairs.keys():
		var a = int(kp[0])
		var b = int(kp[1])
		if protected.has(a) or protected.has(b):
			continue
		for vert in [true, false]:
			for first in [a, b]:
				_plan_straighten_pair(rooms, cw, ch, first, b if first == a else a, vert, min_cells)


func _plan_straighten_pair(rooms: Array, cw: int, ch: int, first: int, second: int, vert: bool, min_cells: int) -> void:
	# For a VERTICAL border (first left of second): bx[row] = x of the
	# first-room cell whose right neighbor is second. Horizontal is the
	# transpose. Two borders in one row means a wrap: skipped.
	var bx = {}
	for i in range(cw * ch):
		if rooms[i] != first:
			continue
		var y = i / cw
		var x = i - y * cw
		if vert:
			if x + 1 < cw and rooms[i + 1] == second:
				if bx.has(y):
					return
				bx[y] = x
		else:
			if y + 1 < ch and rooms[i + cw] == second:
				if bx.has(x):
					return
				bx[x] = y
	if bx.size() < 3:
		return
	var keys = bx.keys()
	keys.sort()
	var vals = []
	var jogs = 0
	for ki in range(keys.size()):
		if ki > 0 and int(keys[ki]) != int(keys[ki - 1]) + 1:
			return
		vals.append(int(bx[keys[ki]]))
		if ki > 0 and int(bx[keys[ki]]) != int(bx[keys[ki - 1]]):
			jogs += 1
	if jogs < 2:
		return
	var sv = vals.duplicate()
	sv.sort()
	var med = int(sv[sv.size() / 2])
	var changes = []
	for ki in range(keys.size()):
		var k2 = int(keys[ki])
		var v = int(bx[k2])
		if v == med:
			continue
		if v > med:
			for c2 in range(med + 1, v + 1):
				var idx2 = k2 * cw + c2
				if not vert:
					idx2 = c2 * cw + k2
				if rooms[idx2] != first:
					return
				changes.append([idx2, first, second])
		else:
			for c2 in range(v + 1, med + 1):
				var idx2 = k2 * cw + c2
				if not vert:
					idx2 = c2 * cw + k2
				if rooms[idx2] != second:
					return
				changes.append([idx2, second, first])
	if changes.empty():
		return
	for c3 in changes:
		rooms[int(c3[0])] = int(c3[2])
	if not _plan_room_connected_min(rooms, cw, ch, first, min_cells) \
			or not _plan_room_connected_min(rooms, cw, ch, second, min_cells):
		for c3 in changes:
			rooms[int(c3[0])] = int(c3[1])


# Connected AND at least min_cells big.
func _plan_room_connected_min(rooms: Array, cw: int, ch: int, rid: int, min_cells: int) -> bool:
	var total = 0
	var start = -1
	for i in range(cw * ch):
		if rooms[i] == rid:
			total += 1
			if start < 0:
				start = i
	if total < min_cells:
		return false
	if start < 0:
		return false
	var seen = {}
	seen[start] = true
	var q = [start]
	var qi = 0
	var cnt = 0
	while qi < q.size():
		var cur = q[qi]
		qi += 1
		cnt += 1
		var y = cur / cw
		var x = cur - y * cw
		for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
			var nx = x + int(d[0])
			var ny = y + int(d[1])
			if nx < 0 or nx >= cw or ny < 0 or ny >= ch:
				continue
			var oi = ny * cw + nx
			if rooms[oi] == rid and not seen.has(oi):
				seen[oi] = true
				q.append(oi)
	return cnt == total


func _plan_merge_small_rooms(rooms: Array, cw: int, ch: int, min_cells: int, protected: Dictionary) -> void:
	# Merge fragments smaller than min_cells into the neighbor sharing the
	# longest border, corridors excepted. A few passes settle chains.
	for _pass in range(3):
		var sizes = {}
		for i in range(cw * ch):
			var r = rooms[i]
			if r >= 0:
				sizes[r] = int(sizes.get(r, 0)) + 1
		var merged = false
		for r in sizes:
			if int(sizes[r]) >= min_cells or protected.has(int(r)):
				continue
			var borders = {}
			for i in range(cw * ch):
				if rooms[i] != r:
					continue
				var y = i / cw
				var x = i - y * cw
				for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
					if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
						continue
					var o = rooms[nb[1] * cw + nb[0]]
					if o >= 0 and o != r:
						borders[o] = int(borders.get(o, 0)) + 1
			var best = -1
			var best_n = 0
			for o in borders:
				if _plan_corr_ids.has(int(o)):
					continue
				# Protected rooms (the hall) stop absorbing once sizeable:
				# unlimited absorption bred one giant room among midgets.
				if protected.has(int(o)):
					var osz = 0
					for i2 in range(cw * ch):
						if rooms[i2] == int(o):
							osz += 1
					if osz > 26:
						continue
				if int(borders[o]) > best_n:
					best_n = int(borders[o])
					best = o
			if best >= 0:
				for i in range(cw * ch):
					if rooms[i] == r:
						rooms[i] = best
				merged = true
		if not merged:
			break


func _plan_carve_closets(rng, rooms: Array, mask: Array, cw: int, ch: int) -> void:
	# Carves a few 1x1 / 1x2 closets off room corners (minority by design).
	var sizes = {}
	for i in range(cw * ch):
		if rooms[i] >= 0:
			sizes[rooms[i]] = int(sizes.get(rooms[i], 0)) + 1
	var next_id = 0
	for r in sizes:
		next_id = int(max(next_id, int(r) + 1))
	var budget = 1 + int(sizes.size() / 6)
	for r in sizes:
		if budget <= 0:
			break
		if int(sizes[r]) < 9 or rng.randf() > _plan_complexity * 0.35:
			continue
		# Find a corner cell of the room (2+ non-room orthogonal neighbors).
		for i in range(cw * ch):
			if rooms[i] != r:
				continue
			var y = i / cw
			var x = i - y * cw
			var outsiders = 0
			for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch \
						or rooms[nb[1] * cw + nb[0]] != r:
					outsiders += 1
			if outsiders >= 2:
				rooms[i] = next_id
				# 1x2 sometimes, along a same-room neighbor.
				if rng.randf() < 0.4:
					for nb in [[x + 1, y], [x, y + 1], [x - 1, y], [x, y - 1]]:
						if nb[0] >= 0 and nb[0] < cw and nb[1] >= 0 and nb[1] < ch \
								and rooms[nb[1] * cw + nb[0]] == r:
							rooms[nb[1] * cw + nb[0]] = next_id
							break
				next_id += 1
				budget -= 1
				break


func _plan_fix_thin_rooms(rooms: Array, cw: int, ch: int, protected: Dictionary) -> void:
	# 1xN rooms (N >= 3) merge into their best neighbor; 1x1 and 1x2 stay
	# (they become closets / WC / staircases).
	var infos = _plan_room_infos(rooms, cw, ch)
	for r in infos:
		if protected.has(int(r)):
			continue
		var inf = infos[r]
		if int(min(int(inf["bw"]), int(inf["bh"]))) > 1 or int(inf["cells"]) <= 2:
			continue
		var borders = {}
		for i in range(cw * ch):
			if rooms[i] != int(r):
				continue
			var y = i / cw
			var x = i - y * cw
			for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var o = rooms[nb[1] * cw + nb[0]]
				if o >= 0 and o != int(r) and not _plan_corr_ids.has(int(o)):
					borders[o] = int(borders.get(o, 0)) + 1
		var best = -1
		var best_n = 0
		for o in borders:
			if int(borders[o]) > best_n:
				best_n = int(borders[o])
				best = o
		if best >= 0:
			for i in range(cw * ch):
				if rooms[i] == int(r):
					rooms[i] = best
	# Second pass: big rooms made only of arms 2 cells wide or less (L/T
	# snakes with no 3x3 core anywhere) read as corridors without being any:
	# merge them into their best neighbor.
	var infos2 = _plan_room_infos(rooms, cw, ch)
	for r2 in infos2:
		if protected.has(int(r2)) or int(infos2[r2]["cells"]) < 10:
			continue
		var has_core = false
		for i in range(cw * ch):
			if rooms[i] != int(r2):
				continue
			var y = i / cw
			var x = i - y * cw
			if x > 0 and x < cw - 1 and y > 0 and y < ch - 1 \
					and rooms[y * cw + x - 1] == int(r2) and rooms[y * cw + x + 1] == int(r2) \
					and rooms[(y - 1) * cw + x] == int(r2) and rooms[(y + 1) * cw + x] == int(r2):
				has_core = true
				break
		if has_core:
			continue
		var borders2 = {}
		for i in range(cw * ch):
			if rooms[i] != int(r2):
				continue
			var y2 = i / cw
			var x2 = i - y2 * cw
			for nb in [[x2 - 1, y2], [x2 + 1, y2], [x2, y2 - 1], [x2, y2 + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var o2 = rooms[nb[1] * cw + nb[0]]
				if o2 >= 0 and o2 != int(r2) and not protected.has(o2):
					borders2[o2] = int(borders2.get(o2, 0)) + 1
		var best2 = -1
		var best2_n = 0
		for o2 in borders2:
			if int(borders2[o2]) > best2_n:
				best2_n = int(borders2[o2])
				best2 = o2
		if best2 >= 0:
			for i in range(cw * ch):
				if rooms[i] == int(r2):
					rooms[i] = best2


# Cells where their room is locally 1 cell wide (no same-room neighbor on
# either side of one axis) form thin arms; arms of 3+ cells are carved off
# to the adjacent rooms (corridors excepted).
func _plan_trim_thin_arms(rooms: Array, cw: int, ch: int, protected: Dictionary) -> bool:
	var sizes = {}
	for i in range(cw * ch):
		if rooms[i] >= 0:
			sizes[rooms[i]] = int(sizes.get(rooms[i], 0)) + 1
	var thin = {}
	for y in range(ch):
		for x in range(cw):
			var r = rooms[y * cw + x]
			if r < 0 or protected.has(r) or int(sizes.get(r, 0)) <= 2:
				continue
			var l = x > 0 and rooms[y * cw + x - 1] == r
			var rr = x < cw - 1 and rooms[y * cw + x + 1] == r
			var u = y > 0 and rooms[(y - 1) * cw + x] == r
			var d = y < ch - 1 and rooms[(y + 1) * cw + x] == r
			if (not l and not rr) or (not u and not d):
				thin[y * cw + x] = true
	if thin.empty():
		return false
	# Connected thin components of 3+ cells (per room) get reassigned.
	var visited = {}
	var changed = false
	for start in thin.keys():
		if visited.has(start):
			continue
		var r0 = rooms[start]
		var comp = []
		var stack = [start]
		visited[start] = true
		while not stack.empty():
			var idx = stack.pop_back()
			comp.append(idx)
			var y2 = idx / cw
			var x2 = idx - y2 * cw
			for nb in [[x2 - 1, y2], [x2 + 1, y2], [x2, y2 - 1], [x2, y2 + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var j = nb[1] * cw + nb[0]
				if thin.has(j) and not visited.has(j) and rooms[j] == r0:
					visited[j] = true
					stack.append(j)
		if comp.size() < 3:
			continue
		for idx in comp:
			var y3 = idx / cw
			var x3 = idx - y3 * cw
			var borders = {}
			for nb in [[x3 - 1, y3], [x3 + 1, y3], [x3, y3 - 1], [x3, y3 + 1]]:
				if nb[0] < 0 or nb[0] >= cw or nb[1] < 0 or nb[1] >= ch:
					continue
				var o = rooms[nb[1] * cw + nb[0]]
				if o >= 0 and o != r0 and not _plan_corr_ids.has(int(o)):
					borders[o] = int(borders.get(o, 0)) + 1
			var best = -1
			var best_n = 0
			for o in borders:
				if int(borders[o]) > best_n:
					best_n = int(borders[o])
					best = o
			if best >= 0:
				rooms[idx] = best
				changed = true
	return changed


func _plan_smooth_stairs(rooms: Array, mask: Array, cw: int, ch: int, protected: Dictionary) -> void:
	# Boundaries stepping at every single cell read as staircases: a cell
	# whose corner pattern continues stepping immediately is flipped to the
	# neighbor, turning 1-cell steps into 2-cell treads or straight walls.
	for _pass in range(24):
		var sizes = {}
		for i in range(cw * ch):
			if rooms[i] >= 0:
				sizes[rooms[i]] = int(sizes.get(rooms[i], 0)) + 1
		var flips = []
		for y in range(ch):
			for x in range(cw):
				var r = rooms[y * cw + x]
				if r < 0 or protected.has(r):
					continue
				# Tiny rooms (closets, WC) are exempt: the swallow rule
				# would erase them entirely.
				if int(sizes.get(r, 0)) <= 2:
					continue
				# 1-cell peninsula/notch: 3+ orthogonal neighbors on the
				# same other side swallow the cell.
				var counts = {}
				for nb in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
					var v = -1
					if nb[0] >= 0 and nb[0] < cw and nb[1] >= 0 and nb[1] < ch:
						v = rooms[nb[1] * cw + nb[0]]
					if v != r:
						counts[v] = int(counts.get(v, 0)) + 1
				var swallowed = false
				for v in counts:
					if int(v) >= 0 and int(counts[v]) >= 3 and not _plan_corr_ids.has(int(v)):
						flips.append([y * cw + x, int(v)])
						swallowed = true
						break
				if swallowed:
					continue
				for dxa in [-1, 1]:
					for dyb in [-1, 1]:
						var nx = x + dxa
						var ny = y + dyb
						var o = -1
						var o2 = -1
						if nx >= 0 and nx < cw:
							o = rooms[y * cw + nx]
						if ny >= 0 and ny < ch:
							o2 = rooms[ny * cw + x]
						if o != o2 or o == r:
							continue
						# The silhouette must stay untouched (only Building
						# Shape Oddity may change it): no flips to outside.
						if o < 0:
							continue
						if _plan_corr_ids.has(o):
							continue
						# One-directional flips only: symmetric flips just
						# swapped the stair back and forth between passes.
						if o <= r and not protected.has(o):
							continue
						# The two orthogonal neighbors belong to the same
						# other side; does the stair continue immediately?
						var c1x = x - dxa
						var c1y = y + dyb
						var c2x = x + dxa
						var c2y = y - dyb
						var cont = false
						if c1x >= 0 and c1x < cw and c1y >= 0 and c1y < ch \
								and rooms[c1y * cw + c1x] == o:
							cont = true
						if c2x >= 0 and c2x < cw and c2y >= 0 and c2y < ch \
								and rooms[c2y * cw + c2x] == o:
							cont = true
						if cont:
							flips.append([y * cw + x, o])
		if flips.empty():
			break
		for f in flips:
			rooms[f[0]] = f[1]


func _plan_split_sprawling(vr, rooms: Array, cw: int, ch: int, protected: Dictionary, bsp_min: int, room_max: int) -> bool:
	var infos = _plan_room_infos(rooms, cw, ch)
	var next_id = 0
	for r in infos:
		next_id = int(max(next_id, int(r) + 1))
	var changed = false
	for r in infos:
		if protected.has(int(r)):
			continue
		var inf = infos[r]
		var cells = int(inf["cells"])
		if cells < 12:
			continue
		var others = 0.0
		var n_others = 0
		for r2 in infos:
			if int(r2) != int(r) and not protected.has(int(r2)):
				others += float(infos[r2]["cells"])
				n_others += 1
		var avg = 0.0
		if n_others > 0:
			avg = others / float(n_others)
		var fill = float(cells) / float(int(inf["bw"]) * int(inf["bh"]))
		var dwarfs = n_others > 0 and float(cells) > max(12.0, avg * 2.5)
		var bw2 = int(inf["bw"])
		var bh2 = int(inf["bh"])
		var stretched = min(bw2, bh2) >= 2 and max(bw2, bh2) > int(float(min(bw2, bh2)) * 3.2)
		if fill >= 0.45 and cells <= room_max * room_max * 3 / 2 and not dwarfs and not stretched:
			continue
		var leaves = []
		_plan_bsp(vr, Rect2(int(inf["x0"]), int(inf["y0"]), int(inf["bw"]), int(inf["bh"])), bsp_min, room_max, leaves)
		if leaves.size() < 2:
			continue
		for li in range(leaves.size()):
			var lr = leaves[li]
			for y in range(int(lr.position.y), int(lr.position.y + lr.size.y)):
				for x in range(int(lr.position.x), int(lr.position.x + lr.size.x)):
					if x >= 0 and x < cw and y >= 0 and y < ch and rooms[y * cw + x] == int(r):
						rooms[y * cw + x] = next_id + li
		next_id += leaves.size()
		changed = true
	return changed


# Relabels connected components and remaps the protection/category dicts
# (needed after any pass that may split a room id in two).
func _plan_relabel_remap(mask: Array, rooms: Array, cw: int, ch: int, protected: Dictionary, circ_cat: Dictionary) -> Array:
	var lab = _plan_label_components(mask, rooms, cw, ch)
	var new_rooms = lab["rooms"]
	var old_of = lab["leaf"]
	var p2 = {}
	var c2 = {}
	for ci in range(old_of.size()):
		var oid = int(old_of[ci])
		if protected.has(oid):
			p2[ci] = true
			c2[ci] = String(circ_cat.get(oid, "corridor"))
	protected.clear()
	circ_cat.clear()
	for k in p2:
		protected[int(k)] = true
	for k in c2:
		circ_cat[int(k)] = String(c2[k])
	_plan_refresh_corr_ids(circ_cat)
	return new_rooms


func _plan_tiny_cat(vr, cells: int) -> String:
	# Tiny rooms with some variety (closets, powder rooms, staircases...).
	var roll = vr.randf()
	if cells <= 1:
		if roll < 0.4:
			return "closet"
		if roll < 0.65:
			return "powder"
		if roll < 0.85:
			return "coat"
		return "linen"
	if roll < 0.3:
		return "closet"
	if roll < 0.5:
		return "powder"
	if roll < 0.7:
		return "staircase"
	if roll < 0.85:
		return "coat"
	return "linen"


func _plan_cell(rooms: Array, mask: Array, cw: int, ch: int, x: int, y: int) -> int:
	# Returns the room id, or -1 for outside cells.
	if x < 0 or x >= cw or y < 0 or y >= ch:
		return -1
	if mask[y * cw + x] == 0:
		return -1
	return rooms[y * cw + x]


func _plan_collect_runs(mask: Array, rooms: Array, cw: int, ch: int) -> Array:
	var runs = []
	# Vertical boundaries at x = 0..cw between columns x-1 and x.
	for x in range(cw + 1):
		var cur = null
		for y in range(ch + 1):
			var state = null
			if y < ch:
				var a = _plan_cell(rooms, mask, cw, ch, x - 1, y)
				var b = _plan_cell(rooms, mask, cw, ch, x, y)
				if a != b:
					var kind = "int"
					if a == -1 or b == -1:
						kind = "ext"
					state = [kind, int(min(a, b)), int(max(a, b))]
			if state != null and cur != null and cur["kind"] == state[0] \
					and cur["a"] == state[1] and cur["b"] == state[2]:
				cur["y1"] += 1
			else:
				if cur != null:
					runs.append(cur)
				cur = null
				if state != null:
					cur = {"vert": true, "x": x, "y0": y, "y1": y + 1,
						"kind": state[0], "a": state[1], "b": state[2], "holes": []}
		if cur != null:
			runs.append(cur)
	# Horizontal boundaries at y = 0..ch.
	for y in range(ch + 1):
		var cur = null
		for x in range(cw + 1):
			var state = null
			if x < cw:
				var a = _plan_cell(rooms, mask, cw, ch, x, y - 1)
				var b = _plan_cell(rooms, mask, cw, ch, x, y)
				if a != b:
					var kind = "int"
					if a == -1 or b == -1:
						kind = "ext"
					state = [kind, int(min(a, b)), int(max(a, b))]
			if state != null and cur != null and cur["kind"] == state[0] \
					and cur["a"] == state[1] and cur["b"] == state[2]:
				cur["x1"] += 1
			else:
				if cur != null:
					runs.append(cur)
				cur = null
				if state != null:
					cur = {"vert": false, "y": y, "x0": x, "x1": x + 1,
						"kind": state[0], "a": state[1], "b": state[2], "holes": []}
		if cur != null:
			runs.append(cur)
	return runs


func _plan_run_len(run) -> int:
	if bool(run["vert"]):
		return int(run["y1"]) - int(run["y0"])
	return int(run["x1"]) - int(run["x0"])


func _plan_try_hole(run, pos: float, w: float, type_s: String) -> bool:
	var len_r = float(_plan_run_len(run))
	if pos < 0.0 or pos + w > len_r:
		return false
	for h in run["holes"]:
		# Keep at least one cell of wall between openings.
		if pos < float(h[0]) + float(h[1]) + 1.0 and float(h[0]) < pos + w + 1.0:
			return false
	for b in run.get("blocked", []):
		if pos < float(b[0]) + float(b[1]) + 0.4 and float(b[0]) < pos + w + 0.4:
			return false
	# Doors and openings from different rooms must not stack on the same
	# wall line: enforce clearance across collinear runs too.
	if type_s == "door" or type_s == "open":
		var abs0 = pos
		var abs1 = pos + w
		if bool(run["vert"]):
			abs0 += float(run["y0"])
			abs1 += float(run["y0"])
		else:
			abs0 += float(run["x0"])
			abs1 += float(run["x0"])
		var my_line = int(run["x"]) if bool(run["vert"]) else int(run["y"])
		for other in _plan_all_runs:
			if other == run:
				continue
			if bool(other["vert"]) != bool(run["vert"]):
				# Perpendicular wall: reject doors meeting at a corner.
				var o_line = int(other["x"]) if bool(other["vert"]) else int(other["y"])
				if o_line < abs0 - 1.0 or o_line > abs1 + 1.0:
					continue
				for h3 in other["holes"]:
					var t3 = String(h3[2])
					if t3 != "door" and t3 != "open":
						continue
					var q0 = float(h3[0])
					var q1 = q0 + float(h3[1])
					if bool(other["vert"]):
						q0 += float(other["y0"])
						q1 += float(other["y0"])
					else:
						q0 += float(other["x0"])
						q1 += float(other["x0"])
					if float(my_line) >= q0 - 1.0 and float(my_line) <= q1 + 1.0:
						return false
				continue
			if bool(run["vert"]):
				if int(other["x"]) != int(run["x"]):
					continue
			else:
				if int(other["y"]) != int(run["y"]):
					continue
			for h2 in other["holes"]:
				var t2 = String(h2[2])
				if t2 != "door" and t2 != "open":
					continue
				var o0 = float(h2[0])
				var o1 = o0 + float(h2[1])
				if bool(other["vert"]):
					o0 += float(other["y0"])
					o1 += float(other["y0"])
				else:
					o0 += float(other["x0"])
					o1 += float(other["x0"])
				if abs0 < o1 + 1.0 and o0 < abs1 + 1.0:
					return false
	# Doors and windows on exterior walls must open to the real outside,
	# never into a tower disc.
	if type_s != "cut" and String(run["kind"]) == "ext" and not _plan_cur_towers.empty():
		var outp = Vector2()
		if bool(run["vert"]):
			var side = 0.5
			if int(run["a"]) == -1:
				side = -0.5
			outp = Vector2(float(run["x"]) + side, float(run["y0"]) + pos + w * 0.5)
		else:
			var side2 = 0.5
			if int(run["a"]) == -1:
				side2 = -0.5
			outp = Vector2(float(run["x0"]) + pos + w * 0.5, float(run["y"]) + side2)
		for t in _plan_cur_towers:
			if outp.distance_to(t[0]) < float(t[1]) + 0.3:
				return false
	run["holes"].append([pos, w, type_s])
	return true


# Unconditional hole (tower circle cuts): overlaps are fine, the interval
# builder merges them.
func _plan_force_hole(run, pos: float, w: float) -> void:
	var len_r = float(_plan_run_len(run))
	var p0 = max(pos, 0.0)
	var p1 = min(pos + w, len_r)
	if p1 - p0 > 0.01:
		run["holes"].append([p0, p1 - p0, "cut"])


# Returns the number of rooms (windows scale with it).
func _plan_convex_corners(mask: Array, cw: int, ch: int) -> Array:
	# Lattice points where exactly ONE of the four surrounding cells is
	# inside the footprint.
	var corners = []
	for py in range(ch + 1):
		for px in range(cw + 1):
			var ins = []
			for c in [[px - 1, py - 1], [px, py - 1], [px - 1, py], [px, py]]:
				var v = 0
				if c[0] >= 0 and c[0] < cw and c[1] >= 0 and c[1] < ch and mask[c[1] * cw + c[0]] == 1:
					v = 1
				ins.append(v)
			if ins[0] + ins[1] + ins[2] + ins[3] == 1:
				var k = 0
				for i in range(4):
					if ins[i] == 1:
						k = i
				corners.append({"p": Vector2(px, py), "cell": k})
	return corners


# The apse keeps its two square shoulder corners: a bevel or a tower
# there would leave the half-circle ends hanging in the air.
func _plan_corner_near_apse(cp: Vector2) -> bool:
	if _plan_proc_apse == null:
		return false
	var ay = float(_plan_proc_apse[1])
	for sx in [-1.0, 1.0]:
		var ax = float(_plan_proc_apse[0]) + sx * float(_plan_proc_apse[2])
		if abs(cp.x - ax) < 1.25 and abs(cp.y - ay) < 1.25:
			return true
	return false


func _plan_corners(rng, mask: Array, runs: Array, cw: int, ch: int, acx: int, acy: int, out_segs: Array, out_arcs: Array, rooms: Array = [], cats: Dictionary = {}) -> void:
	var corners = _plan_convex_corners(mask, cw, ch)
	if not _plan_oriel_pts.empty():
		# Bow-window bays: their outer corners are ALWAYS chamfered
		# (that is what makes them read as oriels), consumed here so the
		# random grammar below never re-rolls them.
		var rem_c = []
		for i3 in range(corners.size()):
			var matched = false
			for op in _plan_oriel_pts:
				if corners[i3]["p"].distance_to(op) < 0.1:
					matched = true
					break
			if matched:
				_plan_bevel_corner(rng, runs, corners[i3], acx, acy, out_segs, 1)
			else:
				rem_c.append(corners[i3])
		corners = rem_c
	_plan_shuffle(rng, corners)
	var sym_x = String(_plan_archetype.get("sym", "")) in ["x", "xy"]
	var beveled = {}
	if sym_x:
		# Perfect symmetry: bevels come in mirror PAIRS with a shared
		# depth, never on the axis, or not at all - a chamfer on one side
		# only would break the whole facade.
		var by_key = {}
		for i2 in range(corners.size()):
			var cp2 = corners[i2]["p"]
			var mk = [int(min(cp2.x, float(cw) - cp2.x)), int(cp2.y)]
			if not by_key.has(mk):
				by_key[mk] = []
			by_key[mk].append(i2)
		var pair_list = []
		for mk2 in by_key:
			if by_key[mk2].size() == 2:
				pair_list.append(by_key[mk2])
		_plan_shuffle(rng, pair_list)
		var want_pairs = _plan_sround(rng, float(pair_list.size()) * (0.25 + _plan_orig * 0.75))
		for pi in range(int(min(want_pairs, pair_list.size()))):
			var pr = pair_list[pi]
			var ca = corners[pr[0]]
			var cb = corners[pr[1]]
			if _plan_corner_near_apse(ca["p"]) or _plan_corner_near_apse(cb["p"]):
				continue
			var bs2 = 1
			if rng.randf() < _plan_orig * 0.6:
				bs2 = 2
			if rng.randf() < _plan_orig * 0.3:
				bs2 = 3
			if _plan_bevel_corner(rng, runs, ca, acx, acy, out_segs, bs2):
				if not _plan_bevel_corner(rng, runs, cb, acx, acy, out_segs, bs2):
					pass
		return
	var bevels = _plan_sround(rng, float(corners.size()) * (0.25 + _plan_orig * 0.75))
	for i in range(int(min(bevels, corners.size()))):
		if _plan_corner_near_apse(corners[i]["p"]):
			continue
		# Deeper 2-3 cell bevels show up with high shape values - but
		# never deeper than a QUARTER of the smaller footprint side: on
		# a 4x4, a 3-cell chamfer swallowed most of the rect and left
		# its original walls (windows included) stranded mid-plan.
		var bcap = int(max(1, floor(float(min(cw, ch)) / 4.0)))
		var bsize = 1
		if rng.randf() < _plan_orig * 0.6:
			bsize = 2
		if rng.randf() < _plan_orig * 0.3:
			bsize = 3
		bsize = int(min(bsize, bcap))
		if _plan_bevel_corner(rng, runs, corners[i], acx, acy, out_segs, bsize):
			beveled[i] = true


func _plan_towers_pass(rng_tow, mask: Array, runs: Array, cw: int, ch: int, acx: int, acy: int, out_segs: Array, out_arcs: Array, rooms: Array, cats: Dictionary) -> void:
	# Towers placed AFTER the interior variant is chosen: their stream is
	# derived from the base seed, so the slider adds/removes towers without
	# reshuffling the interior layout. Under a symmetric archetype the
	# towers come in MIRROR PAIRS sharing one radius (axis corners may
	# take a single centered tower): one flanking tower without its twin
	# would break the facade.
	var corners = _plan_convex_corners(mask, cw, ch)
	if _plan_tower_count <= 0:
		return
	var sym_x = String(_plan_archetype.get("sym", "")) in ["x", "xy"]
	var cands = []
	if sym_x:
		var by_key = {}
		for i in range(corners.size()):
			var cp2 = corners[i]["p"]
			if int(cp2.x) * 2 == cw:
				cands.append([i])
				continue
			var mk = [int(min(cp2.x, float(cw) - cp2.x)), int(cp2.y)]
			if not by_key.has(mk):
				by_key[mk] = []
			by_key[mk].append(i)
		for mk2 in by_key:
			if by_key[mk2].size() == 2:
				cands.append(by_key[mk2])
	else:
		for i in range(corners.size()):
			cands.append([i])
	var placed = 0
	var placed_towers = []
	for cand in cands:
		if placed >= _plan_tower_count:
			break
		var r_pick = [1.0, 1.5, 1.5, 2.0, 2.5][rng_tow.randi_range(0, 4)]
		# A tower must stay an ornament on the corner, not eat the
		# keep: radius capped at a third of the smaller side.
		r_pick = min(r_pick, max(1.0, float(min(cw, ch)) / 3.0))
		var r_cells = 0.0
		for rc in [r_pick, 1.5, 1.0]:
			if rc > r_pick:
				continue
			var all_ok = true
			for ci in cand:
				if not _plan_tower_try_radius(mask, runs, cw, ch, acx, acy,
						corners[ci]["p"], int(corners[ci]["cell"]), rc):
					all_ok = false
					break
			if not all_ok:
				continue
			var clash = false
			for ci2 in cand:
				for t in placed_towers:
					if corners[ci2]["p"].distance_to(t[0]) < rc + float(t[1]) + 0.5:
						clash = true
						break
				if clash:
					break
			if clash:
				continue
			r_cells = rc
			break
		if r_cells <= 0.0:
			continue
		for ci3 in cand:
			_plan_tower_place(runs, corners[ci3]["p"], int(corners[ci3]["cell"]),
				r_cells, acx, acy, out_arcs)
			placed_towers.append([corners[ci3]["p"], r_cells])
			placed += 1


# All the validity checks for one tower candidate at one radius: canvas
# bounds, footprint fit, corner wall solidity up to the arc ends, no
# stranger exterior wall crossing the disc.
func _plan_tower_try_radius(mask: Array, runs: Array, cw: int, ch: int, acx: int, acy: int, cp: Vector2, k: int, rc: float) -> bool:
	if _plan_corner_near_apse(cp):
		return false
	if _plan_bailey != null:
		# NO tower pair on the keep's south corners: two round towers at
		# the foot of a long narrow keep draw a very unfortunate shape.
		var kr = _plan_bailey["keep"]
		var ky = kr.position.y + kr.size.y
		for kx in [kr.position.x, kr.position.x + kr.size.x]:
			if abs(cp.x - float(kx)) < 1.25 and abs(cp.y - float(ky)) < 1.25:
				return false
	var wox = Global.World.WoxelDimensions
	var gx1 = wox.x / CELL - float(acx)
	var gy1 = wox.y / CELL - float(acy)
	if cp.x - rc < -float(acx) + 0.1 or cp.x + rc > gx1 - 0.1 \
			or cp.y - rc < -float(acy) + 0.1 or cp.y + rc > gy1 - 0.1:
		return false
	if not _plan_tower_fits(mask, cw, ch, cp, k, rc):
		return false
	var dxs_w = 1
	if k == 0 or k == 2:
		dxs_w = -1
	var dys_w = 1
	if k == 0 or k == 1:
		dys_w = -1
	var need = int(ceil(rc - 0.01))
	var vs0 = int(cp.y)
	var vs1 = int(cp.y) + need
	if dys_w < 0:
		vs0 = int(cp.y) - need
		vs1 = int(cp.y)
	var hs0 = int(cp.x)
	var hs1 = int(cp.x) + need
	if dxs_w < 0:
		hs0 = int(cp.x) - need
		hs1 = int(cp.x)
	if _plan_find_solid_run(runs, true, int(cp.x), vs0, vs1, true, "ext") == null:
		return false
	if _plan_find_solid_run(runs, false, int(cp.y), hs0, hs1, true, "ext") == null:
		return false
	if _plan_tower_stranger_wall(runs, cp, rc):
		return false
	return true


# Carves the walls and appends the tower arc, stretched to any wall ends
# landing on the circle inside the open quadrant.
func _plan_tower_place(runs: Array, cp: Vector2, k: int, r_cells: float, acx: int, acy: int, out_arcs: Array) -> void:
	var lands = _plan_carve_circle(runs, cp, r_cells, k)
	_plan_cur_towers.append([cp, r_cells])
	var quads = [[PI, PI * 1.5], [PI * 1.5, PI * 2.0], [PI * 0.5, PI], [0.0, PI * 0.5]]
	var q = quads[k]
	var pts = [q[0], q[1]]
	for la in lands:
		var an = la
		while an < 0.0:
			an += PI * 2.0
		while an >= PI * 2.0:
			an -= PI * 2.0
		var near_end = false
		for qe in [q[0], q[1]]:
			var da2 = abs(an - qe)
			if da2 > PI:
				da2 = PI * 2.0 - da2
			if da2 < 0.25:
				near_end = true
				break
		if not near_end:
			pts.append(an)
	pts.sort()
	var mid = (q[0] + q[1]) * 0.5
	var ga0 = q[1]
	var ga1 = q[0] + PI * 2.0
	for gi in range(pts.size()):
		var p0a = pts[gi]
		var p1a = pts[(gi + 1) % pts.size()]
		if (gi + 1) == pts.size():
			p1a += PI * 2.0
		var m2 = mid
		if m2 < p0a:
			m2 += PI * 2.0
		if m2 > p0a and m2 < p1a and p1a - p0a > 0.3:
			ga0 = p1a
			ga1 = p0a + PI * 2.0
			break
	if ga1 - ga0 > PI * 2.0 - 0.3 or ga1 <= ga0:
		ga0 = q[1]
		ga1 = q[0] + PI * 2.0
	out_arcs.append({
		"c": Vector2((acx + cp.x) * CELL, (acy + cp.y) * CELL),
		"r": r_cells * CELL,
		"a0": ga0,
		"a1": ga1
	})


# The two unit wall edges meeting at a convex corner. Returns [run, offset]
# pairs or an empty array.
func _plan_cap(group: String) -> int:
	var caps = {"corridor": 10, "hall": 9, "living": 6, "dining": 4,
		"kitchen": 2, "study": 2}
	return int(caps.get(group, 0))


# Pairs that must NEVER get a door, even as an accessibility last resort:
# bedrooms between themselves (master included), and the kitchen against
# study/bathroom/bedroom.
func _plan_pair_forbidden(cats: Dictionary, a: int, b: int) -> bool:
	var ga = _plan_cat_group(String(cats.get(a, "")))
	var gb = _plan_cat_group(String(cats.get(b, "")))
	if ga == "bedroom" and gb == "bedroom":
		return true
	if ga == "kitchen" and (gb == "study" or gb == "bedroom"):
		return true
	if gb == "kitchen" and (ga == "study" or ga == "bedroom"):
		return true
	if ga == "study" and (gb == "bathroom" or gb == "bedroom"):
		return true
	if gb == "study" and (ga == "bathroom" or ga == "bedroom"):
		return true
	return false


func _plan_pair_ok(cats: Dictionary, a: int, b: int) -> bool:
	var rules = {
		"bathroom": {"corridor": true, "bedroom": true, "living": true},
		"closet": {"corridor": true, "hall": true, "bedroom": true, "living": true},
		"storage": {"corridor": true, "hall": true, "kitchen": true},
		"staircase": {"corridor": true, "hall": true, "living": true},
		"bedroom": {"corridor": true, "hall": true, "living": true, "dining": true},
		"dining": {"kitchen": true, "hall": true, "living": true, "corridor": true},
		"kitchen": {"corridor": true, "hall": true, "living": true, "dining": true, "bathroom": true},
		"study": {"corridor": true, "hall": true, "living": true, "dining": true}
	}
	var hosts = {"hall": true, "corridor": true, "living": true, "dining": true, "kitchen": true, "study": true}
	var ca = _plan_cat_group(String(cats.get(a, "")))
	var cb = _plan_cat_group(String(cats.get(b, "")))
	var ok_a = hosts.has(cb)
	if rules.has(ca):
		ok_a = rules[ca].has(cb)
	var ok_b = hosts.has(ca)
	if rules.has(cb):
		ok_b = rules[cb].has(ca)
	# A door is fine when either side's rule allows the pair (an ensuite
	# bathroom opens into a bedroom); bedroom-bedroom allows neither way.
	return ok_a or ok_b


func _plan_forced_door(run) -> void:
	# Centered when possible, else the first clean half-cell position; a raw
	# centered append only as the very last resort.
	var len_r = float(_plan_run_len(run))
	if _plan_try_hole(run, stepify((len_r - 1.0) * 0.5, 0.5), 1.0, "door"):
		return
	var pos = 0.0
	while pos <= len_r - 1.0:
		if _plan_try_hole(run, pos, 1.0, "door"):
			return
		pos += 0.5
	run["holes"].append([stepify((len_r - 1.0) * 0.5, 0.5), 1.0, "door"])


func _plan_diag_free(p: Vector2) -> bool:
	for q in _plan_diag_pts:
		if p.distance_to(q) < 1.9:
			return false
	return true


# Punches one structural "cut" spanning the absolute cell range
# [a0, a1) on the wall line, spread across every collinear run covering
# it. Returns the placed [run, hole] pairs for rollback, or null when
# the span is not fully walled or collides with an existing hole.
func _plan_cut_wall(runs: Array, vert: bool, line: int, a0: int, a1: int, wall_kind: String = ""):
	var parts = []
	var cov = []
	for c in range(a0, a1):
		cov.append(false)
	for run in runs:
		if bool(run["vert"]) != vert:
			continue
		if wall_kind != "" and String(run["kind"]) != wall_kind:
			# Never mix wall families: an INTERIOR run collinear with an
			# exterior wall must not vouch for exterior coverage (that
			# put bevel cuts on interior walls and left floating
			# diagonals next to wall holes).
			continue
		var r0 = 0
		var r1 = 0
		if vert:
			if int(run["x"]) != line:
				continue
			r0 = int(run["y0"])
			r1 = int(run["y1"])
		else:
			if int(run["y"]) != line:
				continue
			r0 = int(run["x0"])
			r1 = int(run["x1"])
		var o0 = int(max(a0, r0))
		var o1 = int(min(a1, r1))
		if o1 <= o0:
			continue
		for h in run["holes"]:
			var ha = float(r0) + float(h[0])
			var hb = ha + float(h[1])
			# ONE-CELL CLEARANCE, like the historical try_hole: two cuts
			# meeting edge-to-edge (two bevels at both ends of a short
			# wall) eat the whole wall, the diagonals lose their anchors
			# and the prune deletes them too - entire wall stretches
			# vanished on small footprints.
			if ha < float(o1) + 1.0 and hb > float(o0) - 1.0:
				return null
		parts.append([run, o0 - r0, o1 - o0])
		for c2 in range(o0, o1):
			cov[c2 - a0] = true
	for c3 in cov:
		if not c3:
			return null
	var placed = []
	for p in parts:
		var hole = [float(p[1]), float(p[2]), "cut"]
		p[0]["holes"].append(hole)
		placed.append([p[0], hole])
	return placed


# Like _plan_cut_wall but with NO coverage requirement: cuts whatever
# wall portions exist on the span and ignores the rest. Used to trim
# interior walls that poke through a fresh bevel diagonal.
func _plan_cut_wall_partial(runs: Array, vert: bool, line: int, a0: int, a1: int, wall_kind: String = "") -> void:
	if a1 <= a0:
		return
	for run in runs:
		if bool(run["vert"]) != vert:
			continue
		if wall_kind != "" and String(run["kind"]) != wall_kind:
			continue
		var r0 = 0
		var r1 = 0
		if vert:
			if int(run["x"]) != line:
				continue
			r0 = int(run["y0"])
			r1 = int(run["y1"])
		else:
			if int(run["y"]) != line:
				continue
			r0 = int(run["x0"])
			r1 = int(run["x1"])
		var o0 = int(max(a0, r0))
		var o1 = int(min(a1, r1))
		if o1 <= o0:
			continue
		var blocked = false
		for h in run["holes"]:
			var ha = float(r0) + float(h[0])
			var hb = ha + float(h[1])
			if ha < float(o1) and hb > float(o0):
				blocked = true
				break
		if not blocked:
			run["holes"].append([float(o0 - r0), float(o1 - o0), "cut"])


func _plan_cut_rollback(placed) -> void:
	if placed == null:
		return
	for pr in placed:
		pr[0]["holes"].erase(pr[1])


# True when an INTERIOR wall abuts one of the two cut edges of a bevel
# of that size: its junction would sit inside the removed span, leaving
# a wall pointing at the diagonal.
func _plan_bevel_int_conflict(runs: Array, px: int, py: int, sv: int, sh: int, bsize: int) -> bool:
	for run in runs:
		if String(run["kind"]) != "int":
			continue
		if bool(run["vert"]):
			var xi = int(run["x"])
			var dxa = (px - xi) * sh
			if dxa < 1 or dxa >= bsize:
				continue
			if int(run["y0"]) == py or int(run["y1"]) == py:
				return true
		else:
			var yi = int(run["y"])
			var dya = (py - yi) * sv
			if dya < 1 or dya >= bsize:
				continue
			if int(run["x0"]) == px or int(run["x1"]) == px:
				return true
	return false


func _plan_bevel_corner(rng, runs: Array, corner, acx: int, acy: int, out_segs: Array, bsize: int, wall_kind: String = "ext") -> bool:
	if not _plan_diag_free(corner["p"]):
		return false
	var px = int(corner["p"].x)
	var py = int(corner["p"].y)
	var k = int(corner["cell"])
	var sv = 1
	if k == 2 or k == 3:
		sv = -1
	var sh = 1
	if k == 1 or k == 3:
		sh = -1
	# The removed cells extend away from the corner. Spans are absolute
	# cell ranges; the cut is spread across every collinear run covering
	# them, so exterior runs segmented by INTERIOR rooms can never fail
	# a bevel (Shape Seed work must not depend on the Rooms Seed).
	var runs_arr = runs
	var placed0 = null
	while bsize >= 1:
		var v0 = py - bsize if sv > 0 else py
		var v1 = py if sv > 0 else py + bsize
		var g0 = px - bsize if sh > 0 else px
		var g1 = px if sh > 0 else px + bsize
		placed0 = _plan_cut_wall(runs_arr, true, px, v0, v1, wall_kind)
		if placed0 == null:
			bsize -= 1
			continue
		var placed1 = _plan_cut_wall(runs_arr, false, py, g0, g1, wall_kind)
		if placed1 == null:
			_plan_cut_rollback(placed0)
			bsize -= 1
			continue
		if wall_kind == "ext" and _plan_bevel_int_conflict(runs, px, py, sv, sh, bsize):
			# An interior wall lands right on a clipped edge: the T
			# against the diagonal reads badly - retry smaller, so the
			# chamfer stops before the interior wall instead.
			_plan_cut_rollback(placed0)
			_plan_cut_rollback(placed1)
			bsize -= 1
			continue
		break
	if bsize < 1 or placed0 == null:
		return false
	out_segs.append([
		Vector2((acx + px) * CELL, (acy + py - sv * bsize) * CELL),
		Vector2((acx + px - sh * bsize) * CELL, (acy + py) * CELL)
	])
	_plan_diag_pts.append(corner["p"])
	_plan_diag_pts.append(Vector2(px, py - sv * bsize))
	_plan_diag_pts.append(Vector2(px - sh * bsize, py))
	if wall_kind == "ext":
		# Interior walls poking through the fresh diagonal are clipped
		# GEOMETRICALLY at emission (see _plan_clip_seg_tris): mutating
		# the interior runs this early rippled through every later pass.
		_plan_bevel_tris.append([px, py, k, bsize])
	return true


func _plan_tower_fits(mask: Array, cw: int, ch: int, cp: Vector2, k: int, r: float) -> bool:
	# Every inside cell whose center falls within the circle must belong to
	# the corner's interior quadrant, otherwise the exterior arc would cross
	# the building.
	var x0 = int(max(0, floor(cp.x - r - 1.0)))
	var x1 = int(min(cw - 1, ceil(cp.x + r)))
	var y0 = int(max(0, floor(cp.y - r - 1.0)))
	var y1 = int(min(ch - 1, ceil(cp.y + r)))
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if mask[y * cw + x] != 1:
				continue
			var c = Vector2(float(x) + 0.5, float(y) + 0.5)
			if c.distance_to(cp) >= r + 0.2:
				continue
			var dx = c.x - cp.x
			var dy = c.y - cp.y
			var ok = false
			if k == 0:
				ok = dx < 0.0 and dy < 0.0
			elif k == 1:
				ok = dx > 0.0 and dy < 0.0
			elif k == 2:
				ok = dx < 0.0 and dy > 0.0
			else:
				ok = dx > 0.0 and dy > 0.0
			if not ok:
				return false
	return true


# True when an exterior wall OTHER than the corner's own two wall lines
# crosses the tower disc: its cut end would land on the open (undrawn)
# quadrant of the arc.
func _plan_tower_stranger_wall(runs: Array, cp: Vector2, r: float) -> bool:
	for run in runs:
		if String(run["kind"]) != "ext":
			continue
		if bool(run["vert"]):
			if abs(float(run["x"]) - cp.x) < 0.5:
				continue
			var d = float(run["x"]) - cp.x
			if abs(d) >= r:
				continue
			var half = sqrt(r * r - d * d)
			if min(float(run["y1"]), cp.y + half) - max(float(run["y0"]), cp.y - half) > 0.15:
				return true
		else:
			if abs(float(run["y"]) - cp.y) < 0.5:
				continue
			var d2 = float(run["y"]) - cp.y
			if abs(d2) >= r:
				continue
			var half2 = sqrt(r * r - d2 * d2)
			if min(float(run["x1"]), cp.x + half2) - max(float(run["x0"]), cp.x - half2) > 0.15:
				return true
	return false


func _plan_carve_circle(runs: Array, cp: Vector2, r: float, k: int) -> Array:
	# Returns the ANGLES (canvas, y down) where a cut wall end lands on
	# the circle inside the OPEN quadrant: the caller stretches the arc
	# to meet them, closing the room against the tower (an arc end must
	# always sit on a wall).
	var landings = []
	# Cuts every run exactly where it crosses the tower circle, with float
	# precision: wall ends land ON the arc. The portion of a chord lying in
	# the OPEN quadrant (the building side, where no arc is drawn) is NOT
	# cut: cutting there left walls ending on nothing.
	var dxs = 1
	if k == 0 or k == 2:
		dxs = -1
	var dys = 1
	if k == 0 or k == 1:
		dys = -1
	for run in runs:
		if bool(run["vert"]):
			var d = float(run["x"]) - cp.x
			if abs(d) >= r:
				continue
			var half = sqrt(r * r - d * d)
			var y0 = cp.y - half
			var y1 = cp.y + half
			if (d > 0.001 and dxs > 0) or (d < -0.001 and dxs < 0):
				# Open-quadrant x side: only cut the closed-y half - a
				# wall CROSSING the open side must reach through (no arc
				# to land on there). But a wall ENDING inside the disc
				# would dangle in the void: cut it to its very end.
				# Walls merely GRAZING the circle (|d| ~ r) are skipped:
				# their landing sits almost on the arc's standard end and
				# would stretch the arc into a near-closed circle.
				var graze = abs(d) > r - 0.35
				var ry0 = float(run["y0"])
				var ry1 = float(run["y1"])
				if graze:
					if dys > 0:
						y1 = min(y1, cp.y)
					else:
						y0 = max(y0, cp.y)
					if y1 - y0 > 0.02:
						_plan_force_hole(run, y0 - float(run["y0"]), y1 - y0)
					continue
				if dys > 0:
					# Open half below: cut any wall END dangling in it.
					# Bounds INCLUDE the corner lines themselves: a wall
					# T-joining the corner wall inside the disc dangles
					# too, its host got carved there.
					if ry1 < y1 - 0.02 and ry1 > cp.y - 0.02:
						_plan_force_hole(run, cp.y - ry0, ry1 - cp.y)
					if ry0 > cp.y - 0.02 and ry0 < y1 - 0.02:
						_plan_force_hole(run, 0.0, y1 - ry0)
						landings.append(atan2(y1 - cp.y, d))
					y1 = min(y1, cp.y)
				else:
					# Open half above.
					if ry0 > y0 + 0.02 and ry0 < cp.y + 0.02:
						_plan_force_hole(run, 0.0, cp.y - ry0)
					if ry1 < cp.y + 0.02 and ry1 > y0 + 0.02:
						_plan_force_hole(run, y0 - ry0, ry1 - y0)
						landings.append(atan2(y0 - cp.y, d))
					y0 = max(y0, cp.y)
			if y1 - y0 > 0.02:
				_plan_force_hole(run, y0 - float(run["y0"]), y1 - y0)
		else:
			var d2 = float(run["y"]) - cp.y
			if abs(d2) >= r:
				continue
			var half2 = sqrt(r * r - d2 * d2)
			var x0 = cp.x - half2
			var x1 = cp.x + half2
			if (d2 > 0.001 and dys > 0) or (d2 < -0.001 and dys < 0):
				var graze2 = abs(d2) > r - 0.35
				var rx0 = float(run["x0"])
				var rx1 = float(run["x1"])
				if graze2:
					if dxs > 0:
						x1 = min(x1, cp.x)
					else:
						x0 = max(x0, cp.x)
					if x1 - x0 > 0.02:
						_plan_force_hole(run, x0 - float(run["x0"]), x1 - x0)
					continue
				if dxs > 0:
					if rx1 < x1 - 0.02 and rx1 > cp.x - 0.02:
						_plan_force_hole(run, cp.x - rx0, rx1 - cp.x)
					if rx0 > cp.x - 0.02 and rx0 < x1 - 0.02:
						_plan_force_hole(run, 0.0, x1 - rx0)
						landings.append(atan2(d2, x1 - cp.x))
					x1 = min(x1, cp.x)
				else:
					if rx0 > x0 + 0.02 and rx0 < cp.x + 0.02:
						_plan_force_hole(run, 0.0, cp.x - rx0)
					if rx1 < cp.x + 0.02 and rx1 > x0 + 0.02:
						_plan_force_hole(run, x0 - rx0, rx1 - x0)
						landings.append(atan2(d2, x0 - cp.x))
					x0 = max(x0, cp.x)
			if x1 - x0 > 0.02:
				_plan_force_hole(run, x0 - float(run["x0"]), x1 - x0)
	return landings


func _plan_run_intervals(run) -> Array:
	# The run's cell range minus its holes, as [start, end] float pairs.
	var out = []
	for iv in _plan_run_intervals_ex(run):
		out.append([iv[0], iv[1]])
	return out


func _plan_run_intervals_ex(run) -> Array:
	# [start, end, left_neighbor, right_neighbor] where neighbors are "end"
	# (the run's extremity, i.e. a wall junction) or the hole type.
	var len_r = float(_plan_run_len(run))
	var holes = run["holes"].duplicate()
	holes.sort_custom(self, "_plan_hole_sort")
	var out = []
	var pos = 0.0
	var left = "end"
	for h in holes:
		if float(h[0]) > pos + 0.05:
			out.append([pos, float(h[0]), left, String(h[2])])
		if float(h[0]) + float(h[1]) > pos:
			left = String(h[2])
		pos = max(pos, float(h[0]) + float(h[1]))
	if pos < len_r - 0.05:
		out.append([pos, len_r, left, "end"])
	return out


func _plan_hole_sort(a, b) -> bool:
	return float(a[0]) < float(b[0])


# Post-layout corner-door pass. The payload walls are ALREADY split
# around every opening, so a door's own hole edges must not count as
# corners: a real corner is a PERPENDICULAR wall passing by the
# endpoint, or the wall simply not continuing past it. A cornered door
# slides half a cell away when the wall line carries the shifted span
# (its old opening counts as carried: the shift MOVES the opening -
# old span refilled, new span cut); a stuck door is dropped, leaving
# the plain gap that already exists in the walls.
func _plan_fix_corner_doors(segs: Array, doors: Array, arcs: Array) -> Array:
	var dropped = []
	var shifted = []
	var n_shift = 0
	var out_doors = []
	for d in doors:
		var a = d[0]
		var b = d[1]
		if a.distance_to(b) < 1.0:
			continue
		var dirv = (b - a).normalized()
		var na = _plan_end_cornered(a, dirv, segs, a, b) or _plan_in_tower(a, arcs)
		var nb = _plan_end_cornered(b, dirv, segs, a, b) or _plan_in_tower(b, arcs)
		if not na and not nb and _plan_in_tower((a + b) * 0.5, arcs):
			# Deep tower overlap with both ends clear: unmovable.
			na = true
			nb = true
		if not na and not nb:
			out_doors.append(d)
			continue
		var moved = false
		if na != nb:
			var shift = dirv * (CELL * 0.5)
			if nb:
				shift = -shift
			var a2 = a + shift
			var b2 = b + shift
			if _plan_line_cover(a2, b2, segs, a, b) \
					and not _plan_end_cornered(a2, dirv, segs, a, b) \
					and not _plan_end_cornered(b2, dirv, segs, a, b) \
					and not _plan_in_tower(a2, arcs) \
					and not _plan_in_tower(b2, arcs) \
					and not _plan_in_tower((a2 + b2) * 0.5, arcs):
				# Move the opening along with the door.
				segs.append([a, b])
				segs = _plan_cut_span(segs, a2, b2)
				out_doors.append([a2, b2])
				shifted.append([a2, b2])
				moved = true
		if not moved:
			# The door marker goes away AND its wall gap is refilled: a
			# doorless hole next to a corner unanchored the chamfer
			# diagonals and cascaded into missing exterior stretches.
			segs.append([a, b])
			dropped.append([a, b])
			printerr("[SketchPlan] cornered door dropped at ", (a + b) * 0.5)
		else:
			n_shift += 1
			printerr("[SketchPlan] cornered door shifted at ", (a + b) * 0.5)
	printerr("[SketchPlan] corner-door pass: ", doors.size(), " doors, ",
		n_shift, " shifted, ", dropped.size(), " dropped")
	return [segs, out_doors, dropped, shifted]


# Inside (or hugging) a tower circle? Towers clip the walls, so a door
# overlapping the disc hangs over the gap: same treatment as a corner.
func _plan_in_tower(p: Vector2, arcs: Array) -> bool:
	for a3 in arcs:
		if p.distance_to(a3["c"]) <= float(a3["r"]) + 12.0:
			return true
	return false


func _plan_iv_less(a, b) -> bool:
	return float(a[0]) < float(b[0])


# Is this door endpoint on a real corner? True when a NON-colinear
# wall passes within 12 px, or when the wall LINE does not continue on
# both sides of the endpoint. The wall line includes the door's own
# CURRENT opening [fill_a, fill_b] (it moves with the door): without
# it, a half-cell shift landed inside the old opening and looked like
# a wall end, so nothing ever shifted.
func _plan_end_cornered(e: Vector2, dirv: Vector2, segs: Array, fill_a, fill_b) -> bool:
	var cont = e + dirv * 24.0
	var cont2 = e - dirv * 24.0
	var has_out = false
	var has_in = false
	for sg in segs:
		var u = sg[1] - sg[0]
		var lg = u.length()
		if lg < 1.0:
			continue
		u /= lg
		if abs(u.dot(dirv)) < 0.92:
			# Any non-colinear wall (perpendicular OR diagonal, the 45
			# degree chamfers included): corner if its BODY passes by.
			var q = Geometry.get_closest_point_to_segment_2d(e, sg[0], sg[1])
			if q.distance_to(e) <= 12.0:
				return true
		else:
			# Colinear-ish: does the wall continue past the endpoint?
			if abs((e - sg[0]).cross(u)) > 6.0:
				continue
			var t1 = (cont - sg[0]).dot(u)
			var t2 = (cont2 - sg[0]).dot(u)
			if t1 >= -2.0 and t1 <= lg + 2.0:
				has_out = true
			if t2 >= -2.0 and t2 <= lg + 2.0:
				has_in = true
	if fill_a != null:
		# The virtual fill of the current opening.
		var fu = fill_b - fill_a
		var fl = fu.length()
		if fl >= 1.0:
			fu /= fl
			if abs(fu.dot(dirv)) >= 0.92 and abs((e - fill_a).cross(fu)) <= 6.0:
				var t3 = (cont - fill_a).dot(fu)
				var t4 = (cont2 - fill_a).dot(fu)
				if t3 >= -2.0 and t3 <= fl + 2.0:
					has_out = true
				if t4 >= -2.0 and t4 <= fl + 2.0:
					has_in = true
	return not (has_out and has_in)


# Is [a2, b2] fully carried by the colinear wall line? The union of
# colinear segments plus the door's current opening [a, b] must cover
# the whole span (the walls are split around every opening).
func _plan_line_cover(a2: Vector2, b2: Vector2, segs: Array, a: Vector2, b: Vector2) -> bool:
	var dirv = (b2 - a2).normalized()
	var lg2 = a2.distance_to(b2)
	var ivs = []
	for sg in segs:
		var u = sg[1] - sg[0]
		var lg = u.length()
		if lg < 1.0:
			continue
		u /= lg
		if abs(u.dot(dirv)) < 0.9:
			continue
		if abs((sg[0] - a2).cross(dirv)) > 6.0:
			continue
		var t1 = (sg[0] - a2).dot(dirv)
		var t2 = (sg[1] - a2).dot(dirv)
		ivs.append([min(t1, t2), max(t1, t2)])
	if abs((a - a2).cross(dirv)) <= 6.0:
		var t3 = (a - a2).dot(dirv)
		var t4 = (b - a2).dot(dirv)
		ivs.append([min(t3, t4), max(t3, t4)])
	ivs.sort_custom(self, "_plan_iv_less")
	var reach = 0.0
	for iv in ivs:
		if iv[0] > reach + 3.0:
			break
		reach = max(reach, iv[1])
	return reach >= lg2 - 3.0
	# (reach starts at the span's origin: intervals starting before 0
	# still extend it through the sort order.)


# Opens a gap in the wall network over the [a, b] span (the carrying
# colinear segments lose that interval).
func _plan_cut_span(segs: Array, a: Vector2, b: Vector2) -> Array:
	var out = []
	for sg in segs:
		var u = sg[1] - sg[0]
		var lg = u.length()
		if lg < 1.0:
			out.append(sg)
			continue
		var un = u / lg
		if abs((a - sg[0]).cross(un)) > 4.0 or abs((b - sg[0]).cross(un)) > 4.0:
			out.append(sg)
			continue
		var ta = (a - sg[0]).dot(un)
		var tb = (b - sg[0]).dot(un)
		var t1 = clamp(min(ta, tb), 0.0, lg)
		var t2 = clamp(max(ta, tb), 0.0, lg)
		if t2 - t1 < 2.0:
			out.append(sg)
			continue
		if t1 > 8.0:
			out.append([sg[0], sg[0] + un * t1])
		if t2 < lg - 8.0:
			out.append([sg[0] + un * t2, sg[1]])
	return out


func _plan_run_seg(run, i0: float, i1: float, acx: int, acy: int) -> Array:
	if bool(run["vert"]):
		var x = (acx + int(run["x"])) * CELL
		return [Vector2(x, (acy + int(run["y0"]) + i0) * CELL), Vector2(x, (acy + int(run["y0"]) + i1) * CELL)]
	var y = (acy + int(run["y"])) * CELL
	return [Vector2((acx + int(run["x0"]) + i0) * CELL, y), Vector2((acx + int(run["x0"]) + i1) * CELL, y)]


func _on_plan_ext_only_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_plan_ext_only = v
	_plan_regen_same()


func _on_plan_min_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_min = int(v)


func _on_plan_max_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_max = int(v)


func _on_plan_cpx_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_complexity = v


func _on_plan_corr_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_corr = v


func _on_plan_orig_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_orig = v


func _on_plan_irr_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_room_irr = v


func _on_plan_labels_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_plan_labels = v
	_save_settings()
	_update_labels_overlay()


func _on_plan_openings_toggled(v: bool) -> void:
	if _sync_ui:
		return
	_plan_openings = v
	_plan_regen_same()


func _on_plan_towers_changed(v: float) -> void:
	if _sync_ui:
		return
	_plan_tower_count = int(v)


func _on_plan_auto_random_toggled(v: bool) -> void:
	if _sync_ui:
		return
	# The global dice drives every per-setting dice.
	_sync_ui = true
	for k in _plan_rand_flags:
		_plan_rand_flags[k] = v
		if _plan_rand_btns.has(k) and is_instance_valid(_plan_rand_btns[k]):
			_plan_rand_btns[k].pressed = v
	_sync_ui = false
	_float_update_rand_tint()


func _on_plan_rand_flag(v: bool, key: String) -> void:
	if _sync_ui:
		return
	_plan_rand_flags[key] = v
	# The global dice lights up as soon as one setting is randomized.
	var any_on = false
	for k in _plan_rand_flags:
		if bool(_plan_rand_flags[k]):
			any_on = true
			break
	if _btn_rand_global != null and is_instance_valid(_btn_rand_global):
		_sync_ui = true
		_btn_rand_global.pressed = any_on
		_sync_ui = false
	_float_update_rand_tint()


func _plan_apply_rand_flags() -> void:
	for k in _plan_rand_flags:
		if bool(_plan_rand_flags[k]):
			_plan_randomize_one(String(k))


func _plan_ui_rng():
	if _ui_rng == null:
		_ui_rng = RandomNumberGenerator.new()
		_ui_rng.randomize()
	return _ui_rng


func _plan_randomize_one(key: String) -> void:
	if key == "min":
		if _slider_plan_min != null and is_instance_valid(_slider_plan_min):
			_slider_plan_min.value = float(1 + _plan_ui_rng().randi() % 4)
	elif key == "max":
		var mn = int(_plan_min)
		if _slider_plan_max != null and is_instance_valid(_slider_plan_max):
			_slider_plan_max.value = float(int(clamp(mn + 2 + int(_plan_ui_rng().randi() % 9), mn + 1, 24)))
	elif key == "cpx":
		if _slider_plan_cpx != null and is_instance_valid(_slider_plan_cpx):
			_slider_plan_cpx.value = stepify(_plan_ui_rng().randf(), 0.05)
	elif key == "corr":
		if _slider_plan_corr != null and is_instance_valid(_slider_plan_corr):
			_slider_plan_corr.value = stepify(_plan_ui_rng().randf(), 0.05)
	elif key == "orig":
		if _slider_plan_orig != null and is_instance_valid(_slider_plan_orig):
			_slider_plan_orig.value = stepify(_plan_ui_rng().randf(), 0.05)
	elif key == "irr":
		if _slider_plan_irr != null and is_instance_valid(_slider_plan_irr):
			_slider_plan_irr.value = stepify(_plan_ui_rng().randf(), 0.05)
	elif key == "towers":
		if _slider_plan_towers != null and is_instance_valid(_slider_plan_towers):
			_slider_plan_towers.value = float(_plan_ui_rng().randi() % 6)


# ============================================================================
# Drawing (proxy callbacks)
# ============================================================================

# Draws the current stroke as a full-opacity white mask, in texture pixels.
func _draw_stroke_buffer(item) -> void:
	if _plan_render != null:
		_draw_plan(item)
		return
	if _stroke == null:
		return
	var erase = bool(_stroke["erase"])
	var snapping = Global.Editor.get("IsSnapping") == true
	if not _snap_probe_done:
		_snap_probe_done = true
		printerr("[SketchDraw] IsSnapping=", Global.Editor.get("IsSnapping"))
	# The buffer is drawn in real colors (interior can differ from the
	# border); erase strokes only use the alpha channel, so plain white.
	var col = Color(1, 1, 1, 1)
	var fill = Color(1, 1, 1, 1)
	if not erase:
		col = _stroke["color"]
		fill = _stroke["fill_color"]
	var w = max(1.0, float(_stroke["width"]) * _tex_scale)
	if erase:
		# Widen so the erase coverage exceeds the painted AA edge it
		# targets (pairs with the x4 mask sharpening in the shaders).
		w += 2.0
	# Portal colors get a black WALL underlay at double width beneath the
	# colored stroke (drawing a window IS drawing its wall), the same
	# convention as the segment tool and the generator.
	if not erase and (col.is_equal_approx(WINDOW_COLOR) or col.is_equal_approx(DOOR_COLOR)):
		_draw_stroke_pass(item, snapping, Color(0, 0, 0, 1), fill, w * 2.0, false)
	_draw_stroke_pass(item, snapping, col, fill, w, true)


func _draw_stroke_pass(item, snapping: bool, col: Color, fill: Color, w: float, with_fill: bool) -> void:
	var erase = bool(_stroke["erase"])
	var style = int(_stroke["style"])
	var mode = int(_stroke["mode"])
	var soft = not snapping
	if mode == MODE_FREE or mode == MODE_ERASE or mode == MODE_LINE or mode == MODE_BRUSH:
		# Freehand and Line follow their own Square/Round choice (square
		# stamps stay hard-edged); the eraser and brush keep theirs. The
		# fixed kinds (wall / window / door) always stamp SQUARE: crisp
		# structure strokes, only the free Brush kind honors the toggle.
		var square = _paint_square
		if (mode == MODE_FREE or mode == MODE_LINE) and _paint_kind != 0:
			square = true
		if mode == MODE_RECT or mode == MODE_ELLIPSE:
			# Shapes are structure silhouettes: hard square stamps, the
			# Round/Square choice only belongs to the free strokes.
			square = true
		soft = not snapping and not square
		if mode == MODE_ERASE:
			square = _eraser_square
			soft = false
		elif mode == MODE_BRUSH:
			square = _brush_square
			soft = false
		var pts = _stroke["pts"]
		if pts.size() > 1:
			for i in range(pts.size() - 1):
				item.draw_line(pts[i] * _tex_scale, pts[i + 1] * _tex_scale, col, w, soft)
		for p in pts:
			if square:
				item.draw_rect(Rect2(p * _tex_scale - Vector2(w, w) * 0.5, Vector2(w, w)), col, true)
			else:
				item.draw_circle(p * _tex_scale, w * 0.5, col)
	elif mode == MODE_RECT:
		var r = _tex_rect_from_stroke()
		if r.size.x < 0.5 or r.size.y < 0.5:
			return
		# Outline centered ON the snap rect (it used to sit inside it).
		var ro = r
		if erase:
			if style == SHAPE_OUTLINE and not bool(_stroke.get("sub", false)):
				item.draw_rect(ro, col, false, w, false)
			else:
				item.draw_rect(r.grow(1.5), col, true)
		else:
			if with_fill and style != SHAPE_OUTLINE:
				item.draw_rect(r, fill, true)
			if style != SHAPE_FILL:
				# Antialiased like the freehand stroke: the display
				# shader's x4 mask sharpening inflates the AA feather,
				# so hard-edged shape outlines rendered visibly THINNER
				# than the normal (soft) strokes at the same width.
				item.draw_rect(ro, col, false, w, true)
	elif mode == MODE_ELLIPSE:
		var r = _tex_rect_from_stroke()
		if r.size.x < 0.5 or r.size.y < 0.5:
			return
		if erase and style != SHAPE_OUTLINE:
			r = r.grow(1.5)
		var c = r.position + r.size * 0.5
		# Outline centered ON the snap ellipse (it used to sit outside).
		var rx = r.size.x * 0.5
		var ry = r.size.y * 0.5
		var pts = PoolVector2Array()
		for i in range(ELLIPSE_SEGMENTS):
			var a = float(i) / float(ELLIPSE_SEGMENTS) * PI * 2.0
			pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
		var closed = PoolVector2Array(pts)
		closed.append(pts[0])
		if erase:
			if style == SHAPE_OUTLINE and not bool(_stroke.get("sub", false)):
				item.draw_polyline(closed, col, w, soft)
				for p in pts:
					item.draw_circle(p, w * 0.5, col)
			else:
				item.draw_colored_polygon(pts, col)
		else:
			if with_fill and style != SHAPE_OUTLINE:
				item.draw_colored_polygon(pts, fill)
			if style != SHAPE_FILL:
				# Antialiased for the same reason as the rectangle.
				item.draw_polyline(closed, col, w, true)
				for p in pts:
					item.draw_circle(p, w * 0.5, col)


func _tex_rect_from_stroke() -> Rect2:
	var r = _stroke["rect"]
	return Rect2(r.position * _tex_scale, r.size * _tex_scale)


# Brush ring at the cursor, in world pixels (only for Freehand/Eraser/Line).
func _draw_cursor(item) -> void:
	if not _tool_active:
		return
	if _cv_area_pick or _shape_area_pick or _mode == MODE_SELECT:
		# DD manages its own cursor over the map: draw the crosshair on
		# the overlay ourselves, and keep nudging the OS default shape.
		if _cv_area_pick or _shape_area_pick:
			Input.set_default_cursor_shape(Input.CURSOR_CROSS)
		var pc2 = _snap_point(_mouse_world())
		var lw3 = _ui_px(1.5)
		var arm2 = _ui_px(14.0)
		item.draw_line(pc2 - Vector2(arm2, 0), pc2 + Vector2(arm2, 0), Color(0, 0, 0, 0.9), lw3 * 2.0, true)
		item.draw_line(pc2 - Vector2(0, arm2), pc2 + Vector2(0, arm2), Color(0, 0, 0, 0.9), lw3 * 2.0, true)
		item.draw_line(pc2 - Vector2(arm2, 0), pc2 + Vector2(arm2, 0), Color(1, 1, 1, 0.9), lw3, true)
		item.draw_line(pc2 - Vector2(0, arm2), pc2 + Vector2(0, arm2), Color(1, 1, 1, 0.9), lw3, true)
		return
	if PLAN_DEBUG_MARKS and _mode == MODE_PLAN:
		# PINK = dropped doors, GREEN = shifted doors (see the
		# PLAN_DEBUG_MARKS switch next to _plan_dbg_drop).
		for dd in _plan_dbg_drop:
			item.draw_line(dd[0], dd[1], Color(0, 0, 0, 0.9), _ui_px(10.0), true)
			item.draw_line(dd[0], dd[1], Color(1, 0.25, 0.75, 0.95), _ui_px(6.0), true)
			item.draw_circle(dd[0], _ui_px(8.0), Color(1, 0.25, 0.75, 0.95))
			item.draw_circle(dd[1], _ui_px(8.0), Color(1, 0.25, 0.75, 0.95))
		for ds in _plan_dbg_shift:
			item.draw_line(ds[0], ds[1], Color(0, 0, 0, 0.9), _ui_px(10.0), true)
			item.draw_line(ds[0], ds[1], Color(0.2, 0.95, 0.35, 0.95), _ui_px(6.0), true)
			item.draw_circle(ds[0], _ui_px(8.0), Color(0.2, 0.95, 0.35, 0.95))
			item.draw_circle(ds[1], _ui_px(8.0), Color(0.2, 0.95, 0.35, 0.95))
	if _mode != MODE_FREE and _mode != MODE_ERASE and _mode != MODE_LINE and _mode != MODE_BRUSH:
		return
	var w = _paint_width()
	if _mode == MODE_ERASE:
		w = _eraser_width
	elif _mode == MODE_BRUSH:
		w = _brush_width
	# The preview follows the snap, exactly like the stroke will.
	var p = _snap_point(_mouse_world())
	var lw = _ui_px(1.5)
	var cur_square = _paint_square
	if _kind_active() and _paint_kind != 0:
		cur_square = true
	if _mode == MODE_ERASE:
		cur_square = _eraser_square
	elif _mode == MODE_BRUSH:
		cur_square = _brush_square
	if cur_square:
		var half = Vector2(w, w) * 0.5
		item.draw_rect(Rect2(p - half, Vector2(w, w)), Color(0, 0, 0, 0.8), false, lw, true)
		item.draw_rect(Rect2(p - half - Vector2(lw, lw), Vector2(w + lw * 2.0, w + lw * 2.0)),
			Color(1, 1, 1, 0.8), false, lw, true)
	else:
		item.draw_arc(p, max(1.0, w * 0.5), 0.0, PI * 2.0, 48, Color(0, 0, 0, 0.8), lw, true)
		item.draw_arc(p, max(1.0, w * 0.5) + lw, 0.0, PI * 2.0, 48, Color(1, 1, 1, 0.8), lw, true)


func _update_cursor() -> void:
	if _cursor_item == null or not is_instance_valid(_cursor_item):
		return
	var show = _tool_active and ((_seg_type < 0 and not _seg_dragging \
		and (_mode == MODE_FREE or _mode == MODE_ERASE \
		or _mode == MODE_LINE or _mode == MODE_BRUSH)) \
		or _cv_area_pick or _shape_area_pick or _mode == MODE_SELECT \
		or (PLAN_DEBUG_MARKS and _mode == MODE_PLAN \
		and (_plan_dbg_drop.size() > 0 or _plan_dbg_shift.size() > 0)))
	_cursor_item.visible = show
	if show:
		_cursor_item.update()


# ============================================================================
# Composite operation queue (renders into viewport A, one op at a time)
# ============================================================================

func _queue_clear() -> void:
	_ops.append({"type": "clear"})


func _queue_load_active() -> void:
	var sk = _active_sketch()
	var b64 = String(sk["png"])
	if b64 == "":
		return
	var raw = Marshalls.base64_to_raw(b64)
	var img = Image.new()
	if img.load_png_from_buffer(raw) != OK:
		print("[SketchTool] WARN: failed to decode sketch '", sk["name"], "'")
		return
	var r = sk["rect"]
	var world_rect = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
	_ops.append({"type": "stamp", "image": img, "tex_rect": Rect2(world_rect.position * _tex_scale, world_rect.size * _tex_scale)})


func _run_ops() -> void:
	if not _nodes_ok():
		return
	if _op_busy > 0:
		_op_busy -= 1
		if _op_busy == 0:
			for n in _op_nodes:
				if n != null and is_instance_valid(n):
					n.queue_free()
			_op_nodes = []
			_dbg("op done")
			var cb = _op_callback
			var args = _op_callback_args
			_op_callback = ""
			_op_callback_args = []
			if cb != "":
				callv(cb, args)
		return
	if _ops.empty():
		return
	var op = _ops.pop_front()
	var t = String(op["type"])
	_dbg("op start: " + t)
	if t == "clear":
		var cr = ColorRect.new()
		cr.rect_position = Vector2()
		cr.rect_size = _tex_size
		cr.material = _mat_clear
		_view_a.add_child(cr)
		_op_nodes.append(cr)
	elif t == "paint":
		# B already holds the stroke in its real colors; the uniform stroke
		# opacity scales all channels (premultiplied compositing).
		var sp = Sprite.new()
		sp.centered = false
		sp.texture = _view_b.get_texture()
		var pi = float(op["intensity"])
		sp.modulate = Color(pi, pi, pi, pi)
		sp.material = _mat_premul
		_view_a.add_child(sp)
		_op_nodes.append(sp)
	elif t == "erase":
		var sp = Sprite.new()
		sp.centered = false
		sp.texture = _view_b.get_texture()
		_mat_erase.set_shader_param("strength", float(op["strength"]))
		sp.material = _mat_erase
		_view_a.add_child(sp)
		_op_nodes.append(sp)
	elif t == "clear_rect":
		var cr = ColorRect.new()
		var rr = op["rect"]
		cr.rect_position = rr.position
		cr.rect_size = rr.size
		cr.material = _mat_clear
		_view_a.add_child(cr)
		_op_nodes.append(cr)
	elif t == "stamp_rotated":
		var sp = Sprite.new()
		sp.centered = true
		sp.texture = op["tex"]
		sp.position = op["center"]
		sp.rotation = float(op["rot"])
		sp.scale = op.get("scale", Vector2(1, 1))
		sp.material = _mat_premul
		_view_a.add_child(sp)
		_op_nodes.append(sp)
	elif t == "stamp":
		var img = op["image"]
		var tex = ImageTexture.new()
		tex.create_from_image(img, 0)
		var sp = Sprite.new()
		sp.centered = false
		sp.texture = tex
		var tr = op["tex_rect"]
		sp.position = tr.position
		if img.get_width() > 0 and img.get_height() > 0:
			sp.scale = Vector2(tr.size.x / img.get_width(), tr.size.y / img.get_height())
		sp.material = _mat_replace
		_view_a.add_child(sp)
		_op_nodes.append(sp)
	else:
		return
	_op_callback = String(op.get("callback", ""))
	_op_callback_args = op.get("args", [])
	_view_a.render_target_update_mode = Viewport.UPDATE_ONCE
	_op_busy = 2


func _readback_a():
	if not _nodes_ok():
		return null
	var img = _view_a.get_texture().get_data()
	if img == null:
		return null
	img.convert(Image.FORMAT_RGBA8)
	if FLIP_READBACK:
		img.flip_y()
	return img


# ============================================================================
# History (DD undo/redo)
# ============================================================================

func _push_history(uid: int, rect: Rect2, pre_img, post_img, sel_data = null, labels_pair = null, shapes_pair = null) -> void:
	var history = Global.Editor.get("History")
	if history == null or not history.has_method("CreateCustomRecord"):
		return
	var rec = _RecordScript.new()
	rec.handler = self
	rec.sketch_uid = uid
	rec.rect = rect
	rec.pre_image = pre_img
	rec.post_image = post_img
	rec.sel_data = sel_data
	if labels_pair != null:
		rec.labels_before = labels_pair[0]
		rec.labels_after = labels_pair[1]
	if shapes_pair != null:
		rec.shapes_before = shapes_pair[0]
		rec.shapes_after = shapes_pair[1]
	history.CreateCustomRecord(rec)


# Called by history records. Stamps the saved rectangle back into the sketch
# identified by uid, switching the active sketch to it if necessary.
func history_apply(uid: int, rect: Rect2, img, sel_data = null, labels = null, shapes = null) -> void:
	if img == null or not _nodes_ok():
		return
	var idx = _sketch_index_by_uid(uid)
	if idx < 0:
		return
	_cancel_stroke()
	_sel_cancel()
	if idx != int(_map_data["active"]):
		_switch_active(idx)
	if labels != null:
		_active_sketch()["labels"] = labels.duplicate(true)
		_write_map_data()
		_update_labels_overlay()
	if shapes != null:
		# Shape commit undone/redone: the merged-shape store rolls back
		# with the pixels.
		_merge_store_write(_active_sketch(), shapes.duplicate(true))
	var cb = "_after_history"
	var args = []
	var stamp_img = img
	if sel_data != null:
		# Undoing a selection commit/delete brings the selection back as a
		# floating selection. The stamped image already contains the lifted
		# hole so everything lands in a single composite pass (no flash).
		cb = "_after_history_refloat"
		args = [sel_data]
		stamp_img = img.duplicate()
		if not bool(sel_data["copy"]):
			var src_rect = sel_data["rect_tex"]
			var off = src_rect.position - rect.position
			var er = sel_data.get("erase_img", null)
			if er == null:
				er = Image.new()
				er.create(int(src_rect.size.x), int(src_rect.size.y), false, Image.FORMAT_RGBA8)
			stamp_img.blit_rect(er, Rect2(Vector2(), er.get_size()), off)
	_ops.append({"type": "stamp", "image": stamp_img, "tex_rect": rect, "callback": cb, "args": args})


func _after_history() -> void:
	_mark_dirty()


func _after_history_refloat(sd) -> void:
	var pre_full = _readback_a()
	if pre_full == null or sd == null:
		_mark_dirty()
		return
	# The readback shows the lifted hole; patch the source region back to get
	# the pre-lift snapshot the float invariants rely on.
	if not bool(sd["copy"]):
		var ri = sd.get("restore_img", sd["img"])
		pre_full.blit_rect(ri, Rect2(Vector2(), ri.get_size()), sd["rect_tex"].position)
	_change_mode(MODE_SELECT)
	_sel_float_from_data(sd, pre_full, true)
	_mark_dirty()


# ============================================================================
# Serialization (per-sketch PNG blob into map data)
# ============================================================================

func _mark_dirty() -> void:
	# Any raster change makes the Reroll wipe image stale (undo, strokes,
	# selection commits...): restoring it would resurrect older content.
	_last_plan_undo = null
	_save_countdown = SAVE_DEBOUNCE


func _flush_serialize() -> void:
	if _save_countdown >= 0.0:
		_save_countdown = -1.0
		_serialize_active()


func _serialize_active() -> void:
	if not _nodes_ok():
		return
	var img = _readback_a()
	if img == null:
		return
	_serialize_active_from_image(img)


func _serialize_active_from_image(img) -> void:
	var sk = _active_sketch()
	var used = img.get_used_rect()
	if used.size.x <= 0 or used.size.y <= 0:
		sk["png"] = ""
		sk["rect"] = [0, 0, 0, 0]
	else:
		var crop = img.get_rect(used)
		sk["png"] = Marshalls.raw_to_base64(crop.save_png_to_buffer())
		sk["rect"] = [
			used.position.x / _tex_scale, used.position.y / _tex_scale,
			used.size.x / _tex_scale, used.size.y / _tex_scale
		]
	_write_map_data()


# ============================================================================
# Display / export hiding
# ============================================================================

func _apply_display() -> void:
	if _root == null or not is_instance_valid(_root):
		return
	_root.visible = bool(_map_data["visible"]) and not _export_hidden
	if _display_mat != null:
		_display_mat.set_shader_param("overlay_alpha", float(_map_data["overlay_alpha"]))


func _update_export_state(delta: float) -> void:
	if _export_grace > 0.0:
		_export_grace -= delta
	var hidden = _export_grace > 0.0
	if not hidden:
		var wins = Global.Editor.get("Windows")
		if wins != null and wins.has("Export"):
			var d = wins["Export"]
			if d != null and is_instance_valid(d) and d.visible:
				hidden = true
	if hidden != _export_hidden:
		_export_hidden = hidden
		_dbg("export_hidden -> " + str(hidden))
		_apply_display()


func _try_hook_export_ok() -> void:
	if _ok_hooked:
		return
	var wins = Global.Editor.get("Windows")
	if wins == null or not wins.has("Export"):
		return
	var d = wins["Export"]
	if d == null or not is_instance_valid(d):
		return
	var ok = d.find_node("OkayButton", true, false)
	if ok == null:
		return
	if not ok.is_connected("pressed", self, "_on_export_ok"):
		ok.connect("pressed", self, "_on_export_ok")
	_ok_hooked = true


# The Change Map Size window (ChangeMapSizeWindow.cs) can add or remove cells
# on the left/top, which shifts the world origin by (left, top) cells while
# our sketch rects are stored in world coordinates of the OLD origin. Hook its
# Okay button to read the offsets and shift every sketch rect at rebuild time.
func _try_hook_mapsize_ok() -> void:
	if _mapsize_hooked:
		return
	var wins = Global.Editor.get("Windows")
	if wins == null:
		return
	var win = null
	for k in wins:
		if String(k).findn("mapsize") != -1 or String(k).findn("map_size") != -1:
			win = wins[k]
			break
	if win == null or not is_instance_valid(win):
		return
	var ok = win.find_node("OkayButton", true, false)
	_mapsize_left = win.find_node("LeftSpinBox", true, false)
	_mapsize_top = win.find_node("TopSpinBox", true, false)
	if ok == null or _mapsize_left == null or _mapsize_top == null:
		return
	if not ok.is_connected("pressed", self, "_on_mapsize_ok"):
		ok.connect("pressed", self, "_on_mapsize_ok")
	_mapsize_hooked = true
	_dbg("map size window hooked")


func _on_mapsize_ok() -> void:
	if _mapsize_left == null or not is_instance_valid(_mapsize_left) \
			or _mapsize_top == null or not is_instance_valid(_mapsize_top):
		return
	# Cells added on the left/top shift all existing world content; 1 cell =
	# 256 world px. Accumulated in case the rebuild check fires late.
	_resize_offset += Vector2(float(_mapsize_left.value), float(_mapsize_top.value)) * 256.0
	# Poll WoxelDimensions every frame for a few seconds so the rebuild
	# happens as soon as the resize lands, instead of at the 1 Hz check.
	_resize_check_frames = 180
	_dbg("map resize offset queued: " + str(_resize_offset))


func _on_export_ok() -> void:
	# The capture starts right after the click and can outlive the window;
	# keep the overlay hidden for a grace period.
	_export_grace = EXPORT_GRACE
	_update_export_state(0.0)


# ============================================================================
# Per-frame driver (listener _process; keeps running during modal windows)
# ============================================================================

func _on_process(delta: float) -> void:
	if not _dbg_process_logged:
		_dbg_process_logged = true
		_dbg("listener _process alive")
	if Global.World == null or not is_instance_valid(Global.World):
		return
	if not _nodes_ok():
		return

	_update_export_state(delta)
	_reassert_dd_cursor()

	# Fast path after a map resize: check dimensions every frame briefly.
	if _resize_check_frames > 0:
		_resize_check_frames -= 1
		if Global.World.WoxelDimensions != _last_wox:
			_resize_check_frames = 0
			_rebuild_world_nodes()

	# Startup re-apply (defeats DD's own tool-panel value restore).
	if not _reapply_queue.empty():
		_reapply_queue[0] -= delta
		if _reapply_queue[0] <= 0.0:
			_reapply_queue.pop_front()
			_apply_control_values()

	_poll_flood()
	_cv_poll()

	# Floorplan render pipeline: once the queue is idle, render the payload
	# into B for a couple of frames, then flatten it into A like a stroke.
	if _plan_pending != null and _stroke == null and _op_busy == 0 and _ops.empty() and _commit_countdown < 0:
		_pre_image = _readback_a()
		if _pre_image != null:
			_plan_render = _plan_pending["payload"]
			_plan_dbg_drop = _plan_render.get("dbg_drop", []) if _plan_render is Dictionary else []
			_plan_dbg_shift = _plan_render.get("dbg_shift", []) if _plan_render is Dictionary else []
			_plan_rect = _plan_pending["rect_tex"]
			_plan_pend_labels = _plan_pending["payload"].get("labels", [])
			_plan_was_clear = bool(_plan_pending.get("clear", false))
			if _plan_was_clear:
				_ops.append({"type": "clear"})
			_plan_pending = null
			_view_b.render_target_clear_mode = Viewport.CLEAR_MODE_ALWAYS
			_view_b.render_target_update_mode = Viewport.UPDATE_ALWAYS
			if _stroke_item != null and is_instance_valid(_stroke_item):
				_stroke_item.update()
			_plan_countdown = 2
		else:
			_plan_pending = null
	if _plan_countdown > 0:
		_plan_countdown -= 1
	elif _plan_countdown == 0:
		_plan_countdown = -1
		_view_b.render_target_update_mode = Viewport.UPDATE_DISABLED
		_ops.append({
			"type": "paint",
			"intensity": _intensity,
			"callback": "_after_plan",
			"args": [_plan_rect]
		})

	# Selection driver.
	if _sel != null:
		if String(_sel["state"]) == "liftwait" and _op_busy == 0 and _ops.empty():
			_sel_lift()
		if String(_sel["state"]) == "marquee" and not Input.is_mouse_button_pressed(BUTTON_LEFT):
			_sel_release()
		if _sel_floating() and _sel["drag"] != null and not Input.is_mouse_button_pressed(BUTTON_LEFT):
			_sel["drag"] = null
			if bool(_sel.get("move_mode", false)):
				_sel_commit_or_restore()
		if _tool_active:
			if _key_just(KEY_ESCAPE):
				_sel_cancel()
			elif _key_just(KEY_DELETE):
				_sel_delete()
			elif _key_just(KEY_ENTER) or _key_just(KEY_KP_ENTER):
				_sel_commit()

	# Stroke failsafes: Esc cancels, mouse released outside the canvas ends.
	if _stroke != null and _stroke_dragging:
		if Input.is_key_pressed(KEY_ESCAPE):
			_cancel_stroke()
		elif not Input.is_mouse_button_pressed(_stroke_button):
			_end_stroke()

	# Commit countdown -> flatten B into A.
	if _commit_countdown > 0:
		_commit_countdown -= 1
	elif _commit_countdown == 0:
		_commit_countdown = -1
		_commit_stroke()

	_run_ops()

	# Debounced serialization.
	if _save_countdown >= 0.0:
		_save_countdown -= delta
		if _save_countdown < 0.0:
			_serialize_active()

	# Throttled housekeeping.
	_throttle_a += delta
	if _throttle_a >= 0.25:
		_throttle_a = 0.0
		_position_button()
		if _cursor_item != null and is_instance_valid(_cursor_item) and _cursor_item.visible:
			_cursor_item.update()
		if _sel_item != null and is_instance_valid(_sel_item) and _sel_item.visible:
			_sel_item.update()
		_update_labels_overlay()
	_throttle_b += delta
	if _throttle_b >= 1.0:
		_throttle_b = 0.0
		_try_hook_export_ok()
		_try_hook_mapsize_ok()
		if DEBUG and _tool_active:
			var wui_p = Global.get("WorldUI")
			var cm = "?"
			if wui_p != null:
				cm = str(wui_p.get("CursorMode"))
			var cc = "content_not_found"
			if _content_ctrl != null and is_instance_valid(_content_ctrl):
				cc = str(_content_ctrl.mouse_default_cursor_shape)
			_dbg("cursor probe: CursorMode=" + cm + " content_shape=" + cc)
		var wox = Global.World.WoxelDimensions
		if wox != _last_wox:
			_rebuild_world_nodes()
