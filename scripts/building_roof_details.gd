class_name BuildingRoofDetails
extends RefCounted


static func build(root: Node3D, points: PackedVector3Array, base: float, shape: String, style: Dictionary, roof_color: Color, id: int, context: BuildingNeighborhood = null) -> void:
	var roof := root.get_node_or_null("Roof") as MeshInstance3D
	if roof == null or roof.mesh == null:
		return
	var trim := BuildingDetailGeometry.surface()
	var caps := BuildingDetailGeometry.surface()
	var gutters := BuildingDetailGeometry.surface()
	var triangles := BuildingSurfaceUV.faces_of(roof)
	var edges := {}
	var top := base
	for i: int in range(0, triangles.size(), 3):
		var a := triangles[i]
		var b := triangles[i + 1]
		var c := triangles[i + 2]
		var normal := (c - a).cross(b - a).normalized()
		top = maxf(top, maxf(a.y, maxf(b.y, c.y)))
		for pair: Array in [[a, b], [b, c], [c, a]]:
			var p: Vector3 = pair[0]
			var q: Vector3 = pair[1]
			var first := p.snapped(Vector3.ONE * 0.001)
			var second := q.snapped(Vector3.ONE * 0.001)
			var key := [first, second] if first < second else [second, first]
			if edges.has(key):
				edges[key].count += 1
				edges[key].crease = float(edges[key].normal.dot(normal)) < 0.98
			else:
				edges[key] = {"a": p, "b": q, "normal": normal, "center": (a + b + c) / 3.0, "count": 1, "crease": false}
	for edge: Dictionary in edges.values():
		var a: Vector3 = edge.a
		var b: Vector3 = edge.b
		if a.distance_to(b) < 0.05:
			continue
		if edge.count > 1:
			if edge.crease and absf(a.y - top) < 0.02 and absf(b.y - top) < 0.02:
				_beam(caps, a + Vector3.UP * 0.045, b + Vector3.UP * 0.045, 0.24, 0.14)
			continue
		var along := (b - a).normalized()
		var outward := Vector3(-along.z, 0.0, along.x).normalized()
		var mid := (a + b) * 0.5
		if outward.dot(Vector3(edge.center.x - mid.x, 0.0, edge.center.z - mid.z)) > 0.0:
			outward = -outward
		if context != null and context.blocked(Vector3(mid.x, base - 0.3, mid.z) + outward * 0.2, id):
			continue
		if shape == "flat":
			_beam(trim, a + Vector3.UP * 0.1, b + Vector3.UP * 0.1, 0.23, 0.28)
			_beam(caps, a + Vector3.UP * 0.26, b + Vector3.UP * 0.26, 0.31, 0.06)
		elif shape in ["gabled", "hipped", "half-hipped", "gambrel", "mansard", "skillion", "saltbox"] and edge.normal.y > 0.15:
			var offset := outward * 0.24
			offset.y = -Vector3(edge.normal).dot(offset) / float(edge.normal.y)
			var outer_a := a + offset
			var outer_b := b + offset
			PolygonUtils.add_quad_facing(caps, a, b, outer_b, outer_a, edge.normal)
			PolygonUtils.add_quad_facing(trim, a - Vector3.UP * 0.12, b - Vector3.UP * 0.12, outer_b - Vector3.UP * 0.12, outer_a - Vector3.UP * 0.12, -edge.normal)
			_beam(trim, outer_a - Vector3.UP * 0.06, outer_b - Vector3.UP * 0.06, 0.08, 0.14)
			if absf(a.y - b.y) < 0.05 and absf(mid.y - base) < 0.1:
				_beam(gutters, outer_a + outward * 0.04 - Vector3.UP * 0.06, outer_b + outward * 0.04 - Vector3.UP * 0.06, 0.13, 0.10)
	var trim_mesh := BuildingDetailGeometry.finish(trim, "RoofTrim", BuildingDetailGeometry.matte(style.frame_color), 300.0)
	var cap_mesh := BuildingDetailGeometry.finish(caps, "RoofCaps", BuildingDetailGeometry.matte(roof_color), 300.0)
	var gutter_mesh := BuildingDetailGeometry.finish(gutters, "Gutters", BuildingDetailGeometry.matte(Color("494b49"), 0.45), 120.0)
	for mesh: MeshInstance3D in [trim_mesh, cap_mesh, gutter_mesh]:
		if mesh != null:
			root.add_child(mesh)
	if shape in ["gabled", "hipped"] and int(style.seed) % 3 == 0 and BuildingStyleResolver.rectangular_dimensions(points) != Vector2.ZERO:
		_add_chimney(root, points, triangles, style)


static func _beam(st: SurfaceTool, a: Vector3, b: Vector3, width: float, height: float) -> void:
	var u := (b - a) * 0.5
	var side := u.normalized().cross(Vector3.UP).normalized()
	if side.length_squared() < 0.5:
		return
	var v := side.cross(u.normalized()) * height * 0.5
	var w := side * width * 0.5
	var center := (a + b) * 0.5
	for axes: Array in [[u, v, w], [v, w, u], [w, u, v]]:
		var x: Vector3 = axes[0]
		var y: Vector3 = axes[1]
		var z: Vector3 = axes[2]
		for direction: float in [-1.0, 1.0]:
			var face := center + z * direction
			PolygonUtils.add_quad_facing(st, face - x - y, face + x - y, face + x + y, face - x + y, z.normalized() * direction)


static func _add_chimney(root: Node3D, points: PackedVector3Array, faces: PackedVector3Array, style: Dictionary) -> void:
	var ridge := PolygonUtils.polygon_longest_edge_dir(points)
	var size := BuildingStyleResolver.rectangular_dimensions(points)
	var p := PolygonUtils.polygon_centroid(points) + ridge * size.x * 0.2 + ridge.cross(Vector3.UP) * size.y * 0.13
	for i: int in range(0, faces.size(), 3):
		var a := faces[i]
		var b := faces[i + 1]
		var c := faces[i + 2]
		var polygon := PackedVector2Array([Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z)])
		var normal := (c - a).cross(b - a).normalized()
		if absf(normal.y) < 0.1 or not Geometry2D.is_point_in_polygon(Vector2(p.x, p.z), polygon):
			continue
		p.y = a.y - (normal.x * (p.x - a.x) + normal.z * (p.z - a.z)) / normal.y
		var st := BuildingDetailGeometry.surface()
		BuildingDetailGeometry.box(st, p + Vector3.UP * 0.45, Vector3(0.65, 1.5, 0.65), ridge)
		BuildingDetailGeometry.box(st, p + Vector3.UP * 1.2, Vector3(0.8, 0.12, 0.8), ridge)
		var chimney := BuildingDetailGeometry.finish(st, "Chimney", BuildingDetailGeometry.matte(Color("745c50").lerp(style.door_color, 0.15)), 180.0)
		root.add_child(chimney)
		return
