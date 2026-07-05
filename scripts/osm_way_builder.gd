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

# Road width in meters based on highway type
const ROAD_WIDTHS := {
	"motorway": 12.0,
	"motorway_link": 6.0,
	"trunk": 10.0,
	"trunk_link": 5.0,
	"primary": 8.0,
	"primary_link": 4.5,
	"secondary": 7.0,
	"secondary_link": 4.0,
	"tertiary": 6.0,
	"tertiary_link": 3.5,
	"residential": 5.0,
	"living_street": 4.0,
	"service": 3.0,
	"unclassified": 5.0,
	"pedestrian": 3.0,
	"footway": 1.5,
	"cycleway": 2.0,
	"path": 1.0,
	"track": 3.0,
}

# Asphalt tones. Real asphalt is a dark, slightly warm neutral grey (~0.12–0.22),
# not the pale concrete-grey these used to be. Larger/faster roads read a touch
# darker and cooler (fresh tarmac); smaller residential/service roads are a hair
# lighter and warmer (aged, sun-bleached). Unpaved footway/path/track lean brown
# (dirt/gravel) and cycleways keep a faint blue tint.
const ROAD_COLORS := {
	"motorway": Color(0.15, 0.15, 0.17),
	"motorway_link": Color(0.15, 0.15, 0.17),
	"trunk": Color(0.16, 0.16, 0.17),
	"trunk_link": Color(0.16, 0.16, 0.17),
	"primary": Color(0.17, 0.17, 0.18),
	"primary_link": Color(0.17, 0.17, 0.18),
	"secondary": Color(0.18, 0.18, 0.19),
	"secondary_link": Color(0.18, 0.18, 0.19),
	"tertiary": Color(0.19, 0.19, 0.19),
	"tertiary_link": Color(0.19, 0.19, 0.19),
	"residential": Color(0.2, 0.2, 0.2),
	"living_street": Color(0.21, 0.205, 0.2),
	"service": Color(0.2, 0.195, 0.19),
	"footway": Color(0.32, 0.27, 0.21),
	"cycleway": Color(0.2, 0.22, 0.26),
	"path": Color(0.3, 0.25, 0.19),
	"pedestrian": Color(0.24, 0.23, 0.22),
}

const DEFAULT_WIDTH := 4.0
const DEFAULT_COLOR := Color(0.19, 0.19, 0.2)
const ROAD_Y := 0.02  # slightly above ground
const SIDEWALK_WIDTH := 1.5
const SIDEWALK_HEIGHT := 0.10
const SIDEWALK_COLOR := Color(0.68, 0.68, 0.66)
const SIDEWALK_BASE_Y := 0.0

func build_road(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

	if points.size() < 2:
		return null

	var highway_type: String = way.tags.get("highway", "unclassified")
	var color: Color = ROAD_COLORS.get(highway_type, DEFAULT_COLOR)

	# Lane layout parsed from OSM tags (lanes, lanes:forward/backward, oneway).
	# Drives both the procedural markings AND, below, the carriageway width when
	# it isn't given explicitly. lane_count already carries a sensible per-type
	# default (2 for two-way, 1 for one-way) when no lanes tag is present.
	var lane_spec := RoadLaneSpec.from_tags(highway_type, way.tags)

	var width: float = _road_width(highway_type, way.tags, lane_spec)

	# Roads are kept FULL-LENGTH: where ways share a node they overlap and merge
	# into one connected surface (the Mapnik model), rather than being trimmed
	# back — which left gaps even where roads simply connect. The z-fighting that
	# coplanar overlap would otherwise cause is handled at DRAW time instead: the
	# asphalt material does not write depth and carries a per-class
	# render_priority (RoadMaterialFactory), so a bigger road paints on top of a
	# smaller one at a junction, exactly like Mapnik draws casings then fills.

	# Lane attachment: when this narrow (single-lane) road ends at the terminal
	# endpoint of a wider (multi-lane) road, nudge its endpoint sideways so its
	# centreline lines up with one of that road's *lane centres* instead of its
	# middle. Two branches meeting the same wide end take the two different lanes.
	# Applied to the RAW centreline before subdivision/clipping so the shift flows
	# through UVs, markings and terrain-conforming untouched.
	points = _attach_endpoints_to_lanes(points, way, lane_spec, osm_data)

	# Subdivide long segments so the ribbon follows the terrain.
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	# Transverse markings from OSM nodes ON this way (zebra crossings, stop and
	# give-way lines). Built from the RAW node polyline so each marking's
	# metres-along matches the ribbon UV.x (terrain subdivision below only adds
	# collinear points and preserves path length).
	var marking_spec := RoadMarkingSpec.from_way(way.node_ids, osm_data.nodes)
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

	var sidewalk_mat := StandardMaterial3D.new()
	sidewalk_mat.albedo_color = SIDEWALK_COLOR
	sidewalk_st.set_material(sidewalk_mat)

	var sidewalk_sides := _get_sidewalk_sides(way.tags)
	var has_left_sidewalk: bool = sidewalk_sides["left"]
	var has_right_sidewalk: bool = sidewalk_sides["right"]

	# Whether to conform the surface to the terrain triangulation. Even with the
	# edges draped, a flat quad spanning a cell sits below terrain folds crossing
	# it (a "hill in the middle of the street"). When a DEM is present we clip
	# each segment quad against the terrain mesh so the surface coincides with
	# the ground exactly; flat worlds keep the cheap single quad.
	var conform := height_provider != null and height_provider.is_ready() \
		and terrain_grid_step > 0.0

	# Clip the centreline to the current tile (plus a small margin) so a way that
	# spans many tiles only builds its in-tile portion here instead of its whole
	# length in every tile it touches. Marking UVs are metres-from-way-start, so
	# each clipped part carries the along-distance of its FIRST point (found in
	# along_at by nearest original point) to keep markings aligned. When no clip
	# rect is set (flat/whole-map path) the single full polyline is used as-is.
	var parts: Array = [points]
	if tile_clip_rect != null:
		parts = PolygonUtils.clip_polyline_to_rect(points, tile_clip_rect, CLIP_MARGIN)
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
	return mesh_instance


## Carriageway width (metres, excluding sidewalks) for a road way. Precedence:
##
##   1. An explicit `width` tag always wins (it is the real measured width).
##   2. Otherwise the width scales with the lane count: width = lanes × per-lane,
##      where the per-lane width is the type's default treated as a nominal
##      TWO-lane carriageway (default / 2), floored at LANE_WIDTH so lanes never
##      get unrealistically thin. This is the key fix for one-way single-lane
##      roads: a `oneway=yes` tertiary with no `lanes` tag is one lane, so it now
##      renders at ~half the width of the two-lane tertiary it branches from,
##      instead of inheriting the (two-lane) type default and looking just as
##      wide. Multi-lane roads still widen to read as wide as they really are.
##   3. Unmarked/soft ways (footway, path, cycleway, track, pedestrian) are NOT
##      carriageways and keep their literal type default regardless of any
##      (defaulted) lane count.
func _road_width(highway_type: String, tags: Dictionary, lane_spec: RoadLaneSpec) -> float:
	# Explicit width tag takes highest precedence (width excluding sidewalk).
	if tags.has("width"):
		var explicit_width: float = String(tags["width"]).to_float()
		if explicit_width > 0.0:
			return explicit_width

	var default_width: float = ROAD_WIDTHS.get(highway_type, DEFAULT_WIDTH)

	# Non-carriageway ways (paths, footways, …) aren't lane-based; keep default.
	if lane_spec == null or not lane_spec.marked:
		return default_width

	# Per-lane width: half the type default (which assumes a ~2-lane road),
	# but never thinner than a real lane. Width is then lanes × that.
	var per_lane: float = maxf(default_width * 0.5, RoadLaneSpec.LANE_WIDTH)
	return lane_spec.lane_count * per_lane


## Distance (metres) over which an endpoint lane-attachment offset tapers back to
## the road's true centreline, so only the tip near the junction is nudged.
const LANE_ATTACH_TAPER := 8.0


## Shift a single-lane road's endpoint(s) sideways so they meet a *lane centre* of
## a wider road they terminate against, rather than that road's middle. Returns a
## new centreline (a copy) with a tapered lateral offset baked into the tip
## point(s); returns `points` unchanged when no attachment applies.
##
## Only the way's two terminal nodes are considered (a T- or Y-join at a wide
## road's END). The offset is perpendicular to the WIDE road's direction at the
## shared node and equal to the wide road's lane-centre position; when several
## single-lane branches share the same wide endpoint they are handed distinct
## lanes deterministically (sorted by way id) so two branches take the two lanes.
func _attach_endpoints_to_lanes(
		points: PackedVector3Array, way: OSMParser.OSMWay,
		lane_spec: RoadLaneSpec, osm_data: OSMParser.OSMData) -> PackedVector3Array:
	# Only single-lane branches attach; wider roads keep their own centreline.
	if lane_spec == null or lane_spec.lane_count != 1:
		return points
	if way.node_ids.size() < 2 or points.size() < 2:
		return points

	var start_node: int = way.node_ids[0]
	var end_node: int = way.node_ids[way.node_ids.size() - 1]

	var start_off := _lane_attach_offset(start_node, way, osm_data)
	var end_off := _lane_attach_offset(end_node, way, osm_data)
	if start_off == Vector3.ZERO and end_off == Vector3.ZERO:
		return points

	# Bake a tapered offset into a copy: full at the tip, zero past the taper
	# length (measured along the polyline from that end). If the road is shorter
	# than 2× the taper the two ends share the budget by their along-fraction.
	var along := _cumulative_along(points)
	var total: float = along[along.size() - 1]
	if total <= 0.0001:
		return points

	var out := PackedVector3Array()
	out.resize(points.size())
	for i: int in range(points.size()):
		var p := points[i]
		var d_start := along[i]
		var d_end := total - along[i]
		var w_start := _taper_weight(d_start)
		var w_end := _taper_weight(d_end)
		var off := start_off * w_start + end_off * w_end
		out[i] = Vector3(p.x + off.x, p.y, p.z + off.z)
	return out


## Linear taper weight: 1 at the endpoint, falling to 0 at LANE_ATTACH_TAPER m.
func _taper_weight(dist_from_end: float) -> float:
	if dist_from_end >= LANE_ATTACH_TAPER:
		return 0.0
	return 1.0 - dist_from_end / LANE_ATTACH_TAPER


## Lateral offset (XZ, y=0) to move `way`'s endpoint at `node_id` onto a lane
## centre of a wider road that TERMINATES at that same node. Vector3.ZERO when
## there is no such single wide anchor (so no attachment happens).
func _lane_attach_offset(
		node_id: int, way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> Vector3:
	if not osm_data.nodes.has(node_id):
		return Vector3.ZERO

	# Find the wide anchor: a road (!= way) that has node_id as its OWN terminal
	# endpoint and carries 2+ lanes. If there isn't exactly one, don't attach —
	# an ambiguous junction (two wide roads, or a mid-way crossing) is left alone.
	var anchor: OSMParser.OSMWay = null
	var branches: Array[OSMParser.OSMWay] = []
	for other: OSMParser.OSMWay in osm_data.ways.values():
		if other == way or not RoadHandler.is_road(other):
			continue
		if other.node_ids.size() < 2:
			continue
		var o_start: int = other.node_ids[0]
		var o_end: int = other.node_ids[other.node_ids.size() - 1]
		var terminal := (o_start == node_id or o_end == node_id)
		if not terminal:
			continue
		var o_lanes := _way_lane_count(other)
		if o_lanes >= 2:
			if anchor != null:
				return Vector3.ZERO  # more than one wide anchor → ambiguous
			anchor = other
		elif o_lanes == 1:
			branches.append(other)
	if anchor == null:
		return Vector3.ZERO

	# This way is itself a single-lane branch at the node.
	branches.append(way)

	# Wide road direction AT the shared node, pointing into the anchor (away from
	# the node), and the right-hand lateral used to place lane centres.
	var anchor_dir := _anchor_dir_at(anchor, node_id, osm_data)
	if anchor_dir == Vector3.ZERO:
		return Vector3.ZERO
	var lateral := Vector3(-anchor_dir.z, 0.0, anchor_dir.x).normalized()

	var anchor_lanes := _way_lane_count(anchor)
	var anchor_spec := RoadLaneSpec.from_tags(
		anchor.tags.get("highway", "unclassified"), anchor.tags)
	var anchor_width := _road_width(
		anchor.tags.get("highway", "unclassified"), anchor.tags, anchor_spec)
	var lane_w: float = anchor_width / float(anchor_lanes)

	# Assign each branch to a distinct lane. Preference is which side the branch
	# leans relative to the anchor's lateral (so a branch coming in from the right
	# takes a right-hand lane — no crossover); ties and overflow fall back to a
	# stable id order. Greedy in preference order, filling nearest free lane.
	var lane_k := _assign_branch_lane(
		branches, way, node_id, lateral, anchor_lanes, osm_data)

	# Lane centres, left→right: (k + 0.5 - lanes/2) * lane_w for k in [0, lanes).
	var lane_center := (lane_k + 0.5 - anchor_lanes / 2.0) * lane_w
	return lateral * lane_center


## Deterministically hand each single-lane branch at a shared node a distinct
## lane of the wide anchor (0 = leftmost). Branches are ranked by how far right
## they lean relative to `lateral` (their outgoing direction · lateral), so the
## left-leaning branch takes a left lane and the right-leaning one a right lane;
## id order breaks ties. Returns the lane index assigned to `way`, capped to
## [0, anchor_lanes).
func _assign_branch_lane(
		branches: Array[OSMParser.OSMWay], way: OSMParser.OSMWay,
		node_id: int, lateral: Vector3, anchor_lanes: int,
		osm_data: OSMParser.OSMData) -> int:
	# Rank: left-leaning (most negative lateral projection) first → lowest lane.
	var ranked := branches.duplicate()
	ranked.sort_custom(func(a: OSMParser.OSMWay, b: OSMParser.OSMWay) -> bool:
		var pa := _branch_side(a, node_id, lateral, osm_data)
		var pb := _branch_side(b, node_id, lateral, osm_data)
		if is_equal_approx(pa, pb):
			return a.id < b.id
		return pa < pb)
	var idx := ranked.find(way)
	if idx < 0:
		idx = 0
	return clampi(idx, 0, anchor_lanes - 1)


## Signed lean of a branch relative to the anchor lateral at the shared node:
## the branch's outgoing direction (from the node into the branch) projected onto
## `lateral`. Negative = leans left, positive = leans right.
func _branch_side(
		branch: OSMParser.OSMWay, node_id: int, lateral: Vector3,
		osm_data: OSMParser.OSMData) -> float:
	var dir := _anchor_dir_at(branch, node_id, osm_data)
	if dir == Vector3.ZERO:
		return 0.0
	return dir.dot(lateral)


## Lane count for any road way (defaults included), reusing RoadLaneSpec so the
## branch/anchor classification matches the markings and width logic exactly.
func _way_lane_count(way: OSMParser.OSMWay) -> int:
	var ht: String = way.tags.get("highway", "unclassified")
	return RoadLaneSpec.from_tags(ht, way.tags).lane_count


## Unit direction of `anchor` at its terminal node `node_id`, pointing from the
## node toward the road's interior (so the lateral is consistent). Vector3.ZERO
## for a degenerate anchor.
func _anchor_dir_at(
		anchor: OSMParser.OSMWay, node_id: int, osm_data: OSMParser.OSMData) -> Vector3:
	var n := anchor.node_ids.size()
	if not osm_data.nodes.has(node_id):
		return Vector3.ZERO
	var neighbor_id: int
	if anchor.node_ids[0] == node_id:
		neighbor_id = anchor.node_ids[1]
	elif anchor.node_ids[n - 1] == node_id:
		neighbor_id = anchor.node_ids[n - 2]
	else:
		return Vector3.ZERO
	if not osm_data.nodes.has(neighbor_id):
		return Vector3.ZERO
	var here: Vector3 = osm_data.nodes[node_id].local_pos
	var there: Vector3 = osm_data.nodes[neighbor_id].local_pos
	var d := Vector3(there.x - here.x, 0.0, there.z - here.z)
	if d.length_squared() < 0.0001:
		return Vector3.ZERO
	return d.normalized()


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

		if has_left_sidewalk:
			var center := Vector3(part_pts[i].x, left_edge[i].y, part_pts[i].z)
			var outward: Vector3 = (center - left_edge[i]).normalized()
			_add_sidewalk_segment(sidewalk_st, left_edge[i], left_edge[i + 1], -outward, i == 0, i == n_pts - 2)

		if has_right_sidewalk:
			var center := Vector3(part_pts[i].x, right_edge[i].y, part_pts[i].z)
			var outward: Vector3 = (right_edge[i] - center).normalized()
			_add_sidewalk_segment(sidewalk_st, right_edge[i], right_edge[i + 1], outward, i == 0, i == n_pts - 2)


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

func _get_sidewalk_sides(tags: Dictionary) -> Dictionary:
	var left := false
	var right := false

	if tags.has("sidewalk"):
		var sidewalk_tag := String(tags["sidewalk"])
		if sidewalk_tag == "separate":
			left = true
			right = true
		elif sidewalk_tag == "both":
			left = true
			right = true
		elif sidewalk_tag == "left":
			left = true
		elif sidewalk_tag == "right":
			right = true
		elif sidewalk_tag == "no":
			left = false
			right = false

	if tags.has("sidewalk:both"):
		var sidewalk_both_tag := String(tags["sidewalk:both"])
		if sidewalk_both_tag == "separate":
			left = true
			right = true
		elif sidewalk_both_tag == "no":
			left = false
			right = false

	if tags.has("sidewalk:left"):
		left = _is_rendered_sidewalk_value(String(tags["sidewalk:left"]))

	if tags.has("sidewalk:right"):
		right = _is_rendered_sidewalk_value(String(tags["sidewalk:right"]))

	return {
		"left": left,
		"right": right,
	}

func _is_rendered_sidewalk_value(value: String) -> bool:
	return value == "separate"

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
