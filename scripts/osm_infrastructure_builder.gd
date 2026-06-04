class_name OSMInfrastructureBuilder
extends RefCounted

## Builds elevated structural geometry from OSM ways that sit *above* the ground
## rather than draping onto it: overhead power lines (power=line/minor_line/cable)
## and sign/signal gantries (man_made=gantry). Unlike the terrain ribbons in
## OSMWayBuilder these features are raised structures, so they share tube/beam
## geometry (PolygonUtils.add_tube_segment) instead of ribbon math.

# ─── Power lines ─────────────────────────────────────────────────────────────

const POWERLINE_COLORS := {
	"line": Color(0.1, 0.1, 0.12),         # high-voltage transmission
	"minor_line": Color(0.15, 0.15, 0.17), # distribution
	"cable": Color(0.12, 0.12, 0.14),
}
const POWERLINE_DEFAULT_COLOR := Color(0.12, 0.12, 0.14)
# Cable hangs at these heights (meters) above the ground at each pylon/pole.
const POWERLINE_HEIGHTS := {
	"line": 18.0,        # transmission towers are tall
	"minor_line": 8.0,   # wooden distribution poles
	"cable": 8.0,
}
const POWERLINE_DEFAULT_HEIGHT := 10.0
const POWERLINE_SAG := 0.08          # mid-span droop as a fraction of span length
const POWERLINE_RADIUS := 0.12       # visual thickness of the cable
const POWERLINE_SUBDIVS := 6         # catenary samples per span

## Builds drooping cable geometry strung between the nodes of a power=line /
## power=minor_line way (the supporting towers/poles are placed separately as
## node assets). Each span hangs as a simple parabolic catenary at the line's
## nominal height above the terrain. Returns null for degenerate ways.
func build_power_line(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	var power_type: String = way.tags.get("power", "minor_line")
	var color: Color = POWERLINE_COLORS.get(power_type, POWERLINE_DEFAULT_COLOR)
	var height: float = POWERLINE_HEIGHTS.get(power_type, POWERLINE_DEFAULT_HEIGHT)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "PowerLine_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(points.size() - 1):
		_emit_catenary_span(st, points[i], points[i + 1], height)

	mesh_instance.mesh = st.commit()
	return mesh_instance

## Emit a thin sagging tube approximating a single cable span between two
## supports. The cable starts and ends at `height` above each support's terrain
## elevation and droops by POWERLINE_SAG * span in the middle.
func _emit_catenary_span(st: SurfaceTool, a: Vector3, b: Vector3, height: float) -> void:
	var span := Vector3(b.x - a.x, 0.0, b.z - a.z).length()
	var sag := span * POWERLINE_SAG
	var samples: Array[Vector3] = []
	for s: int in range(POWERLINE_SUBDIVS + 1):
		var t := float(s) / float(POWERLINE_SUBDIVS)
		var x := lerpf(a.x, b.x, t)
		var z := lerpf(a.z, b.z, t)
		var ground := lerpf(a.y, b.y, t)
		# Parabolic droop: 0 at the ends, -sag at mid-span.
		var droop := -sag * (4.0 * t * (1.0 - t))
		samples.append(Vector3(x, ground + height + droop, z))
	for s: int in range(samples.size() - 1):
		PolygonUtils.add_tube_segment(st, samples[s], samples[s + 1], POWERLINE_RADIUS)

# ─── Man-made gantries ───────────────────────────────────────────────────────

const GANTRY_COLOR := Color(0.45, 0.45, 0.48)  # galvanised steel
const GANTRY_CLEARANCE := 5.5                   # underside height above ground (m)
const GANTRY_BEAM := 0.5                        # cross-beam thickness (m)
const GANTRY_LEG := 0.4                         # support-leg thickness (m)

## Builds a sign/signal gantry: a horizontal cross-beam strung between the way's
## endpoints at road clearance height, plus a vertical support leg dropping to
## the ground at each end. Intermediate nodes are spanned as straight beam
## sections. Returns null for degenerate ways.
func build_gantry(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Gantry_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = GANTRY_COLOR
	mat.metallic = 0.5
	st.set_material(mat)

	# Horizontal beam following the way at clearance height.
	for i: int in range(points.size() - 1):
		var a := points[i] + Vector3(0.0, GANTRY_CLEARANCE, 0.0)
		var b := points[i + 1] + Vector3(0.0, GANTRY_CLEARANCE, 0.0)
		PolygonUtils.add_tube_segment(st, a, b, GANTRY_BEAM * 0.5)

	# Vertical support legs at the two ends.
	var p0 := points[0]
	var p1 := points[points.size() - 1]
	PolygonUtils.add_tube_segment(st,
		Vector3(p0.x, p0.y, p0.z),
		Vector3(p0.x, p0.y + GANTRY_CLEARANCE, p0.z), GANTRY_LEG * 0.5)
	PolygonUtils.add_tube_segment(st,
		Vector3(p1.x, p1.y, p1.z),
		Vector3(p1.x, p1.y + GANTRY_CLEARANCE, p1.z), GANTRY_LEG * 0.5)

	mesh_instance.mesh = st.commit()
	return mesh_instance
