extends Node3D

## The course's gates in the world: a tall beam of light and a ring on the road
## at the next gate, visible over the rooftops, and a fainter one at the gate
## after it so the player can read where the course turns. The finish is white.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")

const BEAM_HEIGHT := 90.0
const BEAM_RADIUS := 1.6
const RING_RADIUS := 9.0

var _gates := PackedVector3Array()
var _next: MarkerSet
var _after: MarkerSet


## One gate's beam + ring, with its own material so the two can differ.
class MarkerSet:
	var root := Node3D.new()
	var material := StandardMaterial3D.new()

	func _init(parent: Node3D, beam_mesh: Mesh, ring_mesh: Mesh) -> void:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.disable_receive_shadows = true
		for mesh: Mesh in [beam_mesh, ring_mesh]:
			var instance := MeshInstance3D.new()
			instance.mesh = mesh
			instance.material_override = material
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if mesh == beam_mesh:
				instance.position.y = BEAM_HEIGHT * 0.5
			else:
				instance.position.y = 0.15
			root.add_child(instance)
		parent.add_child(root)

	func show_at(pos: Vector3, color: Color) -> void:
		root.visible = true
		root.global_position = pos
		material.albedo_color = color


func _ready() -> void:
	var beam := CylinderMesh.new()
	beam.top_radius = BEAM_RADIUS
	beam.bottom_radius = BEAM_RADIUS
	beam.height = BEAM_HEIGHT
	beam.cap_top = false
	beam.cap_bottom = false
	var ring := TorusMesh.new()
	ring.inner_radius = RING_RADIUS - 0.5
	ring.outer_radius = RING_RADIUS
	_next = MarkerSet.new(self, beam, ring)
	_after = MarkerSet.new(self, beam, ring)
	_refresh(0)


func set_gates(gates: PackedVector3Array) -> void:
	_gates = gates
	_refresh(0)


## Show the gate at `index` as the target and the one after it faintly.
func set_next(index: int) -> void:
	_refresh(index)


func clear() -> void:
	_gates = PackedVector3Array()
	_refresh(0)


func is_showing_next() -> bool:
	return _next.root.visible


func _refresh(index: int) -> void:
	if _next == null:
		return
	_next.root.visible = false
	_after.root.visible = false
	var last := _gates.size() - 1
	if index <= last:
		_next.show_at(_gates[index], _color(index == last, 0.6))
	if index + 1 <= last:
		_after.show_at(_gates[index + 1], _color(index + 1 == last, 0.2))


func _color(is_finish: bool, alpha: float) -> Color:
	var color := InterfaceTheme.PAPER if is_finish else InterfaceTheme.ACCENT
	color.a = alpha
	return color
