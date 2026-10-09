class_name BuildingDetailGeometry
extends RefCounted


static func surface() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


## Faces a box can leave out when a neighbour (the wall it sits on, a bar it
## overlaps) already hides them. Trim is built in the thousands, and every
## hidden face is triangles drawn for nothing in the depth, colour and shadow passes.
const SKIP_BACK := 1  ## the -w face, against the wall
const SKIP_ENDS := 2  ## the +/-v faces, buried in a crossing bar


static func box(st: SurfaceTool, center: Vector3, size: Vector3, along: Vector3 = Vector3.RIGHT, skip: int = 0) -> void:
	var u := along.normalized() * size.x * 0.5
	var v := Vector3.UP * size.y * 0.5
	var w := along.normalized().cross(Vector3.UP) * size.z * 0.5
	var axes := [[u, v, w], [v, w, u], [w, u, v]]
	for axis: int in range(3):
		var a: Vector3 = axes[axis][0]
		var b: Vector3 = axes[axis][1]
		var c: Vector3 = axes[axis][2]
		for sign_value: float in [-1.0, 1.0]:
			if axis == 0 and sign_value < 0.0 and skip & SKIP_BACK != 0:
				continue
			if axis == 1 and skip & SKIP_ENDS != 0:
				continue
			var face := center + c * sign_value
			PolygonUtils.add_quad_facing(st, face - a - b, face + a - b, face + a + b, face - a + b, c.normalized() * sign_value)


## Detail meshes are small trim, so by default they cast no shadow: the wall
## behind already does, and each cascade would redraw every one of them.
static func finish(st: SurfaceTool, name_str: String, material: Material, max_distance: float = 0.0, casts_shadow: bool = false) -> MeshInstance3D:
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = name_str
	instance.mesh = mesh
	instance.material_override = material
	if not casts_shadow:
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if max_distance > 0.0:
		instance.visibility_range_end = max_distance
		instance.visibility_range_end_margin = 15.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return instance


static var _matte_materials: Dictionary = {}


## Shared per colour and roughness: see BuildingMaterialFactory for why.
static func matte(color: Color, roughness: float = 0.8) -> StandardMaterial3D:
	var key := [color, roughness]
	if _matte_materials.has(key):
		return _matte_materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	_matte_materials[key] = mat
	return mat
