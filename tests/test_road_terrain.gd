extends GdUnitTestSuite

## Unit tests for road-mesh vertex elevation on sloped terrain.
##
## Roads are draped onto the terrain by sampling the HeightProvider at each
## centerline vertex, but the left/right edge vertices are offset purely in the
## XZ plane — their Y is copied from the center point. On a slope that runs
## *across* the road (perpendicular to the road direction), one edge floats
## above the terrain while the opposite edge sinks below it. This test pins
## that known defect so it becomes a regression gate for a future fix.

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMWayBuilder := preload("res://scripts/osm_way_builder.gd")
const HeightProvider := preload("res://scripts/height_provider.gd")

# ─── Fixture constants ───────────────────────────────────────────────────────

## Heightmap: 16×16 texels, elevation increases linearly west→east (left→right).
## A road running north→south (constant X) will have a cross-slope: the left
## edge is downhill, the right edge is uphill (or vice versa), and the center
## sits on the sampled terrain.
const IMG_W := 16
const IMG_H := 16
const MIN_LON := 8.0
const MIN_LAT := 49.0
const MAX_LON := 8.02
const MAX_LAT := 49.02
const MIN_ELEV := 100.0
const MAX_ELEV := 200.0

## Road parameters: a "residential" road is 5 m wide, so the edge is 2.5 m from
## center. On a 100 m elevation range over ~1.5 km of longitude that is a
## nontrivial cross-slope.
const ROAD_TYPE := "residential"
const ROAD_WIDTH: float = 5.0   # must match ROAD_WIDTHS["residential"]
const ROAD_Y: float = 0.02      # must match OSMWayBuilder.ROAD_Y

## Terrain mesh grid: tile_size and subdivisions that match the heightmap so
## sample_mesh_height reproduces the triangulated surface exactly.
const TILE_SIZE: float = 256.0
const TERRAIN_SUBS: int = 32

## ─── Interior-piercing (ridge) fixture ──────────────────────────────────────
##
## To make a hill crest that is sharp at ROAD scale (a few metres), the ridge
## fixture covers a TINY geographic patch (~44 m) with a 64-texel heightmap, so
## one texel spans ~0.7 m. A triangular ridge in that map therefore rises ~1 m
## over the 2.5 m from the road centerline to its edge — a real bump between the
## road's left/right sample points, not a kilometre-wide swell the road can't
## notice.
const RIDGE_IMG := 64
const RIDGE_MIN_LON := 8.0
const RIDGE_MIN_LAT := 49.0
const RIDGE_MAX_LON := 8.0006   # ~44 m of longitude
const RIDGE_MAX_LAT := 49.0006
const RIDGE_MIN_ELEV := 100.0
const RIDGE_MAX_ELEV := 110.0

## Fine terrain mesh grid for the ridge test: TILE_SIZE / RIDGE_SUBS = 1 m cells,
## smaller than the 5 m road, so the terrain mesh has vertices BETWEEN the road's
## left and right edges. A crest on one of those interior vertices pokes up
## through a flat road quad — the case a per-vertex check cannot catch, and the
## one the terrain-conforming clip must eliminate.
const RIDGE_SUBS: int = 256

var _tmp_png := "user://_test_road_terrain_dem.png"
var _tmp_json := "user://_test_road_terrain_dem.json"


# ─── Lifecycle ───────────────────────────────────────────────────────────────

func before() -> void:
	_write_fixture()


func after() -> void:
	_cleanup()


# ─── Fixture helpers ─────────────────────────────────────────────────────────

## Build a heightmap whose elevation increases linearly from west to east.
## Column x maps to norm = x / (IMG_W - 1), so:
##   west  edge → MIN_ELEV
##   east  edge → MAX_ELEV
## Rows are constant (no north–south gradient).
func _write_fixture() -> void:
	var img := Image.create(IMG_W, IMG_H, false, Image.FORMAT_RF)
	for y: int in range(IMG_H):
		for x: int in range(IMG_W):
			var norm := float(x) / float(IMG_W - 1)
			img.set_pixel(x, y, Color(norm, norm, norm))
	img.save_png(_tmp_png)

	var meta := {
		"min_lon": MIN_LON, "min_lat": MIN_LAT,
		"max_lon": MAX_LON, "max_lat": MAX_LAT,
		"width": IMG_W, "height": IMG_H,
		"min_elev": MIN_ELEV, "max_elev": MAX_ELEV,
		"source": "test east-west gradient",
	}
	var f := FileAccess.open(_tmp_json, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()


## Build a heightmap with a triangular RIDGE whose crest runs north–south along
## the center longitude (the road centerline). Elevation peaks at the middle
## column and falls off linearly toward the east and west edges:
##   center column → MAX_ELEV   (crest, under the road centerline)
##   east/west edge → MIN_ELEV   (valley floor)
## A north–south road laid on this crest has both its left and right edges in
## lower terrain, while the terrain bulges UP through the middle of the flat
## road quad — the "hill in the middle of the street" case.
func _write_ridge_fixture() -> void:
	var img := Image.create(RIDGE_IMG, RIDGE_IMG, false, Image.FORMAT_RF)
	var mid := float(RIDGE_IMG - 1) / 2.0
	for y: int in range(RIDGE_IMG):
		for x: int in range(RIDGE_IMG):
			# Triangular profile: 1.0 at the center column, 0.0 at the edges.
			var dist := absf(float(x) - mid) / mid
			var norm := 1.0 - dist
			img.set_pixel(x, y, Color(norm, norm, norm))
	img.save_png(_tmp_png)

	var meta := {
		"min_lon": RIDGE_MIN_LON, "min_lat": RIDGE_MIN_LAT,
		"max_lon": RIDGE_MAX_LON, "max_lat": RIDGE_MAX_LAT,
		"width": RIDGE_IMG, "height": RIDGE_IMG,
		"min_elev": RIDGE_MIN_ELEV, "max_elev": RIDGE_MAX_ELEV,
		"source": "test north-south ridge",
	}
	var f := FileAccess.open(_tmp_json, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()


func _cleanup() -> void:
	for p: String in [_tmp_png, _tmp_json]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _make_height_provider(
		subdivisions: int = TERRAIN_SUBS,
		ref_lat: float = (MIN_LAT + MAX_LAT) / 2.0,
		ref_lon: float = (MIN_LON + MAX_LON) / 2.0,
) -> HeightProvider:
	var hp := HeightProvider.new()
	var ok := hp.load_from_files(ref_lat, ref_lon, _tmp_png, _tmp_json)
	assert_bool(ok) \
		.override_failure_message("HeightProvider loads the test DEM fixture").is_true()
	hp.set_mesh_grid(TILE_SIZE, subdivisions)
	return hp


## Build a minimal OSMData with two nodes forming a north→south road segment.
## The road runs at a fixed longitude (constant X). lat_span sets how far the
## road reaches north/south of center (degrees); keep it inside the heightmap
## bounds so the road stays on the mapped terrain.
func _make_road_osm_data(
		hp: HeightProvider,
		ref_lat: float = (MIN_LAT + MAX_LAT) / 2.0,
		ref_lon: float = (MIN_LON + MAX_LON) / 2.0,
		lat_span: float = 0.002,
) -> OSMParser.OSMData:
	var m_per_deg_lat := 111132.0
	var m_per_deg_lon := 111132.0 * cos(deg_to_rad(ref_lat))

	# Place two nodes at the dataset center longitude, offset north/south.
	var lat_a := ref_lat + lat_span   # slightly north
	var lat_b := ref_lat - lat_span   # slightly south
	var lon := ref_lon                # center longitude → middle of slope

	var node_a := OSMParser.OSMNode.new()
	node_a.id = 1
	node_a.lat = lat_a
	node_a.lon = lon
	node_a.local_pos = Vector3(
		(lon - ref_lon) * m_per_deg_lon,
		hp.sample_local_xz((lon - ref_lon) * m_per_deg_lon,
			-(lat_a - ref_lat) * m_per_deg_lat),
		-(lat_a - ref_lat) * m_per_deg_lat,
	)

	var node_b := OSMParser.OSMNode.new()
	node_b.id = 2
	node_b.lat = lat_b
	node_b.lon = lon
	node_b.local_pos = Vector3(
		(lon - ref_lon) * m_per_deg_lon,
		hp.sample_local_xz((lon - ref_lon) * m_per_deg_lon,
			-(lat_b - ref_lat) * m_per_deg_lat),
		-(lat_b - ref_lat) * m_per_deg_lat,
	)

	var data := OSMParser.OSMData.new()
	data.nodes = { 1: node_a, 2: node_b }
	data.center_lat = ref_lat
	data.center_lon = ref_lon
	data.height_provider = hp
	return data


func _make_road_way() -> OSMParser.OSMWay:
	var way := OSMParser.OSMWay.new()
	way.id = 999
	way.node_ids = [1, 2] as Array[int]
	way.tags = { "highway": ROAD_TYPE, "sidewalk": "no" }
	return way


# ─── Tests ───────────────────────────────────────────────────────────────────

## On a cross-slope, every road-mesh vertex must sit at or above the terrain
## surface at that vertex's XZ position. The current implementation copies the
## centerline elevation to left/right edges without re-sampling, so edge
## vertices on the downhill side float above the terrain (OK) while edge
## vertices on the uphill side sink below the terrain (defect).
##
## This test is expected to FAIL until the road builder re-samples each edge
## vertex against the terrain.
func test_road_edge_vertices_not_below_terrain() -> void:
	var hp := _make_height_provider()
	var osm_data := _make_road_osm_data(hp)
	var way := _make_road_way()

	var builder := OSMWayBuilder.new()
	builder.height_provider = hp
	builder.terrain_grid_step = TILE_SIZE / float(max(1, TERRAIN_SUBS))

	var mesh_inst := builder.build_road(way, osm_data)
	assert_object(mesh_inst) \
		.override_failure_message("build_road produces a MeshInstance3D").is_not_null()
	if mesh_inst == null:
		return

	# Extract all unique vertices from the committed road mesh surface 0.
	var mdt := MeshDataTool.new()
	var err := mdt.create_from_surface(mesh_inst.mesh, 0)
	assert_int(err) \
		.override_failure_message("MeshDataTool reads the road mesh surface") \
		.is_equal(OK)
	if err != OK:
		return

	var worst_penetration: float = 0.0
	var worst_vertex := Vector3.ZERO
	var worst_terrain_y: float = 0.0
	var vertex_count := mdt.get_vertex_count()

	for vi: int in range(vertex_count):
		var v := mdt.get_vertex(vi)
		# Terrain height at the vertex's XZ position, on the triangulated mesh.
		var terrain_y := hp.sample_mesh_height(v.x, v.z)
		# The road should sit ROAD_Y above the terrain, but at minimum it must
		# never be below the raw terrain surface.
		var penetration := terrain_y - v.y   # positive = vertex is below terrain
		if penetration > worst_penetration:
			worst_penetration = penetration
			worst_vertex = v
			worst_terrain_y = terrain_y

	var msg := (
		"No road vertex should sit below the terrain surface. " +
		"Worst penetration: %s m at vertex (%s, %s, %s) " +
		"where terrain is %s m. The road builder copies centerline " +
		"elevation to edge vertices instead of re-sampling each edge " +
		"against the terrain."
	) % [
		"%.4f" % worst_penetration,
		"%.2f" % worst_vertex.x,
		"%.4f" % worst_vertex.y,
		"%.2f" % worst_vertex.z,
		"%.4f" % worst_terrain_y,
	]
	mesh_inst.free()

	assert_float(worst_penetration) \
		.override_failure_message(msg) \
		.is_less_equal(0.0)


## The terrain can poke UP through the middle of a road even when both edges are
## correctly draped: the road surface is a flat quad spanning its full width, so
## a hill crest BETWEEN the sampled edges (e.g. a ridge running along the road,
## or terrain finer than the road is wide) pierces the road from below.
##
## This samples the interior of every road triangle (not just its corner
## vertices) and asserts the terrain never rises above the interpolated road
## surface there. The fix is to conform the road surface to the terrain
## triangulation — clip each segment quad against the terrain mesh and drape the
## pieces — so the ground cannot pierce through between the edges.
func test_terrain_does_not_pierce_road_interior() -> void:
	# A ridge whose crest runs along the road centerline: edges sit in lower
	# terrain, the crest bulges up through the middle of the flat road quad.
	_write_ridge_fixture()
	var ridge_ref_lat := (RIDGE_MIN_LAT + RIDGE_MAX_LAT) / 2.0
	var ridge_ref_lon := (RIDGE_MIN_LON + RIDGE_MAX_LON) / 2.0
	# Fine mesh grid (1 m cells) so the terrain is sampled BETWEEN the road
	# edges, not just at them. This is what exposes mid-road piercing.
	var hp := _make_height_provider(RIDGE_SUBS, ridge_ref_lat, ridge_ref_lon)
	# Road spans ±0.0002° (~22 m) north/south, well inside the ~44 m map.
	var osm_data := _make_road_osm_data(hp, ridge_ref_lat, ridge_ref_lon, 0.0002)
	var way := _make_road_way()

	var builder := OSMWayBuilder.new()
	builder.height_provider = hp
	builder.terrain_grid_step = TILE_SIZE / float(max(1, RIDGE_SUBS))

	var mesh_inst := builder.build_road(way, osm_data)
	assert_object(mesh_inst) \
		.override_failure_message("build_road produces a MeshInstance3D").is_not_null()
	if mesh_inst == null:
		return

	var mdt := MeshDataTool.new()
	var err := mdt.create_from_surface(mesh_inst.mesh, 0)
	assert_int(err) \
		.override_failure_message("MeshDataTool reads the road mesh surface") \
		.is_equal(OK)
	if err != OK:
		mesh_inst.free()
		return

	# Walk every triangle face and sample its interior on a barycentric grid.
	# At each sample, the road surface height is the barycentric interpolation
	# of the triangle's three vertex Ys; the terrain height is sample_mesh_height
	# at the same XZ. Penetration > 0 means terrain pierces up through the road.
	const SAMPLES_PER_EDGE := 8   # barycentric resolution across each triangle
	var worst_penetration: float = 0.0
	var worst_xz := Vector2.ZERO
	var worst_road_y: float = 0.0
	var worst_terrain_y: float = 0.0

	for fi: int in range(mdt.get_face_count()):
		var a := mdt.get_vertex(mdt.get_face_vertex(fi, 0))
		var b := mdt.get_vertex(mdt.get_face_vertex(fi, 1))
		var c := mdt.get_vertex(mdt.get_face_vertex(fi, 2))
		for i: int in range(SAMPLES_PER_EDGE + 1):
			for j: int in range(SAMPLES_PER_EDGE + 1 - i):
				var u := float(i) / float(SAMPLES_PER_EDGE)
				var v := float(j) / float(SAMPLES_PER_EDGE)
				var w := 1.0 - u - v
				# Point on the triangle and its interpolated road surface height.
				var px := a.x * w + b.x * u + c.x * v
				var pz := a.z * w + b.z * u + c.z * v
				var road_y := a.y * w + b.y * u + c.y * v
				var terrain_y := hp.sample_mesh_height(px, pz)
				var penetration := terrain_y - road_y
				if penetration > worst_penetration:
					worst_penetration = penetration
					worst_xz = Vector2(px, pz)
					worst_road_y = road_y
					worst_terrain_y = terrain_y

	mesh_inst.free()

	var msg := (
		"Terrain must not pierce up through the road surface. " +
		"Worst penetration: %s m at XZ (%s, %s) where the road surface is " +
		"%s m but the terrain rises to %s m. The road surface must conform to " +
		"the terrain triangulation (clip each segment quad against the terrain " +
		"mesh) so the ground cannot poke through between the edges."
	) % [
		"%.4f" % worst_penetration,
		"%.2f" % worst_xz.x,
		"%.2f" % worst_xz.y,
		"%.4f" % worst_road_y,
		"%.4f" % worst_terrain_y,
	]
	# Allow a sub-millimetre tolerance for float error when sampling exactly on a
	# terrain triangle edge; the conforming road must otherwise never dip below.
	assert_float(worst_penetration) \
		.override_failure_message(msg) \
		.is_less_equal(0.001)


# ─── Regression: production-scale road over folded terrain ───────────────────

## Worst terrain penetration (meters, positive = ground above road) sampled over
## the interior of every triangle in a road mesh, against the given height field.
## Returns a dict {pen, xz, road_y, terrain_y} describing the deepest sample.
func _worst_road_penetration(mesh: Mesh, hp: HeightProvider) -> Dictionary:
	var mdt := MeshDataTool.new()
	if mdt.create_from_surface(mesh, 0) != OK:
		return {"pen": INF}
	var out := {"pen": 0.0, "xz": Vector2.ZERO, "road_y": 0.0, "terrain_y": 0.0}
	const SPE := 6
	for fi: int in range(mdt.get_face_count()):
		var a := mdt.get_vertex(mdt.get_face_vertex(fi, 0))
		var b := mdt.get_vertex(mdt.get_face_vertex(fi, 1))
		var c := mdt.get_vertex(mdt.get_face_vertex(fi, 2))
		for i: int in range(SPE + 1):
			for j: int in range(SPE + 1 - i):
				var u := float(i) / float(SPE)
				var v := float(j) / float(SPE)
				var w := 1.0 - u - v
				var px := a.x * w + b.x * u + c.x * v
				var pz := a.z * w + b.z * u + c.z * v
				var road_y := a.y * w + b.y * u + c.y * v
				var pen := hp.sample_mesh_height(px, pz) - road_y
				if pen > out["pen"]:
					out["pen"] = pen
					out["xz"] = Vector2(px, pz)
					out["road_y"] = road_y
					out["terrain_y"] = hp.sample_mesh_height(px, pz)
	return out


## Heightmap fixture for the production-scale regression: a deterministic, hilly
## DEM (overlaid sine waves) over a ~1.1 km patch. The waves have ~30–60 m
## wavelengths, so on the 6.25 m production terrain grid every cell tilts a
## different way — exactly the "folded terrain finer than the road" condition
## that made the reported real-world road show terrain through it, but fully
## synthetic and stable. Uses the HILLY_* constants below.
const HILLY_IMG := 192
const HILLY_MIN_LON := 8.0
const HILLY_MIN_LAT := 49.0
const HILLY_MAX_LON := 8.016     # ~1.16 km of longitude
const HILLY_MAX_LAT := 49.0105   # ~1.16 km of latitude
const HILLY_MIN_ELEV := 100.0
const HILLY_MAX_ELEV := 140.0    # 40 m of relief

func _write_hilly_fixture() -> void:
	var img := Image.create(HILLY_IMG, HILLY_IMG, false, Image.FORMAT_RF)
	for y: int in range(HILLY_IMG):
		for x: int in range(HILLY_IMG):
			# Overlaid sine waves at a few frequencies/orientations → bumpy but
			# deterministic terrain with no axis-aligned symmetry.
			var fx := float(x) / float(HILLY_IMG - 1)
			var fy := float(y) / float(HILLY_IMG - 1)
			var h := 0.5
			h += 0.25 * sin(fx * TAU * 6.0 + 0.7)
			h += 0.25 * sin(fy * TAU * 5.0 + 1.9)
			h += 0.15 * sin((fx + fy) * TAU * 9.0)
			h += 0.10 * sin((fx - fy) * TAU * 11.0 + 0.3)
			var norm := clampf(0.5 + 0.5 * h - 0.25, 0.0, 1.0)
			img.set_pixel(x, y, Color(norm, norm, norm))
	img.save_png(_tmp_png)

	var meta := {
		"min_lon": HILLY_MIN_LON, "min_lat": HILLY_MIN_LAT,
		"max_lon": HILLY_MAX_LON, "max_lat": HILLY_MAX_LAT,
		"width": HILLY_IMG, "height": HILLY_IMG,
		"min_elev": HILLY_MIN_ELEV, "max_elev": HILLY_MAX_ELEV,
		"source": "test hilly",
	}
	var f := FileAccess.open(_tmp_json, FileAccess.WRITE)
	f.store_string(JSON.stringify(meta))
	f.close()


## Waypoints (degrees from the dataset center) forming a bent, oblique road, so
## its quads cross terrain grid lines and cell diagonals at angles — like a real
## street, not an axis-aligned synthetic one. Node ids are the 1-based index.
func _oblique_waypoints() -> Array:
	return [
		Vector2(-0.004, -0.003),
		Vector2(-0.0015, -0.0005),
		Vector2(0.001, 0.0008),
		Vector2(0.0035, 0.0026),
	]


## Build OSMData whose nodes (ids 1..N) are the oblique waypoints, draped on hp.
func _make_oblique_road_osm_data(
		hp: HeightProvider, ref_lat: float, ref_lon: float) -> OSMParser.OSMData:
	var m_per_deg_lat := 111132.0
	var m_per_deg_lon := 111132.0 * cos(deg_to_rad(ref_lat))
	var data := OSMParser.OSMData.new()
	var nid := 1
	for wp: Vector2 in _oblique_waypoints():
		var lon := ref_lon + wp.x
		var lat := ref_lat + wp.y
		var node := OSMParser.OSMNode.new()
		node.id = nid
		node.lat = lat
		node.lon = lon
		var wx := (lon - ref_lon) * m_per_deg_lon
		var wz := -(lat - ref_lat) * m_per_deg_lat
		node.local_pos = Vector3(wx, hp.sample_local_xz(wx, wz), wz)
		data.nodes[nid] = node
		nid += 1
	data.center_lat = ref_lat
	data.center_lon = ref_lon
	data.height_provider = hp
	return data


## The reproduction the user reported: a narrow road (narrower than a terrain
## cell) running obliquely over folded terrain, at the GAME's production tile
## settings (200 m tiles, 32 subdivisions → 6.25 m cells). Before the
## terrain-conforming fix the flat road quads dipped below the terrain folds and
## the ground showed through; afterwards the surface conforms exactly. Fully
## synthetic — no dependency on bundled map data.
func test_production_scale_road_not_pierced() -> void:
	_write_hilly_fixture()
	var ref_lat := (HILLY_MIN_LAT + HILLY_MAX_LAT) / 2.0
	var ref_lon := (HILLY_MIN_LON + HILLY_MAX_LON) / 2.0

	# Production tile parameters (mirror OSMTileManager defaults): 6.25 m cells.
	var prod_tile_size := 200.0
	var prod_subs := 32

	var hp := _make_height_provider(prod_subs, ref_lat, ref_lon)
	# Override the grid to the production tile size (helper uses TILE_SIZE).
	hp.set_mesh_grid(prod_tile_size, prod_subs)

	var data := _make_oblique_road_osm_data(hp, ref_lat, ref_lon)
	var node_ids: Array[int] = []
	for k: int in range(1, _oblique_waypoints().size() + 1):
		node_ids.append(k)
	var way := OSMParser.OSMWay.new()
	way.id = 4242
	way.node_ids = node_ids
	# 4 m wide — narrower than the 6.25 m terrain cell, like the reported road.
	way.tags = {"highway": "residential", "width": "4.0", "sidewalk": "no"}

	var builder := OSMWayBuilder.new()
	builder.height_provider = hp
	builder.terrain_grid_step = prod_tile_size / float(prod_subs)

	var mesh_inst := builder.build_road(way, data)
	assert_object(mesh_inst) \
		.override_failure_message("build_road builds the oblique road").is_not_null()
	if mesh_inst == null:
		return

	var worst := _worst_road_penetration(mesh_inst.mesh, hp)
	var pen: float = worst["pen"]
	var xz: Vector2 = worst.get("xz", Vector2.ZERO)
	mesh_inst.free()

	var msg := (
		"A narrow road running obliquely over folded terrain at production grid " +
		"settings must not let the ground show through. Worst penetration: %s m " +
		"at XZ (%s, %s). Before the terrain-conforming fix flat road quads dipped " +
		"below terrain folds crossing them."
	) % ["%.4f" % pen, "%.2f" % xz.x, "%.2f" % xz.y]
	# Sub-centimetre tolerance: exact on the mesh, with float-edge slack.
	assert_float(pen).override_failure_message(msg).is_less_equal(0.01)
