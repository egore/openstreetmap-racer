class_name OSMWayBuilder
extends RefCounted

## Builds terrain-draped ribbon meshes from linear OSM ways: roads (highway=*),
## waterways (waterway=*), and railways (railway=*). All three share the miter-
## joined ribbon edge math and DEM-following subdivision below. Elevated
## structures that ride above the ground (power lines, gantries) live in
## OSMInfrastructureBuilder instead.

## Terrain parameters set by the tile manager. When a HeightProvider is
## available, polyline points are subdivided so road/waterway/railway ribbons
## follow the DEM instead of linearly interpolating between sparse OSM nodes.
var height_provider: HeightProvider = null
var terrain_grid_step: float = 0.0
## [min_x, max_x, min_z, max_z] of the tile currently being built, or null. When
## set, a way's centreline is clipped to this rect (plus CLIP_MARGIN) before the
## ribbon is built, so a country-spanning way (e.g. a primary road) only builds
## the portion inside this tile instead of its whole length in every tile it
## touches. The manager sets this per tile before dispatching way builds.
var tile_clip_rect: Variant = null
## Overlap (m) added around the tile when clipping ribbons, so adjacent tiles'
## clipped ribbons meet with no seam gap. A couple of metres is plenty.
const CLIP_MARGIN := 3.0

# Road cross-section rules (widths, colours, kerbs, layers) live in RoadProfile
# so the junction solver and this builder cannot drift apart. Preloaded rather
# than referenced by bare class_name so it resolves during headless test
# discovery regardless of the global class-cache order (same pattern as the tile
# manager's script preloads). The aliases keep the historical constant names
# available to the waterway/railway code below and to existing tests.
const RoadProfileScript := preload("res://scripts/road_profile.gd")
const RoadNetworkContextScript := preload("res://scripts/road_network_context.gd")

## The solved intersection layout for the tile being built. Set by the tile
## manager before dispatching this tile's way builds; when null, roads are built
## full-length with no junction trimming (the flat/legacy path and unit tests
## that exercise a single way in isolation).
var network: RoadNetworkContextScript = null

const ROAD_WIDTHS := RoadProfileScript.ROAD_WIDTHS
const ROAD_COLORS := RoadProfileScript.ROAD_COLORS
const DEFAULT_WIDTH := RoadProfileScript.DEFAULT_WIDTH
const DEFAULT_COLOR := RoadProfileScript.DEFAULT_COLOR
const ROAD_Y := RoadProfileScript.ROAD_Y
const SIDEWALK_WIDTH := RoadProfileScript.SIDEWALK_WIDTH
const SIDEWALK_HEIGHT := RoadProfileScript.SIDEWALK_HEIGHT
const SIDEWALK_COLOR := RoadProfileScript.SIDEWALK_COLOR
const SIDEWALK_BASE_Y := 0.0

## The most of a road's own length that junction trimming may consume, as a
## fraction. A short connector between two close junctions can be asked to give
## up more than it has; honouring that literally deletes the road (or leaves an
## unusable sliver), which reads as the street failing to connect. Capping the
## total trim keeps a visible ribbon on every way — the intersection caps simply
## overlap it a little, which is invisible because they are opaque and painted
## above the road surface.
const MAX_TRIM_FRACTION := 0.6

## Shortest span (metres) worth emitting between two junctions.
##
## Junctions in OSM often sit a metre or two apart (a slip road joining beside a
## crossing, a service entrance next to a side street). The stub of carriageway
## between them is invisible once the two intersection caps are drawn, but it
## still emits a complete kerb run with start and end caps — which appears as a
## detached slab of pavement floating beside the road.
const MIN_SPAN_LENGTH := 2.0

func build_road(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

	if points.size() < 2:
		return null

	# Tunnels are not drawn on the surface at all — they run below it.
	if RoadProfileScript.is_tunnel(way):
		return null

	var highway_type := RoadProfileScript.highway_type(way)
	var color := RoadProfileScript.color_for(highway_type)

	# Lane layout parsed from OSM tags (lanes, lanes:forward/backward, oneway).
	# Drives the procedural markings; the width comes from RoadProfile, which the
	# junction solver also uses so caps and ribbons agree exactly.
	var lane_spec := RoadLaneSpec.from_tags(highway_type, way.tags)
	var width := RoadProfileScript.width_for(way)

	# Roads now END at intersections rather than overlapping through them. Each
	# end that meets a junction is pulled back by the distance the solver worked
	# out, and the hole this leaves is filled by a dedicated cap mesh (see
	# build_junction_cap). Ways with no junction at an end still run to their
	# terminal node, so a street that simply continues is unbroken.
	var trim_start := _trim_at_way_start(way)
	# One polyline per junction-to-junction span. A way running THROUGH an
	# intersection is cut there too, not just at its own two ends.
	var spans := _split_at_junctions(points, way, osm_data)
	if spans.is_empty():
		# Every span was consumed by its own junction trims — the way is shorter
		# than the intersections it connects. The caps cover that ground.
		return null

	# Subdivide long segments so each span follows the terrain.
	if terrain_grid_step > 0.0:
		var draped: Array = []
		for span: PackedVector3Array in spans:
			draped.append(PolygonUtils.subdivide_polyline_to_terrain(
				span, height_provider, terrain_grid_step))
		spans = draped

	# The full (untrimmed) centreline is still what marking distances and the
	# shader's end-fade are measured against, so keep it for the UV maths below.
	points = PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	# Transverse markings from OSM nodes ON this way (zebra crossings, stop and
	# give-way lines). Built from the RAW node polyline, so each marking's
	# metres-along is measured from the way's ORIGINAL start.
	#
	# The ribbon no longer starts there: junction trimming cuts trim_start metres
	# off the front, and the ribbon UVs restart from that new origin. Without
	# rebasing, every marking on a road that meets an intersection is painted
	# trim_start metres too far along — which is what put zebra crossings and
	# stop lines in visibly wrong places, sometimes out in the intersection.
	var marking_spec := RoadMarkingSpec.from_way(way.node_ids, osm_data.nodes)
	marking_spec = marking_spec.rebased(trim_start)
	# Cumulative along-road distance at each point, plus total length, so the
	# ribbon UVs (metres travelled) and the shader's end-fade line up.
	var along_at := _cumulative_along(points)
	var road_length: float = along_at[along_at.size() - 1] if along_at.size() > 0 else 0.0

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Road_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# Asphalt for paved roads (procedural noise grain + faked normal bump),
	# matte fallback for unpaved/soft surfaces. The shader samples noise in
	# world-space XZ; lane markings additionally use the ribbon UVs we emit
	# below (UV.x = metres along the road, UV.y = fraction across it).
	var mat := RoadMaterialFactory.create_road_material(
		highway_type, color, lane_spec, width, road_length, marking_spec)
	st.set_material(mat)

	var sidewalk_st := SurfaceTool.new()
	sidewalk_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var sidewalk_mat := RoadMaterialFactory.create_sidewalk_material()
	sidewalk_st.set_material(sidewalk_mat)

	var sidewalk_sides := RoadProfileScript.sidewalk_sides(way.tags)
	var has_left_sidewalk: bool = sidewalk_sides["left"]
	var has_right_sidewalk: bool = sidewalk_sides["right"]

	# Whether to conform the surface to the terrain triangulation. Even with the
	# edges draped, a flat quad spanning a cell sits below terrain folds crossing
	# it (a "hill in the middle of the street"). When a DEM is present we clip
	# each segment quad against the terrain mesh so the surface coincides with
	# the ground exactly; flat worlds keep the cheap single quad.
	var conform := height_provider != null and height_provider.is_ready() \
		and terrain_grid_step > 0.0

	# Clip each span to the current tile (plus a small margin) so a way that
	# spans many tiles only builds its in-tile portion here instead of its whole
	# length in every tile it touches. Marking UVs are metres-from-way-start, so
	# each clipped part carries the along-distance of its FIRST point (found in
	# along_at by nearest original point) to keep markings aligned. When no clip
	# rect is set (flat/whole-map path) each span is used as-is.
	var parts: Array = []
	for span: PackedVector3Array in spans:
		if span.size() < 2:
			continue
		if tile_clip_rect == null:
			parts.append(span)
			continue
		for piece: PackedVector3Array in PolygonUtils.clip_polyline_to_rect(
				span, tile_clip_rect, CLIP_MARGIN):
			parts.append(piece)
	if parts.is_empty():
		return null  # way doesn't actually enter this tile

	for part: PackedVector3Array in parts:
		var part_pts: PackedVector3Array = part
		if part_pts.size() < 2:
			continue
		# Along-distance offset for this part = distance from the way start to the
		# part's first point, so lane/crossing markings line up across the clip.
		var part_along0 := _along_at_point(points, along_at, part_pts[0])
		_emit_road_ribbon(
			st, sidewalk_st, part_pts, width, part_along0,
			has_left_sidewalk, has_right_sidewalk, conform)

	var mesh := st.commit()
	if has_left_sidewalk or has_right_sidewalk:
		mesh = sidewalk_st.commit(mesh)

	mesh_instance.mesh = mesh
	# Bridges/tunnels ride above or below ground level. Applying the offset to
	# the NODE (rather than baking it into every vertex) keeps the geometry in
	# the same world frame as the terrain sampling that produced it, and lets a
	# bridge deck be raised without re-draping it onto the ground it spans.
	var layer_y := RoadProfileScript.layer_offset(way)
	if layer_y != 0.0:
		mesh_instance.position.y = layer_y
	return mesh_instance


## How far this way's ribbon is cut back at its FIRST node. Exposed separately
## from the trimming itself because the marking spec must be rebased by exactly
## this distance (the ribbon's UV origin moves with it).
func _trim_at_way_start(way: OSMParser.OSMWay) -> float:
	if network == null or way.node_ids.is_empty():
		return 0.0
	return network.trim_at(way.id, way.node_ids[0], true)


## Split a way into the spans between the junctions along it, each already
## trimmed back at both ends.
##
## A way does not merely START and END at intersections — it commonly runs
## THROUGH several. Those interior junction nodes must cut the ribbon too, or the
## road is drawn as one continuous strip straight across every crossing it
## passes. The junction cap cannot hide that: the cap is a rounded polygon while
## the ribbon is a rectangle, so the ribbon's square corners stick out past the
## cap's fillets — which is exactly the "street ends in a 90° edge" and the
## "hole in the continuing street" seen in-game.
##
## Returns one polyline per drawable span. A way with no junctions on it yields a
## single span (its whole length); a way crossing two junctions yields three.
## Spans consumed entirely by their own trims are dropped.
func _split_at_junctions(
		points: PackedVector3Array, way: OSMParser.OSMWay,
		osm_data: OSMParser.OSMData) -> Array:
	if network == null or points.size() < 2 or way.node_ids.is_empty():
		return [points] as Array

	# Distance along the way of every junction node on it, paired with how far
	# the ribbon must be cut back on each side of that junction.
	var cuts: Array = []   # [{ along, trim_before, trim_after }]
	var along := 0.0
	var prev_pos := Vector3.ZERO
	var have_prev := false
	for i: int in range(way.node_ids.size()):
		var nid: int = way.node_ids[i]
		if not osm_data.nodes.has(nid):
			continue
		var pos: Vector3 = osm_data.nodes[nid].local_pos
		if have_prev:
			along += _xz_distance(prev_pos, pos)
		prev_pos = pos
		have_prev = true

		if not network.has_junction(nid):
			continue
		# The arm LEAVING this node along the way (at_way_start=true) governs the
		# cut on the far side; the arm ARRIVING here (false) governs the near
		# side. At the way's own endpoints only one of the two exists.
		var trim_after := network.trim_at(way.id, nid, true)
		var trim_before := network.trim_at(way.id, nid, false)
		if trim_after <= 0.0 and trim_before <= 0.0:
			continue
		cuts.append({
			"along": along,
			"trim_before": trim_before,
			"trim_after": trim_after,
		})

	if cuts.is_empty():
		return [points] as Array

	var total := 0.0
	for i: int in range(points.size() - 1):
		total += _xz_distance(points[i], points[i + 1])

	# Walk the way, emitting the span between each consecutive pair of cuts.
	var spans: Array = []
	var span_start := 0.0
	var span_start_trim := 0.0
	for cut: Dictionary in cuts:
		var cut_at: float = cut["along"]
		var end_trim: float = cut["trim_before"]
		_append_span(spans, points, span_start, span_start_trim, cut_at, end_trim, total)
		span_start = cut_at
		span_start_trim = cut["trim_after"]
	# Final span: last junction to the end of the way.
	_append_span(spans, points, span_start, span_start_trim, total, 0.0, total)
	return spans


## Cut one span out of a polyline and append it, unless the trims consume it.
##
## `from`/`to` are distances along the polyline bounding the span; `trim_from`
## and `trim_to` are pulled off each end. As in _trim_points_at_junctions, the
## trims are scaled down rather than honoured literally when the span is too
## short to afford them, so a stub between two close junctions still draws.
func _append_span(
		spans: Array, points: PackedVector3Array,
		from: float, trim_from: float, to: float, trim_to: float,
		_total: float) -> void:
	var span_len := to - from
	if span_len <= 0.01:
		return
	var requested := trim_from + trim_to
	var budget := span_len * MAX_TRIM_FRACTION
	if requested > budget and requested > 0.0:
		var scale := budget / requested
		trim_from *= scale
		trim_to *= scale

	var a := from + trim_from
	var b := to - trim_to
	if b - a <= MIN_SPAN_LENGTH:
		# Too short to be worth drawing. A sub-metre stub between two adjacent
		# junctions contributes no visible carriageway, but it DOES emit a full
		# kerb run complete with both end caps — which reads as a detached slab
		# of pavement floating beside the road. The junction caps either side
		# already cover this ground, so dropping it is both cheaper and correct.
		return
	spans.append(_slice_polyline(points, a, b))


## The portion of a polyline between two distances along it, with exact
## interpolated endpoints so a span's mouth lands precisely where the junction
## cap expects it.
static func _slice_polyline(
		points: PackedVector3Array, from: float, to: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.append(_point_along(points, from))
	var travelled := 0.0
	for i: int in range(points.size()):
		if i > 0:
			travelled += _xz_distance(points[i - 1], points[i])
		if travelled > from + 0.01 and travelled < to - 0.01:
			out.append(points[i])
	out.append(_point_along(points, to))
	return out


## Trim a road's centreline back from any junction at either end.
##
## Retained for the endpoint-only case and for tests that exercise a single way
## in isolation. The streaming path goes through _split_at_junctions, which also
## cuts the way at the intersections it passes THROUGH.
##
## Returns the (possibly shortened) polyline. When trimming would consume the
## whole way, an empty array is returned and the caller skips the ribbon.
func _trim_points_at_junctions(
		points: PackedVector3Array, way: OSMParser.OSMWay) -> PackedVector3Array:
	if network == null or points.size() < 2 or way.node_ids.is_empty():
		return points

	var first_node: int = way.node_ids[0]
	var last_node: int = way.node_ids[way.node_ids.size() - 1]
	# at_way_start distinguishes the two arms a way contributes when it both
	# starts and ends at the same junction (a loop).
	var trim_start := network.trim_at(way.id, first_node, true)
	var trim_end := network.trim_at(way.id, last_node, false)
	if trim_start <= 0.0 and trim_end <= 0.0:
		return points

	# Short connector ways (slip roads, the stub between two close junctions) can
	# be shorter than the trims their two ends ask for. Taking those literally
	# deletes the road entirely or leaves a half-metre sliver, which reads as a
	# hole in the network — the street visibly stops connecting.
	#
	# So the trims are scaled down to fit whatever the way can afford. The cap
	# geometry then overlaps the ribbon slightly instead of meeting it exactly,
	# which is invisible (the cap is opaque asphalt painted above the road) and
	# far better than a missing street.
	var total := 0.0
	for i: int in range(points.size() - 1):
		total += _xz_distance(points[i], points[i + 1])
	var budget := total * MAX_TRIM_FRACTION
	var requested := trim_start + trim_end
	if requested > budget and requested > 0.0:
		var scale := budget / requested
		trim_start *= scale
		trim_end *= scale

	return _trim_polyline(points, trim_start, trim_end)


## Cut `from_start` metres off the beginning and `from_end` metres off the end of
## a polyline, interpolating a new endpoint at the exact cut distance so the
## ribbon mouth lands precisely where the junction cap expects it.
##
## Returns an empty array when the two cuts overlap (the polyline is shorter than
## the material removed).
static func _trim_polyline(
		points: PackedVector3Array, from_start: float,
		from_end: float) -> PackedVector3Array:
	var total := 0.0
	for i: int in range(points.size() - 1):
		total += _xz_distance(points[i], points[i + 1])
	if from_start + from_end >= total - 0.01:
		return PackedVector3Array()

	var out := PackedVector3Array()
	var keep_from := from_start
	var keep_to := total - from_end
	var travelled := 0.0

	# Emit the exact start point, then every original vertex inside the kept
	# span, then the exact end point.
	out.append(_point_along(points, keep_from))
	for i: int in range(points.size()):
		if i > 0:
			travelled += _xz_distance(points[i - 1], points[i])
		if travelled > keep_from + 0.01 and travelled < keep_to - 0.01:
			out.append(points[i])
	out.append(_point_along(points, keep_to))
	return out


## The point `distance` metres along a polyline, interpolated within whichever
## segment contains it. Clamped to the polyline's ends.
static func _point_along(points: PackedVector3Array, distance: float) -> Vector3:
	if points.size() == 0:
		return Vector3.ZERO
	if distance <= 0.0:
		return points[0]
	var travelled := 0.0
	for i: int in range(points.size() - 1):
		var seg := _xz_distance(points[i], points[i + 1])
		if seg <= 0.0001:
			continue
		if travelled + seg >= distance:
			var t := (distance - travelled) / seg
			return points[i].lerp(points[i + 1], t)
		travelled += seg
	return points[points.size() - 1]


## Horizontal (XZ) distance between two points. Road lengths are measured on the
## ground plane so a steep hill doesn't stretch marking spacing.
static func _xz_distance(a: Vector3, b: Vector3) -> float:
	var dx := b.x - a.x
	var dz := b.z - a.z
	return sqrt(dx * dx + dz * dz)



## Emit one ribbon (road surface + optional sidewalks) for a single centreline
## polyline into the shared SurfaceTools. Extracted from build_road so a way that
## was clipped into several in-tile parts can build each with its own along-offset
## while sharing one mesh/material. `along0` is the metres-from-way-start of
## part_pts[0], so lane/crossing marking UVs stay aligned after clipping.
func _emit_road_ribbon(
		st: SurfaceTool, sidewalk_st: SurfaceTool,
		part_pts: PackedVector3Array, width: float, along0: float,
		has_left_sidewalk: bool, has_right_sidewalk: bool, conform: bool) -> void:
	var half_w := width / 2.0
	var miter_limit := 2.0  # clamp miter to avoid spikes on very sharp turns
	var n_pts := part_pts.size()

	# Cumulative along-distance for THIS part, offset so UV.x remains metres from
	# the original way start (keeps markings aligned across the clip seam).
	var along_at := _cumulative_along(part_pts)
	for i: int in range(along_at.size()):
		along_at[i] += along0

	# Miter offset to the RIGHT edge per point (left edge is its negation).
	var miter_offsets: Array[Vector3] = []
	miter_offsets.resize(n_pts)
	for i: int in range(n_pts):
		miter_offsets[i] = _miter_offset(part_pts, i, half_w, miter_limit)

	var left_edge: Array = []
	var right_edge: Array = []
	left_edge.resize(n_pts)
	right_edge.resize(n_pts)
	for i: int in range(n_pts):
		var pt := part_pts[i]
		var off := miter_offsets[i]
		var lx := pt.x - off.x
		var lz := pt.z - off.z
		var rx := pt.x + off.x
		var rz := pt.z + off.z
		left_edge[i] = Vector3(lx, _edge_height(lx, lz, pt.y) + ROAD_Y, lz)
		right_edge[i] = Vector3(rx, _edge_height(rx, rz, pt.y) + ROAD_Y, rz)

	# Emit the road surface, one segment quad at a time.
	for i: int in range(n_pts - 1):
		var l0: Vector3 = left_edge[i]
		var r0: Vector3 = right_edge[i]
		var r1: Vector3 = right_edge[i + 1]
		var l1: Vector3 = left_edge[i + 1]

		var c0 := part_pts[i]
		var c1 := part_pts[i + 1]
		var uv_fn := _segment_uv_fn(
			Vector2(c0.x, c0.z), Vector2(c1.x, c1.z),
			along_at[i], width)

		if conform:
			var quad := PackedVector2Array([
				Vector2(l0.x, l0.z),
				Vector2(r0.x, r0.z),
				Vector2(r1.x, r1.z),
				Vector2(l1.x, l1.z),
			])
			PolygonUtils.emit_terrain_conforming_quad(
				st, quad, height_provider, terrain_grid_step, ROAD_Y, uv_fn)
		else:
			var uv_l0 := uv_fn.call(Vector2(l0.x, l0.z)) as Vector2
			var uv_r0 := uv_fn.call(Vector2(r0.x, r0.z)) as Vector2
			var uv_r1 := uv_fn.call(Vector2(r1.x, r1.z)) as Vector2
			var uv_l1 := uv_fn.call(Vector2(l1.x, l1.z)) as Vector2
			st.set_uv(uv_l0); st.set_normal(Vector3.UP); st.add_vertex(l0)
			st.set_uv(uv_r1); st.set_normal(Vector3.UP); st.add_vertex(r1)
			st.set_uv(uv_r0); st.set_normal(Vector3.UP); st.add_vertex(r0)
			st.set_uv(uv_l0); st.set_normal(Vector3.UP); st.add_vertex(l0)
			st.set_uv(uv_l1); st.set_normal(Vector3.UP); st.add_vertex(l1)
			st.set_uv(uv_r1); st.set_normal(Vector3.UP); st.add_vertex(r1)

		# End caps close off the kerb where a pavement run stops, so it reads as
		# a solid block rather than a hollow shell. They belong on the FIRST and
		# LAST segment of each emitted part.
		var is_first := i == 0
		var is_last := i == n_pts - 2
		if has_left_sidewalk:
			var center := Vector3(part_pts[i].x, left_edge[i].y, part_pts[i].z)
			var outward: Vector3 = (center - left_edge[i]).normalized()
			_add_sidewalk_segment(
				sidewalk_st, left_edge[i], left_edge[i + 1], -outward,
				is_first, is_last)

		if has_right_sidewalk:
			var center := Vector3(part_pts[i].x, right_edge[i].y, part_pts[i].z)
			var outward: Vector3 = (right_edge[i] - center).normalized()
			_add_sidewalk_segment(
				sidewalk_st, right_edge[i], right_edge[i + 1], outward,
				is_first, is_last)


## Along-distance (metres from way start) of the original point nearest `p`. Used
## to give a clipped part the correct marking-UV offset. Linear scan is fine —
## clipped parts are few and this runs once per part.
func _along_at_point(points: PackedVector3Array, along_at: PackedFloat32Array, p: Vector3) -> float:
	var best_i := 0
	var best_d := INF
	for i: int in range(points.size()):
		var dx := points[i].x - p.x
		var dz := points[i].z - p.z
		var d := dx * dx + dz * dz
		if d < best_d:
			best_d = d
			best_i = i
	return along_at[best_i] if best_i < along_at.size() else 0.0


# ─── Lane-marking UVs ─────────────────────────────────────────────────────────

## Cumulative XZ distance travelled along the polyline at each point (index i is
## the distance from points[0] to points[i]). along_at[0] == 0. Used so ribbon
## UVs carry metres-along-road, consistent across segments and across the
## terrain-conforming clip.
func _cumulative_along(points: PackedVector3Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(points.size())
	if points.size() == 0:
		return out
	out[0] = 0.0
	var acc := 0.0
	for i: int in range(1, points.size()):
		var dx := points[i].x - points[i - 1].x
		var dz := points[i].z - points[i - 1].z
		acc += sqrt(dx * dx + dz * dz)
		out[i] = acc
	return out


## Build a Callable that maps a world-space XZ point to a ribbon UV for one road
## segment running c0 -> c1 (centreline endpoints in XZ). UV.x is metres along
## the whole road (along0 at c0, growing toward c1); UV.y is the fraction across
## the carriageway (0 at the left edge, 1 at the right edge), clamped so clipped
## terrain vertices slightly outside the quad still read as on-road.
##
## "Right" is (dir rotated -90°) = Vector2(-dir.y, dir.x) in XZ, matching the
## miter offset convention (+offset = right edge) used when placing the edges.
func _segment_uv_fn(c0: Vector2, c1: Vector2, along0: float, width: float) -> Callable:
	var dir := c1 - c0
	var seg_len := dir.length()
	if seg_len < 0.0001:
		return func(_p: Vector2) -> Vector2: return Vector2(along0, 0.5)
	var udir := dir / seg_len
	# Right-hand lateral in XZ (mirrors _miter_offset's Vector3(-fwd.z,0,fwd.x)).
	var right := Vector2(-udir.y, udir.x)
	var half_w := maxf(width * 0.5, 0.0001)
	return func(p: Vector2) -> Vector2:
		var rel := p - c0
		var along := along0 + rel.dot(udir)
		var across := rel.dot(right)
		var frac := clampf(0.5 + across / (half_w * 2.0), 0.0, 1.0)
		return Vector2(along, frac)


## Terrain elevation (meters) for a ribbon edge vertex at (x, z).
##
## When a height provider is ready we re-sample the terrain *mesh* surface at the
## edge's own XZ position so each edge drapes independently (the fix for roads
## sinking into / floating over cross-slopes). Without a DEM we fall back to the
## supplied centerline elevation, which is 0 in the flat world.
func _edge_height(x: float, z: float, fallback_y: float) -> float:
	if height_provider != null and height_provider.is_ready():
		return height_provider.sample_mesh_height(x, z)
	return fallback_y


## Miter-joined offset vector from the centerline to the RIGHT edge at point i
## (the left edge is the negation). Bisects the bend angle at interior points so
## adjacent segments share edge vertices, with a miter-length clamp to avoid
## spikes at sharp turns. Pure XZ (the Y/drape is applied by the caller).
func _miter_offset(points: PackedVector3Array, i: int, half_w: float, miter_limit: float) -> Vector3:
	var n_pts := points.size()
	if i == 0:
		var fwd := (points[1] - points[0]).normalized()
		return Vector3(-fwd.z, 0.0, fwd.x).normalized() * half_w
	if i == n_pts - 1:
		var fwd := (points[i] - points[i - 1]).normalized()
		return Vector3(-fwd.z, 0.0, fwd.x).normalized() * half_w
	# Interior point: average the two segments' lateral directions.
	var fwd_prev := (points[i] - points[i - 1]).normalized()
	var fwd_next := (points[i + 1] - points[i]).normalized()
	var lat_prev := Vector3(-fwd_prev.z, 0.0, fwd_prev.x).normalized()
	var lat_next := Vector3(-fwd_next.z, 0.0, fwd_next.x).normalized()
	var miter_dir := (lat_prev + lat_next)
	if miter_dir.length_squared() < 0.0001:
		# Nearly antiparallel (U-turn) — fall back to the previous lateral.
		miter_dir = lat_prev
	else:
		miter_dir = miter_dir.normalized()
	# Scale to keep the perpendicular width correct: half_w / dot(miter, lateral).
	var d := miter_dir.dot(lat_prev)
	var miter_len := half_w
	if absf(d) > 0.0001:
		miter_len = half_w / d
	miter_len = clampf(miter_len, half_w, half_w * miter_limit)
	return miter_dir * miter_len

const WATERWAY_WIDTHS := {
	"river": 12.0,
	"canal": 8.0,
	"stream": 2.0,
	"ditch": 1.0,
	"drain": 1.0,
}
const WATERWAY_DEFAULT_WIDTH := 2.0
const WATERWAY_COLOR := Color(0.2, 0.4, 0.8)
const WATERWAY_Y := 0.01  # just above ground, below roads

## Builds a flat blue ribbon mesh for a waterway (river, stream, canal, ...).
## Returns null for degenerate ways. Callers should skip underground waterways
## (tunnel=culvert, etc.) before invoking this.
func build_waterway(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	# Subdivide long segments so the ribbon follows the terrain.
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	var waterway_type: String = way.tags.get("waterway", "stream")
	var width: float = WATERWAY_WIDTHS.get(waterway_type, WATERWAY_DEFAULT_WIDTH)
	if way.tags.has("width"):
		var explicit_width: float = way.tags["width"].to_float()
		if explicit_width > 0.0:
			width = explicit_width

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Waterway_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = WATERWAY_COLOR
	st.set_material(mat)

	var edges := _build_ribbon_edges(points, width / 2.0, WATERWAY_Y)
	var left_edge: Array = edges["left"]
	var right_edge: Array = edges["right"]

	for i: int in range(points.size() - 1):
		var v0: Vector3 = left_edge[i]
		var v1: Vector3 = right_edge[i]
		var v2: Vector3 = right_edge[i + 1]
		var v3: Vector3 = left_edge[i + 1]
		st.set_normal(Vector3.UP); st.add_vertex(v0)
		st.set_normal(Vector3.UP); st.add_vertex(v2)
		st.set_normal(Vector3.UP); st.add_vertex(v1)
		st.set_normal(Vector3.UP); st.add_vertex(v0)
		st.set_normal(Vector3.UP); st.add_vertex(v3)
		st.set_normal(Vector3.UP); st.add_vertex(v2)

	mesh_instance.mesh = st.commit()
	return mesh_instance

# ─── Railways ────────────────────────────────────────────────────────────────

const RAILWAY_WIDTHS := {
	"rail": 2.6,        # standard-gauge track bed (sleeper length ~2.6 m)
	"light_rail": 2.6,
	"subway": 2.6,
	"tram": 2.2,
	"narrow_gauge": 1.8,
	"monorail": 1.2,
	"funicular": 2.2,
	"disused": 2.6,
	"preserved": 2.6,
}
const RAILWAY_DEFAULT_WIDTH := 2.6
const RAILWAY_BED_COLOR := Color(0.32, 0.28, 0.25)   # ballast / sleepers brown-grey
const RAILWAY_RAIL_COLOR := Color(0.6, 0.6, 0.62)    # steel rails
const RAILWAY_BED_Y := 0.03                          # ballast just above ground/road skin
const RAILWAY_RAIL_Y := 0.06                          # rails sit on top of the bed
const RAILWAY_RAIL_HALF := 0.07                       # half-width of each rail strip
const RAILWAY_GAUGE_FRAC := 0.55                      # rail spacing as fraction of bed width

## Builds a track-bed ribbon for a railway way (rail, tram, light_rail, ...),
## plus two thin steel rail strips on top so tracks read as rails rather than a
## plain road. Underground/elevated handling is left to the caller; returns null
## for degenerate ways.
func build_railway(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	# Subdivide long segments so the ribbon follows the terrain.
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	var railway_type: String = way.tags.get("railway", "rail")
	var width: float = RAILWAY_WIDTHS.get(railway_type, RAILWAY_DEFAULT_WIDTH)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Railway_%d" % way.id

	# Ballast bed.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bed_mat := StandardMaterial3D.new()
	bed_mat.albedo_color = RAILWAY_BED_COLOR
	st.set_material(bed_mat)

	var bed := _build_ribbon_edges(points, width / 2.0, RAILWAY_BED_Y)
	var bed_left: Array = bed["left"]
	var bed_right: Array = bed["right"]
	for i: int in range(points.size() - 1):
		_emit_ribbon_quad(st, bed_left[i], bed_right[i], bed_right[i + 1], bed_left[i + 1])

	# Two rail strips, offset symmetrically from the centerline.
	var rail_offset := (width * RAILWAY_GAUGE_FRAC) / 2.0
	var rail_st := SurfaceTool.new()
	rail_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = RAILWAY_RAIL_COLOR
	rail_mat.metallic = 0.6
	rail_st.set_material(rail_mat)

	_emit_offset_strip(rail_st, points, rail_offset, RAILWAY_RAIL_HALF, RAILWAY_RAIL_Y)
	_emit_offset_strip(rail_st, points, -rail_offset, RAILWAY_RAIL_HALF, RAILWAY_RAIL_Y)

	var mesh := st.commit()
	mesh = rail_st.commit(mesh)
	mesh_instance.mesh = mesh
	return mesh_instance

# ─── Ribbon helpers ──────────────────────────────────────────────────────────

## Emit the two triangles of a ribbon quad (left/right edges of a segment) with
## an upward normal. Shared by the railway bed and rail strips.
func _emit_ribbon_quad(st: SurfaceTool, l0: Vector3, r0: Vector3, r1: Vector3, l1: Vector3) -> void:
	st.set_normal(Vector3.UP); st.add_vertex(l0)
	st.set_normal(Vector3.UP); st.add_vertex(r1)
	st.set_normal(Vector3.UP); st.add_vertex(r0)
	st.set_normal(Vector3.UP); st.add_vertex(l0)
	st.set_normal(Vector3.UP); st.add_vertex(l1)
	st.set_normal(Vector3.UP); st.add_vertex(r1)

## Emit a narrow ribbon strip parallel to the centerline, displaced laterally by
## `center_offset` (signed) and `half` wide, at height `y`. Used for rail strips.
func _emit_offset_strip(st: SurfaceTool, points: PackedVector3Array, center_offset: float, half: float, y: float) -> void:
	var n_pts := points.size()
	var centerline: PackedVector3Array = PackedVector3Array()
	centerline.resize(n_pts)
	for i: int in range(n_pts):
		var lateral: Vector3
		if i == 0:
			var fwd := (points[1] - points[0]).normalized()
			lateral = Vector3(-fwd.z, 0.0, fwd.x).normalized()
		elif i == n_pts - 1:
			var fwd := (points[i] - points[i - 1]).normalized()
			lateral = Vector3(-fwd.z, 0.0, fwd.x).normalized()
		else:
			var fwd_prev := (points[i] - points[i - 1]).normalized()
			var fwd_next := (points[i + 1] - points[i]).normalized()
			var lat_prev := Vector3(-fwd_prev.z, 0.0, fwd_prev.x).normalized()
			var lat_next := Vector3(-fwd_next.z, 0.0, fwd_next.x).normalized()
			lateral = (lat_prev + lat_next)
			if lateral.length_squared() < 0.0001:
				lateral = lat_prev
			else:
				lateral = lateral.normalized()
		var pt := points[i]
		centerline[i] = Vector3(pt.x + lateral.x * center_offset, pt.y, pt.z + lateral.z * center_offset)
	var edges := _build_ribbon_edges(centerline, half, y)
	var left_edge: Array = edges["left"]
	var right_edge: Array = edges["right"]
	for i: int in range(n_pts - 1):
		_emit_ribbon_quad(st, left_edge[i], right_edge[i], right_edge[i + 1], left_edge[i + 1])

## Compute miter-joined left/right edge vertices for a polyline ribbon.
## Returns { "left": Array[Vector3], "right": Array[Vector3] }.
func _build_ribbon_edges(points: PackedVector3Array, half_w: float, y: float) -> Dictionary:
	var miter_limit := 2.0
	var n_pts := points.size()
	var left_edge: Array = []
	var right_edge: Array = []
	for i: int in range(n_pts):
		var pt := points[i]
		var offset: Vector3
		if i == 0:
			var fwd := (points[1] - points[0]).normalized()
			offset = Vector3(-fwd.z, 0.0, fwd.x).normalized() * half_w
		elif i == n_pts - 1:
			var fwd := (points[i] - points[i - 1]).normalized()
			offset = Vector3(-fwd.z, 0.0, fwd.x).normalized() * half_w
		else:
			var fwd_prev := (points[i] - points[i - 1]).normalized()
			var fwd_next := (points[i + 1] - points[i]).normalized()
			var lat_prev := Vector3(-fwd_prev.z, 0.0, fwd_prev.x).normalized()
			var lat_next := Vector3(-fwd_next.z, 0.0, fwd_next.x).normalized()
			var miter_dir := (lat_prev + lat_next)
			if miter_dir.length_squared() < 0.0001:
				miter_dir = lat_prev
			else:
				miter_dir = miter_dir.normalized()
			var d := miter_dir.dot(lat_prev)
			var miter_len := half_w
			if absf(d) > 0.0001:
				miter_len = half_w / d
			miter_len = clampf(miter_len, half_w, half_w * miter_limit)
			offset = miter_dir * miter_len
		# Drape each edge vertex on the terrain at its own XZ position (see
		# _edge_height); y is the small float offset above ground. Flat world
		# falls back to pt.y == 0.
		var lx := pt.x - offset.x
		var lz := pt.z - offset.z
		var rx := pt.x + offset.x
		var rz := pt.z + offset.z
		left_edge.append(Vector3(lx, _edge_height(lx, lz, pt.y) + y, lz))
		right_edge.append(Vector3(rx, _edge_height(rx, rz, pt.y) + y, rz))
	return { "left": left_edge, "right": right_edge }

func _add_sidewalk_segment(st: SurfaceTool, edge_start: Vector3, edge_end: Vector3, outward: Vector3, add_start_cap: bool, add_end_cap: bool) -> void:
	var offset := outward * SIDEWALK_WIDTH

	# Base each sidewalk on the terrain elevation of its edge (the edges carry
	# pt.y + ROAD_Y), so the curb follows the DEM. SIDEWALK_BASE_Y stays the
	# ground reference; subtract ROAD_Y to land on terrain, not the road skin.
	var start_base := edge_start.y - ROAD_Y + SIDEWALK_BASE_Y
	var end_base := edge_end.y - ROAD_Y + SIDEWALK_BASE_Y

	var inner_start_bottom := Vector3(edge_start.x, start_base, edge_start.z)
	var inner_end_bottom := Vector3(edge_end.x, end_base, edge_end.z)
	var inner_start_top := Vector3(edge_start.x, start_base + SIDEWALK_HEIGHT, edge_start.z)
	var inner_end_top := Vector3(edge_end.x, end_base + SIDEWALK_HEIGHT, edge_end.z)

	var outer_start := edge_start + offset
	var outer_end := edge_end + offset
	var outer_start_bottom := Vector3(outer_start.x, start_base, outer_start.z)
	var outer_end_bottom := Vector3(outer_end.x, end_base, outer_end.z)
	var outer_start_top := Vector3(outer_start.x, start_base + SIDEWALK_HEIGHT, outer_start.z)
	var outer_end_top := Vector3(outer_end.x, end_base + SIDEWALK_HEIGHT, outer_end.z)

	# Top face — should face up
	_add_quad_facing(st, inner_start_top, inner_end_top, outer_end_top, outer_start_top, Vector3.UP)
	# Outer wall — should face outward (away from road)
	_add_quad_facing(st, outer_start_bottom, outer_start_top, outer_end_top, outer_end_bottom, outward)
	# Inner wall — should face inward (toward road, i.e. -outward)
	_add_quad_facing(st, inner_start_bottom, inner_end_bottom, inner_end_top, inner_start_top, -outward)

	if add_start_cap:
		# Start cap — should face toward start (opposite of edge direction)
		var cap_normal := (edge_start - edge_end).normalized()
		_add_quad_facing(st, outer_start_bottom, inner_start_bottom, inner_start_top, outer_start_top, cap_normal)

	if add_end_cap:
		# End cap — should face toward end
		var cap_normal := (edge_end - edge_start).normalized()
		_add_quad_facing(st, inner_end_bottom, outer_end_bottom, outer_end_top, inner_end_top, cap_normal)

func _add_quad_facing(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, desired_normal: Vector3) -> void:
	PolygonUtils.add_quad_facing(st, a, b, c, d, desired_normal)
