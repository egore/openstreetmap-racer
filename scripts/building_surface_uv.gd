class_name BuildingSurfaceUV
extends RefCounted


static func apply(root: Node3D, origin: Vector3, ridge: Vector3) -> void:
	for child: Node in root.get_children():
		if child is MeshInstance3D and child.mesh != null:
			project(child, origin, ridge, child.name == "Roof")


static func project(instance: MeshInstance3D, origin: Vector3, ridge: Vector3, roof: bool) -> void:
	var mesh := ArrayMesh.new()
	for surface: int in range(instance.mesh.get_surface_count()):
		var arrays := instance.mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(instance.mesh.surface_get_material(surface))
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
	instance.mesh = mesh
