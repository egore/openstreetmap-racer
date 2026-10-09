class_name BuildingDetailGeometry
extends RefCounted


static func surface() -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	return st


static func box(st: SurfaceTool, center: Vector3, size: Vector3, along: Vector3 = Vector3.RIGHT) -> void:
	var u := along.normalized() * size.x * 0.5
	var v := Vector3.UP * size.y * 0.5
	var w := along.normalized().cross(Vector3.UP) * size.z * 0.5
	for axes: Array in [[u, v, w], [v, w, u], [w, u, v]]:
		var a: Vector3 = axes[0]
		var b: Vector3 = axes[1]
		var c: Vector3 = axes[2]
		for sign_value: float in [-1.0, 1.0]:
			var face := center + c * sign_value
			PolygonUtils.add_quad_facing(st, face - a - b, face + a - b, face + a + b, face - a + b, c.normalized() * sign_value)


static func finish(st: SurfaceTool, name_str: String, material: Material, max_distance: float = 0.0) -> MeshInstance3D:
	var arrays := st.commit_to_arrays()
	if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty():
		return null
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var instance := MeshInstance3D.new()
	instance.name = name_str
	instance.mesh = mesh
	instance.material_override = material
	if max_distance > 0.0:
		instance.visibility_range_end = max_distance
		instance.visibility_range_end_margin = 15.0
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
	return instance


static func matte(color: Color, roughness: float = 0.8) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
	var key := [color, roughness]
	if _matte_materials.has(key):
		return _matte_materials[key]
	_matte_materials[key] = mat
