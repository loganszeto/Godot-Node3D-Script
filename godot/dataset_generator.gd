extends Node3D

# -----------------------------
# CONFIG (edit these)
# -----------------------------
@export var num_frames: int = 200
@export var output_dir_name: String = "dataset"
@export var image_size: Vector2i = Vector2i(640, 640)
@export var random_seed: int = 12345

@export var spawn_radius: float = 2.0
@export var object_y: float = 0.5

@export var camera_radius_min: float = 4.5
@export var camera_radius_max: float = 6.5
@export var camera_height_min: float = 2.5
@export var camera_height_max: float = 4.0

@export var light_yaw_min_deg: float = 0.0
@export var light_yaw_max_deg: float = 360.0
@export var light_pitch_min_deg: float = 25.0
@export var light_pitch_max_deg: float = 70.0

# -----------------------------
# INTERNALS
# -----------------------------
var _rng := RandomNumberGenerator.new()
var _frame := 0

@onready var _cam: Camera3D = $"Camera3D"
@onready var _light: DirectionalLight3D = $"DirectionalLight3D"

var _meshes: Array[MeshInstance3D] = []
var _original_materials: Dictionary = {} # MeshInstance3D -> Material? (for restore)

# mask colors: object -> Color
var _mask_colors: Dictionary = {}

func _ready() -> void:
	_rng.seed = random_seed

	# Collect meshes under this node (direct children or deeper)
	_collect_meshes(self)

	if _meshes.is_empty():
		push_error("No MeshInstance3D found under root. Add Cube/Sphere/Cylinder as MeshInstance3D nodes.")
		return

	# Assign each object a unique flat color for segmentation
	_assign_mask_colors()

	# Prepare output folders (user:// is writable and portable)
	_ensure_dir("user://%s" % output_dir_name)
	_ensure_dir("user://%s/rgb" % output_dir_name)
	_ensure_dir("user://%s/mask" % output_dir_name)
	_ensure_dir("user://%s/meta" % output_dir_name)

	# Set viewport size (controls saved image dimensions)
	get_viewport().size = image_size

	# Run generation one frame at a time (so the renderer has time to update)
	set_process(true)

func _process(_delta: float) -> void:
	if _frame >= num_frames:
		print("Done. Generated %d frames." % num_frames)
		set_process(false)
		return

	_randomize_scene()

	# IMPORTANT: wait one frame so transforms apply before capture
	await get_tree().process_frame

	# 1) RGB capture
	var rgb_path := "user://%s/rgb/frame_%06d.png" % [output_dir_name, _frame]
	_save_viewport_png(rgb_path)

	# 2) MASK capture (temporary material override)
	_apply_segmentation_materials()
	await get_tree().process_frame

	var mask_path := "user://%s/mask/frame_%06d.png" % [output_dir_name, _frame]
	_save_viewport_png(mask_path)

	_restore_original_materials()

	# 3) Metadata JSON
	var meta_path := "user://%s/meta/frame_%06d.json" % [output_dir_name, _frame]
	_save_metadata_json(meta_path, rgb_path, mask_path)

	_frame += 1

# -----------------------------
# SCENE RANDOMIZATION
# -----------------------------
func _randomize_scene() -> void:
	# Randomize object poses (skip Ground if present by name)
	for m in _meshes:
		if m.name == "Ground":
			continue

		var x = _rng.randf_range(-spawn_radius, spawn_radius)
		var z = _rng.randf_range(-spawn_radius, spawn_radius)
		m.position = Vector3(x, object_y, z)
		m.rotation = Vector3(
			0.0,
			_rng.randf_range(0.0, TAU),
			0.0
		)

	# Randomize camera on a ring looking at origin
	var r = _rng.randf_range(camera_radius_min, camera_radius_max)
	var theta = _rng.randf_range(0.0, TAU)
	var cam_x = r * cos(theta)
	var cam_z = r * sin(theta)
	var cam_y = _rng.randf_range(camera_height_min, camera_height_max)
	_cam.position = Vector3(cam_x, cam_y, cam_z)
	_cam.look_at(Vector3(0, 0.5, 0), Vector3.UP)

	# Randomize directional light orientation
	var yaw = deg_to_rad(_rng.randf_range(light_yaw_min_deg, light_yaw_max_deg))
	var pitch = deg_to_rad(_rng.randf_range(light_pitch_min_deg, light_pitch_max_deg))
	_light.rotation = Vector3(pitch, yaw, 0.0)

# -----------------------------
# DATA CAPTURE
# -----------------------------
func _save_viewport_png(path: String) -> void:
	var img: Image = get_viewport().get_texture().get_image()
	img.save_png(path)

func _save_metadata_json(meta_path: String, rgb_path: String, mask_path: String) -> void:
	var objects := []
	for m in _meshes:
		if m.name == "Ground":
			continue

		objects.append({
			"name": m.name,
			"position": [m.position.x, m.position.y, m.position.z],
			"rotation_y_rad": m.rotation.y,
			"mask_color_rgb": _mask_colors[m].to_html(false) # "RRGGBB"
		})

	var cam_basis := _cam.global_transform.basis
	var cam_origin := _cam.global_transform.origin

	var meta := {
		"frame": _frame,
		"seed": random_seed,
		"rgb": rgb_path,
		"mask": mask_path,
		"camera": {
			"position": [cam_origin.x, cam_origin.y, cam_origin.z],
			# basis as rows (useful for ML)
			"basis_row0": [cam_basis.x.x, cam_basis.x.y, cam_basis.x.z],
			"basis_row1": [cam_basis.y.x, cam_basis.y.y, cam_basis.y.z],
			"basis_row2": [cam_basis.z.x, cam_basis.z.y, cam_basis.z.z]
		},
		"light": {
			"rotation_rad": [_light.rotation.x, _light.rotation.y, _light.rotation.z]
		},
		"objects": objects
	}

	var f := FileAccess.open(meta_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta, "\t"))
	f.close()

# -----------------------------
# SEGMENTATION OVERRIDES
# -----------------------------
func _assign_mask_colors() -> void:
	_mask_colors.clear()

	# Hard-coded distinct colors (no black/white)
	var palette := [
		Color(1, 0, 0),    # red
		Color(0, 1, 0),    # green
		Color(0, 0, 1),    # blue
		Color(1, 1, 0),    # yellow
		Color(1, 0, 1),    # magenta
		Color(0, 1, 1)     # cyan
	]

	# Only assign colors to non-ground meshes
	var idx := 0
	for m in _meshes:
		if m.name == "Ground":
			continue
		_mask_colors[m] = palette[idx % palette.size()]
		idx += 1

func _apply_segmentation_materials() -> void:
	_original_materials.clear()

	for m in _meshes:
		if m.name == "Ground":
			continue

		_original_materials[m] = m.material_override

		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = _mask_colors[m]
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

		m.material_override = mat

func _restore_original_materials() -> void:
	for m in _original_materials.keys():
		m.material_override = _original_materials[m]

# -----------------------------
# HELPERS
# -----------------------------
func _collect_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_meshes.append(child)
		_collect_meshes(child)

func _ensure_dir(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		DirAccess.make_dir_recursive_absolute(path)
