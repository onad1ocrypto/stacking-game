extends Node3D

# ============================================
# STACKING GAME 3D - Godot 4.7
# All elements (blocks, camera, light, UI) are built via code.
# Setup: create a new scene with root Node3D, attach this script, set as Main Scene.
# ============================================

# ===== CONFIG =====
@export var base_size := Vector3(4, 1, 4)
@export var block_height := 1.0
@export var start_speed := 3.0
@export var speed_increment := 0.15
@export var camera_offset := Vector3(9, 9, 9)
@export var move_range := 5.0

# ===== STATE =====
var blocks: Array = []
var current_block: Node3D = null
var move_axis := "x"
var move_dir := 1
var move_speed := 0.0
var score := 0
var high_score := 0
var game_over := false
var ignore_input_until_ms := 0
var camera: Camera3D
var world_env: WorldEnvironment
var sky_time := 0.0

# UI refs
var score_label: Label
var best_label: Label
var new_best_label: Label
var new_best_shown := false
var status_panel: PanelContainer
var status_label: Label
var game_over_layer: CanvasLayer
var game_over_panel: PanelContainer
var game_over_score_label: Label
var title_label: Label
var title_base_pos := Vector2.ZERO
var title_time := 0.0

# Online leaderboard refs
var http_submit: HTTPRequest
var http_leaderboard: HTTPRequest
var name_input: LineEdit
var submit_button: Button
var leaderboard_button: Button
var submit_status_label: Label
var score_submitted := false
var leaderboard_layer: CanvasLayer
var leaderboard_panel: PanelContainer
var leaderboard_list_vbox: VBoxContainer
var leaderboard_status_label: Label

# Audio
var bgm_player: AudioStreamPlayer
var sfx_place: AudioStreamPlayer
var sfx_gameover: AudioStreamPlayer
var music_muted := false

const SAVE_PATH := "user://highscore.save"

# ===== SUPABASE CONFIG =====
const SUPABASE_URL := "https://hxaiskiqgkclxbrnfngg.supabase.co"
const SUPABASE_KEY := "sb_publishable_lpYCt-uU7Na6oyWHOxHOOA_cFB-SGJc"

var colors := [
	Color(0.95, 0.3, 0.3),
	Color(0.95, 0.6, 0.2),
	Color(0.95, 0.9, 0.2),
	Color(0.4, 0.85, 0.4),
	Color(0.3, 0.6, 0.95),
	Color(0.6, 0.3, 0.9),
]

func _ready():
	move_speed = start_speed
	_load_high_score()
	_setup_world()
	_setup_particles()
	_setup_network()
	_setup_audio()
	_setup_ui()
	_spawn_base()
	_spawn_next_block()
	ignore_input_until_ms = Time.get_ticks_msec() + 500

# ---------- WORLD SETUP (sky, fog, floor, lighting) ----------
func _setup_world():
	var env = Environment.new()

	# Gradient sky instead of flat color
	env.background_mode = Environment.BG_SKY
	var sky_material = ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color(0.05, 0.05, 0.13)
	sky_material.sky_horizon_color = Color(0.35, 0.22, 0.42)
	sky_material.sky_curve = 0.15
	sky_material.ground_bottom_color = Color(0.04, 0.04, 0.07)
	sky_material.ground_horizon_color = Color(0.22, 0.15, 0.28)
	sky_material.ground_curve = 0.15
	var sky = Sky.new()
	sky.sky_material = sky_material
	env.sky = sky

	# Ambient light pulled from the sky gradient, so shadows aren't pure black
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 1.1

	# Soft fog for depth
	env.fog_enabled = true
	env.fog_light_color = Color(0.3, 0.22, 0.38)
	env.fog_light_energy = 1.0
	env.fog_density = 0.008

	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.08

	world_env = WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	# Key light
	var light = DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.5
	light.light_color = Color(1.0, 0.97, 0.9)
	light.shadow_enabled = true
	add_child(light)

	# Fill light from the opposite side
	var fill_light = DirectionalLight3D.new()
	fill_light.rotation_degrees = Vector3(-20, 140, 0)
	fill_light.light_energy = 0.45
	fill_light.light_color = Color(0.55, 0.65, 1.0)
	add_child(fill_light)

	# Ground plane so there's a visual anchor instead of empty void
	var floor_mesh = MeshInstance3D.new()
	var floor_box = BoxMesh.new()
	floor_box.size = Vector3(30, 0.2, 30)
	floor_mesh.mesh = floor_box
	floor_mesh.position = Vector3(0, -0.6, 0)
	var floor_mat = StandardMaterial3D.new()
	floor_mat.albedo_color = Color(0.14, 0.14, 0.19)
	floor_mat.roughness = 0.85
	floor_mesh.material_override = floor_mat
	add_child(floor_mesh)

	camera = Camera3D.new()
	camera.position = camera_offset
	camera.fov = 55
	add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.UP)

# ---------- AMBIENT FIRE PARTICLES ----------
func _setup_particles():
	var particles = GPUParticles3D.new()
	particles.amount = 45
	particles.lifetime = 5.0
	particles.preprocess = 5.0
	particles.emitting = true

	# Covers a tall vertical range so embers are visible no matter how high the tower gets
	particles.position = Vector3(0, 18, 0)

	var quad = QuadMesh.new()
	quad.size = Vector2(0.18, 0.18)
	particles.draw_pass_1 = quad

	var mat = StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.albedo_color = Color(1.0, 0.55, 0.15, 0.85)
	quad.material = mat

	var process_mat = ParticleProcessMaterial.new()
	process_mat.direction = Vector3(0, 1, 0)
	process_mat.spread = 20.0
	process_mat.gravity = Vector3(0, 0.4, 0)
	process_mat.initial_velocity_min = 0.5
	process_mat.initial_velocity_max = 1.3
	process_mat.scale_min = 0.4
	process_mat.scale_max = 1.5
	process_mat.color = Color(1.0, 0.5, 0.1)
	process_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	process_mat.emission_box_extents = Vector3(11, 22, 11)
	# fade in/out over lifetime using a color ramp-like alpha curve
	var alpha_curve = Curve.new()
	alpha_curve.add_point(Vector2(0.0, 0.0))
	alpha_curve.add_point(Vector2(0.15, 1.0))
	alpha_curve.add_point(Vector2(0.8, 0.6))
	alpha_curve.add_point(Vector2(1.0, 0.0))
	var alpha_tex = CurveTexture.new()
	alpha_tex.curve = alpha_curve
	process_mat.alpha_curve = alpha_tex
	particles.process_material = process_mat

	add_child(particles)

# ---------- UI SETUP ----------
func _setup_ui():
	var canvas = CanvasLayer.new()
	add_child(canvas)

	# --- Score panel (top-left, rounded, semi-transparent) ---
	var score_panel = PanelContainer.new()
	var score_style = StyleBoxFlat.new()
	score_style.bg_color = Color(0, 0, 0, 0.4)
	score_style.corner_radius_top_left = 14
	score_style.corner_radius_top_right = 14
	score_style.corner_radius_bottom_left = 14
	score_style.corner_radius_bottom_right = 14
	score_style.content_margin_left = 24
	score_style.content_margin_right = 24
	score_style.content_margin_top = 12
	score_style.content_margin_bottom = 12
	score_panel.add_theme_stylebox_override("panel", score_style)
	score_panel.position = Vector2(24, 24)
	canvas.add_child(score_panel)

	var score_vbox = VBoxContainer.new()
	score_vbox.add_theme_constant_override("separation", 2)
	score_panel.add_child(score_vbox)

	score_label = Label.new()
	score_label.text = "Score: 0"
	score_label.add_theme_font_size_override("font_size", 34)
	score_label.add_theme_color_override("font_color", Color(1, 1, 1))
	score_vbox.add_child(score_label)

	best_label = Label.new()
	best_label.text = "Best: %d" % high_score
	best_label.add_theme_font_size_override("font_size", 16)
	best_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	score_vbox.add_child(best_label)

	new_best_label = Label.new()
	new_best_label.text = "NEW BEST!"
	new_best_label.add_theme_font_size_override("font_size", 14)
	new_best_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	new_best_label.visible = false
	score_vbox.add_child(new_best_label)

	# --- Status pill (bottom-center) ---
	status_panel = PanelContainer.new()
	var status_style = StyleBoxFlat.new()
	status_style.bg_color = Color(1, 1, 1, 0.1)
	status_style.corner_radius_top_left = 20
	status_style.corner_radius_top_right = 20
	status_style.corner_radius_bottom_left = 20
	status_style.corner_radius_bottom_right = 20
	status_style.content_margin_left = 22
	status_style.content_margin_right = 22
	status_style.content_margin_top = 10
	status_style.content_margin_bottom = 10
	status_panel.add_theme_stylebox_override("panel", status_style)
	canvas.add_child(status_panel)

	status_label = Label.new()
	status_label.text = "Press SPACE or click to start stacking   |   M: mute music"
	status_label.add_theme_font_size_override("font_size", 16)
	status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	status_panel.add_child(status_label)

	call_deferred("_position_status_panel")

	# --- Floating animated title (background ambiance) ---
	title_label = Label.new()
	title_label.text = "STACKING GAME"
	title_label.add_theme_font_size_override("font_size", 46)
	title_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
	title_label.add_theme_color_override("font_outline_color", Color(1, 0.5, 0.15, 0.6))
	title_label.add_theme_constant_override("outline_size", 10)
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	canvas.add_child(title_label)
	canvas.move_child(title_label, 0)  # draw behind the score/status panels
	call_deferred("_position_title_label")

	# --- Game over overlay (hidden by default) ---
	game_over_layer = CanvasLayer.new()
	game_over_layer.visible = false
	add_child(game_over_layer)

	var dim = ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	game_over_layer.add_child(dim)

	game_over_panel = PanelContainer.new()
	var go_style = StyleBoxFlat.new()
	go_style.bg_color = Color(0.12, 0.12, 0.17, 0.96)
	go_style.corner_radius_top_left = 20
	go_style.corner_radius_top_right = 20
	go_style.corner_radius_bottom_left = 20
	go_style.corner_radius_bottom_right = 20
	go_style.content_margin_left = 44
	go_style.content_margin_right = 44
	go_style.content_margin_top = 32
	go_style.content_margin_bottom = 32
	game_over_panel.add_theme_stylebox_override("panel", go_style)
	game_over_layer.add_child(game_over_panel)

	var go_vbox = VBoxContainer.new()
	go_vbox.add_theme_constant_override("separation", 12)
	go_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	game_over_panel.add_child(go_vbox)

	var go_title = Label.new()
	go_title.text = "GAME OVER"
	go_title.add_theme_font_size_override("font_size", 40)
	go_title.add_theme_color_override("font_color", Color(1, 0.45, 0.4))
	go_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	go_vbox.add_child(go_title)

	game_over_score_label = Label.new()
	game_over_score_label.text = "Final Score: 0"
	game_over_score_label.add_theme_font_size_override("font_size", 22)
	game_over_score_label.add_theme_color_override("font_color", Color(1, 1, 1))
	game_over_score_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	go_vbox.add_child(game_over_score_label)

	var go_hint = Label.new()
	go_hint.text = "Press R to play again"
	go_hint.add_theme_font_size_override("font_size", 16)
	go_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	go_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	go_vbox.add_child(go_hint)

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	go_vbox.add_child(spacer)

	name_input = LineEdit.new()
	name_input.placeholder_text = "Enter your name"
	name_input.text = "Player"
	name_input.custom_minimum_size = Vector2(220, 0)
	name_input.max_length = 20
	go_vbox.add_child(name_input)

	var button_row = HBoxContainer.new()
	button_row.alignment = BoxContainer.ALIGNMENT_CENTER
	button_row.add_theme_constant_override("separation", 10)
	go_vbox.add_child(button_row)

	submit_button = Button.new()
	submit_button.text = "Submit Score"
	submit_button.pressed.connect(_submit_score)
	button_row.add_child(submit_button)

	leaderboard_button = Button.new()
	leaderboard_button.text = "Leaderboard"
	leaderboard_button.pressed.connect(_show_leaderboard)
	button_row.add_child(leaderboard_button)

	submit_status_label = Label.new()
	submit_status_label.text = ""
	submit_status_label.add_theme_font_size_override("font_size", 14)
	submit_status_label.add_theme_color_override("font_color", Color(0.6, 1, 0.6))
	submit_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	go_vbox.add_child(submit_status_label)

	# --- Leaderboard overlay (separate layer, hidden by default) ---
	leaderboard_layer = CanvasLayer.new()
	leaderboard_layer.visible = false
	add_child(leaderboard_layer)

	var lb_dim = ColorRect.new()
	lb_dim.color = Color(0, 0, 0, 0.65)
	lb_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	leaderboard_layer.add_child(lb_dim)

	leaderboard_panel = PanelContainer.new()
	var lb_style = StyleBoxFlat.new()
	lb_style.bg_color = Color(0.12, 0.12, 0.17, 0.97)
	lb_style.corner_radius_top_left = 20
	lb_style.corner_radius_top_right = 20
	lb_style.corner_radius_bottom_left = 20
	lb_style.corner_radius_bottom_right = 20
	lb_style.content_margin_left = 40
	lb_style.content_margin_right = 40
	lb_style.content_margin_top = 28
	lb_style.content_margin_bottom = 28
	leaderboard_panel.add_theme_stylebox_override("panel", lb_style)
	leaderboard_panel.custom_minimum_size = Vector2(320, 0)
	leaderboard_layer.add_child(leaderboard_panel)

	var lb_outer_vbox = VBoxContainer.new()
	lb_outer_vbox.add_theme_constant_override("separation", 14)
	leaderboard_panel.add_child(lb_outer_vbox)

	var lb_title = Label.new()
	lb_title.text = "TOP 10 WORLDWIDE"
	lb_title.add_theme_font_size_override("font_size", 26)
	lb_title.add_theme_color_override("font_color", Color(1, 0.8, 0.3))
	lb_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lb_outer_vbox.add_child(lb_title)

	leaderboard_status_label = Label.new()
	leaderboard_status_label.text = "Loading..."
	leaderboard_status_label.add_theme_font_size_override("font_size", 14)
	leaderboard_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	leaderboard_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	leaderboard_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	leaderboard_status_label.custom_minimum_size = Vector2(280, 0)
	lb_outer_vbox.add_child(leaderboard_status_label)

	leaderboard_list_vbox = VBoxContainer.new()
	leaderboard_list_vbox.add_theme_constant_override("separation", 6)
	lb_outer_vbox.add_child(leaderboard_list_vbox)

	var lb_close = Button.new()
	lb_close.text = "Close"
	lb_close.pressed.connect(_hide_leaderboard)
	lb_outer_vbox.add_child(lb_close)

func _position_status_panel():
	var vp_size = get_viewport().get_visible_rect().size
	status_panel.position = Vector2(
		vp_size.x / 2.0 - status_panel.size.x / 2.0,
		vp_size.y - status_panel.size.y - 40
	)

func _position_title_label():
	var vp_size = get_viewport().get_visible_rect().size
	title_base_pos = Vector2(
		vp_size.x / 2.0 - title_label.size.x / 2.0,
		70
	)
	title_label.position = title_base_pos

func _position_game_over_panel():
	var vp_size = get_viewport().get_visible_rect().size
	game_over_panel.position = Vector2(
		vp_size.x / 2.0 - game_over_panel.size.x / 2.0,
		vp_size.y / 2.0 - game_over_panel.size.y / 2.0
	)

func _position_leaderboard_panel():
	var vp_size = get_viewport().get_visible_rect().size
	leaderboard_panel.position = Vector2(
		vp_size.x / 2.0 - leaderboard_panel.size.x / 2.0,
		vp_size.y / 2.0 - leaderboard_panel.size.y / 2.0
	)

# ---------- BASE BLOCK (static) ----------
func _spawn_base():
	var base = _make_static_block(base_size, Vector3.ZERO, colors[0])
	blocks.append({"node": base, "size": base_size, "pos": Vector3.ZERO})

# ---------- SPAWN MOVING BLOCK ----------
func _spawn_next_block():
	if game_over:
		return

	var last = blocks[blocks.size() - 1]
	var size: Vector3 = last["size"]
	var y = blocks.size() * block_height

	move_axis = "x" if blocks.size() % 2 == 1 else "z"
	move_dir = 1

	var start_pos: Vector3
	if move_axis == "x":
		start_pos = Vector3(-move_range, y, last["pos"].z)
	else:
		start_pos = Vector3(last["pos"].x, y, -move_range)

	var color = colors[blocks.size() % colors.size()]
	current_block = _make_visual_block(size, start_pos, color)
	current_block.set_meta("size", size)

	status_label.text = "Press SPACE / Click to drop the block"
	call_deferred("_position_status_panel")

# ---------- BLOCK CREATION HELPERS ----------
func _make_static_block(size: Vector3, pos: Vector3, color: Color) -> StaticBody3D:
	var body = StaticBody3D.new()
	body.position = pos

	var mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.35
	mat.metallic = 0.05
	mesh_instance.material_override = mat
	body.add_child(mesh_instance)

	var collision = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)

	add_child(body)
	return body

func _make_visual_block(size: Vector3, pos: Vector3, color: Color) -> Node3D:
	var holder = Node3D.new()
	holder.position = pos

	var mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = size
	mesh_instance.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.35
	mat.metallic = 0.05
	mesh_instance.material_override = mat
	holder.add_child(mesh_instance)

	add_child(holder)
	return holder

# ---------- MOVEMENT & CAMERA ----------
func _process(delta):
	# Slowly rotate the sky so the background never feels static
	sky_time += delta
	if world_env and world_env.environment:
		world_env.environment.sky_rotation = Vector3(0, sky_time * 0.03, 0)

	# Floating, gently glowing title text
	title_time += delta
	if title_label:
		title_label.position.y = title_base_pos.y + sin(title_time * 1.1) * 8.0
		var pulse = 0.75 + 0.25 * sin(title_time * 1.8)
		title_label.modulate = Color(1, 1, 1, pulse)

	if game_over or current_block == null:
		return

	if move_axis == "x":
		current_block.position.x += move_dir * move_speed * delta
		if current_block.position.x > move_range:
			current_block.position.x = move_range
			move_dir = -1
		elif current_block.position.x < -move_range:
			current_block.position.x = -move_range
			move_dir = 1
	else:
		current_block.position.z += move_dir * move_speed * delta
		if current_block.position.z > move_range:
			current_block.position.z = move_range
			move_dir = -1
		elif current_block.position.z < -move_range:
			current_block.position.z = -move_range
			move_dir = 1

	var target_y = camera_offset.y + (blocks.size() - 1) * block_height
	camera.position.y = lerp(camera.position.y, target_y, delta * 3.0)
	camera.look_at(Vector3(0, camera.position.y - camera_offset.y, 0), Vector3.UP)

# ---------- INPUT ----------
func _input(event):
	# While typing in the name field, don't let game shortcuts (R, Space, click) fire.
	if name_input and name_input.has_focus():
		return

	# Ignore input for a brief moment after the game starts/restarts — the
	# browser's initial click to focus the canvas can otherwise be read as
	# a genuine "drop the block" action.
	if Time.get_ticks_msec() < ignore_input_until_ms:
		return

	if event is InputEventKey and event.pressed and event.keycode == KEY_M:
		_toggle_music_mute()

	if game_over:
		if event is InputEventKey and event.pressed and event.keycode == KEY_R:
			_restart()
		return

	var pressed = (event is InputEventKey and event.pressed and event.keycode == KEY_SPACE) \
		or (event is InputEventMouseButton and event.pressed)
	if pressed and current_block != null:
		_place_block()

# ---------- PLACE & CUT ----------
func _place_block():
	var last = blocks[blocks.size() - 1]
	var last_size: Vector3 = last["size"]
	var last_pos: Vector3 = last["pos"]
	var cur_size: Vector3 = current_block.get_meta("size")
	var cur_pos: Vector3 = current_block.position

	var axis_idx = 0 if move_axis == "x" else 2
	var last_min = last_pos[axis_idx] - last_size[axis_idx] / 2.0
	var last_max = last_pos[axis_idx] + last_size[axis_idx] / 2.0
	var cur_min = cur_pos[axis_idx] - cur_size[axis_idx] / 2.0
	var cur_max = cur_pos[axis_idx] + cur_size[axis_idx] / 2.0

	var overlap_min = max(last_min, cur_min)
	var overlap_max = min(last_max, cur_max)
	var overlap = overlap_max - overlap_min

	if overlap <= 0.05:
		_end_game()
		return

	var new_size = cur_size
	new_size[axis_idx] = overlap
	var new_pos = cur_pos
	new_pos[axis_idx] = overlap_min + overlap / 2.0

	var leftover = cur_size[axis_idx] - overlap
	if leftover > 0.05:
		_spawn_falling_piece(cur_size, cur_pos, axis_idx, overlap_min, overlap_max)

	var color: Color = current_block.get_child(0).material_override.albedo_color
	current_block.queue_free()

	var placed = _make_static_block(new_size, new_pos, color)
	blocks.append({"node": placed, "size": new_size, "pos": new_pos})

	score += 1
	if score > high_score:
		high_score = score
		_save_high_score()
		new_best_label.visible = true
		new_best_shown = true
	score_label.text = "Score: %d" % score
	best_label.text = "Best: %d" % high_score
	move_speed += speed_increment
	_play_sfx(sfx_place)

	current_block = null
	_spawn_next_block()

func _spawn_falling_piece(cur_size: Vector3, cur_pos: Vector3, axis_idx: int, overlap_min: float, overlap_max: float):
	var piece_size = cur_size
	var piece_pos = cur_pos

	if cur_pos[axis_idx] - cur_size[axis_idx] / 2.0 < overlap_min:
		var w = overlap_min - (cur_pos[axis_idx] - cur_size[axis_idx] / 2.0)
		piece_size[axis_idx] = w
		piece_pos[axis_idx] = overlap_min - w / 2.0
	else:
		var w = (cur_pos[axis_idx] + cur_size[axis_idx] / 2.0) - overlap_max
		piece_size[axis_idx] = w
		piece_pos[axis_idx] = overlap_max + w / 2.0

	var body = RigidBody3D.new()
	body.position = piece_pos

	var mesh_instance = MeshInstance3D.new()
	var box = BoxMesh.new()
	box.size = piece_size
	mesh_instance.mesh = box
	var mat = StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.1, 0.1)
	mesh_instance.material_override = mat
	body.add_child(mesh_instance)

	var collision = CollisionShape3D.new()
	var shape = BoxShape3D.new()
	shape.size = piece_size
	collision.shape = shape
	body.add_child(collision)

	add_child(body)

	var timer = Timer.new()
	timer.wait_time = 3.0
	timer.one_shot = true
	body.add_child(timer)
	timer.timeout.connect(func(): body.queue_free())
	timer.start()

# ---------- GAME OVER & RESTART ----------
func _end_game():
	game_over = true
	if current_block:
		current_block.queue_free()
		current_block = null
	game_over_score_label.text = "Final Score: %d   (Best: %d)" % [score, high_score]
	game_over_layer.visible = true
	_play_sfx(sfx_gameover, false)
	call_deferred("_position_game_over_panel")

func _restart():
	for b in blocks:
		b["node"].queue_free()
	blocks.clear()
	score = 0
	move_speed = start_speed
	game_over = false
	game_over_layer.visible = false
	new_best_label.visible = false
	new_best_shown = false
	score_label.text = "Score: 0"
	best_label.text = "Best: %d" % high_score
	score_submitted = false
	submit_button.disabled = false
	submit_status_label.text = ""
	ignore_input_until_ms = Time.get_ticks_msec() + 300
	_spawn_base()
	_spawn_next_block()

# ---------- LOCAL HIGH SCORE (saved on this PC only) ----------
func _load_high_score():
	if FileAccess.file_exists(SAVE_PATH):
		var f = FileAccess.open(SAVE_PATH, FileAccess.READ)
		high_score = f.get_32()
		f.close()

func _save_high_score():
	var f = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	f.store_32(high_score)
	f.close()

# ---------- AUDIO (music + SFX) ----------
# Drop your own files into res://audio/ using these exact names, or change
# the paths below. If a file is missing, that sound is simply skipped —
# nothing will crash.
func _setup_audio():
	bgm_player = AudioStreamPlayer.new()
	bgm_player.volume_db = -8.0
	add_child(bgm_player)
	var bgm_path = "res://audio/bgm.ogg"
	if ResourceLoader.exists(bgm_path):
		bgm_player.stream = load(bgm_path)
		bgm_player.play()
		# Loop reliably no matter the audio format
		bgm_player.finished.connect(func(): bgm_player.play())
	else:
		print("No background music found at ", bgm_path, " — skipping.")

	sfx_place = AudioStreamPlayer.new()
	add_child(sfx_place)
	_load_sfx(sfx_place, "res://audio/place.ogg")

	sfx_gameover = AudioStreamPlayer.new()
	add_child(sfx_gameover)
	_load_sfx(sfx_gameover, "res://audio/gameover.ogg")

func _load_sfx(player: AudioStreamPlayer, path: String):
	if ResourceLoader.exists(path):
		player.stream = load(path)
	else:
		print("No SFX found at ", path, " — skipping.")

func _play_sfx(player: AudioStreamPlayer, pitch_variation := true):
	if player.stream == null:
		return
	if pitch_variation:
		player.pitch_scale = randf_range(0.95, 1.15)
	player.play()

func _toggle_music_mute():
	music_muted = !music_muted
	bgm_player.volume_db = -80.0 if music_muted else -8.0

# ---------- ONLINE LEADERBOARD (Supabase) ----------
func _setup_network():
	http_submit = HTTPRequest.new()
	add_child(http_submit)
	http_submit.request_completed.connect(_on_submit_completed)

	http_leaderboard = HTTPRequest.new()
	add_child(http_leaderboard)
	http_leaderboard.request_completed.connect(_on_leaderboard_completed)

func _submit_score():
	if score_submitted:
		return

	var player_name = name_input.text.strip_edges()
	if player_name == "":
		player_name = "Player"

	submit_button.disabled = true
	submit_status_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	submit_status_label.text = "Submitting..."

	var url = SUPABASE_URL + "/rest/v1/scores"
	var headers = [
		"apikey: " + SUPABASE_KEY,
		"Authorization: Bearer " + SUPABASE_KEY,
		"Content-Type: application/json",
		"Prefer: return=minimal"
	]
	var body = JSON.stringify({"player_name": player_name, "score": score})
	var err = http_submit.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		submit_status_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		submit_status_label.text = "Network error"
		submit_button.disabled = false

func _on_submit_completed(_result, response_code, _headers, _body):
	if response_code == 201 or response_code == 200:
		score_submitted = true
		submit_status_label.add_theme_color_override("font_color", Color(0.6, 1, 0.6))
		submit_status_label.text = "Score submitted!"
	else:
		submit_status_label.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		submit_status_label.text = "Failed (code %d)" % response_code
		submit_button.disabled = false

func _show_leaderboard():
	leaderboard_layer.visible = true
	leaderboard_status_label.text = "Loading..."
	leaderboard_status_label.visible = true
	for child in leaderboard_list_vbox.get_children():
		child.queue_free()
	call_deferred("_position_leaderboard_panel")
	_fetch_leaderboard()

func _hide_leaderboard():
	leaderboard_layer.visible = false

func _fetch_leaderboard():
	if OS.has_feature("web"):
		_fetch_leaderboard_web()
	else:
		_fetch_leaderboard_native()

# ---- Native (desktop) path: use Godot's built-in HTTPRequest ----
func _fetch_leaderboard_native():
	var url = SUPABASE_URL + "/rest/v1/scores?select=player_name,score&order=score.desc&limit=10"
	var headers = [
		"apikey: " + SUPABASE_KEY,
		"Authorization: Bearer " + SUPABASE_KEY
	]
	var err = http_leaderboard.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		leaderboard_status_label.text = "Network error"

func _on_leaderboard_completed(result, response_code, _headers, body):
	var raw_text = body.get_string_from_utf8()
	print("[Leaderboard] request result=", result, " http_code=", response_code, " body=", raw_text)

	if response_code == 0:
		leaderboard_status_label.text = "No response — CORS or network blocked (see console)"
		return
	if response_code != 200:
		leaderboard_status_label.text = "Server error %d: %s" % [response_code, raw_text.left(120)]
		return

	_render_leaderboard_from_json(raw_text)

# ---- Web export path: HTTPRequest's body-reading is unreliable on Web,
# so use the browser's native fetch() via JavaScriptBridge instead ----
var _js_leaderboard_callback: JavaScriptObject

func _fetch_leaderboard_web():
	var url = SUPABASE_URL + "/rest/v1/scores?select=player_name,score&order=score.desc&limit=10"
	_js_leaderboard_callback = JavaScriptBridge.create_callback(_on_js_leaderboard_result)
	JavaScriptBridge.get_interface("window").godotLeaderboardCallback = _js_leaderboard_callback

	var js_code = """
	(function() {
		fetch("%s", {
			method: "GET",
			headers: {
				"apikey": "%s",
				"Authorization": "Bearer %s"
			}
		})
		.then(function(r) { return r.text(); })
		.then(function(t) { window.godotLeaderboardCallback(t); })
		.catch(function(e) { window.godotLeaderboardCallback("__FETCH_ERROR__:" + e); });
	})();
	""" % [url, SUPABASE_KEY, SUPABASE_KEY]

	JavaScriptBridge.eval(js_code, true)

func _on_js_leaderboard_result(args):
	var raw_text = str(args[0])
	print("[Leaderboard-web] raw=", raw_text)

	if raw_text.begins_with("__FETCH_ERROR__"):
		leaderboard_status_label.text = "Fetch error: " + raw_text
		return

	_render_leaderboard_from_json(raw_text)

# ---- Shared: parse JSON text and populate the on-screen list ----
func _render_leaderboard_from_json(raw_text: String):
	var json = JSON.new()
	var parse_err = json.parse(raw_text)
	if parse_err != OK:
		leaderboard_status_label.text = "Parse error: %s | raw: %s" % [json.get_error_message(), raw_text.left(80)]
		return

	var entries: Array = json.data
	if entries.is_empty():
		leaderboard_status_label.text = "No scores yet — be the first!"
		call_deferred("_position_leaderboard_panel")
		return

	leaderboard_status_label.visible = false
	var rank = 1
	for entry in entries:
		var row = Label.new()
		var p_name = str(entry.get("player_name", "???"))
		var p_score = str(int(entry.get("score", 0)))
		row.text = "%d. %s — %s" % [rank, p_name, p_score]
		row.add_theme_font_size_override("font_size", 16)
		row.add_theme_color_override("font_color", Color(1, 1, 1, 0.9))
		if rank == 1:
			row.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
		leaderboard_list_vbox.add_child(row)
		rank += 1

	call_deferred("_position_leaderboard_panel")
