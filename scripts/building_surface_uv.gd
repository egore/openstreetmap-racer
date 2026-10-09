class_name BuildingSurfaceUV
extends RefCounted

## Reading a committed mesh back (surface_get_arrays / get_faces) copies it out
## of GPU memory and stalls the render device, which costs tens of ms per
## building while streaming. So every building mesh remembers the arrays it was
## built from; later stages read that copy instead.
const CPU_SURFACES_META := &"cpu_surfaces"


## Commits `st` into a mesh for `instance` and keeps the arrays it was built from.
static func commit(st: SurfaceTool, instance: MeshInstance3D) -> ArrayMesh:
	var mesh := st.commit()
	instance.set_meta(CPU_SURFACES_META, [{"arrays": st.commit_to_arrays(), "material": mesh.surface_get_material(0)}])
	return mesh


static func apply(root: Node3D, origin: Vector3, ridge: Vector3) -> void:
	for child: Node in root.get_children():
		if child is MeshInstance3D and child.mesh != null:
			project(child, origin, ridge, child.name == "Roof")


## The triangle corners of every surface of `instance`, three vertices per triangle.
static func faces_of(instance: MeshInstance3D) -> PackedVector3Array:
	if not instance.has_meta(CPU_SURFACES_META):
		return instance.mesh.get_faces()
	var faces := PackedVector3Array()
	for surface: Dictionary in instance.get_meta(CPU_SURFACES_META):
		var vertices: PackedVector3Array = surface["arrays"][Mesh.ARRAY_VERTEX]
		var indices = surface["arrays"][Mesh.ARRAY_INDEX]
		if indices == null or indices.is_empty():
			faces.append_array(vertices)
		else:
			for index: int in indices:
				faces.append(vertices[index])
	return faces


static func project(instance: MeshInstance3D, origin: Vector3, ridge: Vector3, roof: bool) -> void:
	var mesh := ArrayMesh.new()
	var kept: Array[Dictionary] = []
	for surface: Dictionary in _surfaces_of(instance):
		var arrays: Array = surface["arrays"]
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(surface["material"])
		var count := indices.size() if not indices.is_empty() else vertices.size()
		for i: int in range(0, count, 3):
			var a := indices[i] if not indices.is_empty() else i
			var b := indices[i + 1] if not indices.is_empty() else i + 1
			var c := indices[i + 2] if not indices.is_empty() else i + 2
			var n := (vertices[c] - vertices[a]).cross(vertices[b] - vertices[a]).normalized()
			if n.length_squared() < 0.5:
				continue
			var u := n.cross(Vector3.UP).normalized()
			if u.length_squared() < 0.5:
				u = ridge.normalized()
			var v := n.cross(u).normalized() if roof else Vector3.UP
			for index: int in [a, b, c]:
				var p := vertices[index] - origin
				st.set_normal(n)
				st.set_uv(Vector2(p.dot(u), p.dot(v)))
				st.add_vertex(vertices[index])
		st.generate_tangents()
		st.commit(mesh)
		kept.append({"arrays": st.commit_to_arrays(), "material": surface["material"]})
	instance.mesh = mesh
	instance.set_meta(CPU_SURFACES_META, kept)


static func _surfaces_of(instance: MeshInstance3D) -> Array:
	if instance.has_meta(CPU_SURFACES_META):
		return instance.get_meta(CPU_SURFACES_META)
	var surfaces := []
	for surface: int in range(instance.mesh.get_surface_count()):
		surfaces.append({
			"arrays": instance.mesh.surface_get_arrays(surface),
			"material": instance.mesh.surface_get_material(surface),
		})
	return surfaces
