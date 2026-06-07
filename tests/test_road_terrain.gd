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


func _cleanup() -> void:
	for p: String in [_tmp_png, _tmp_json]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))


func _make_height_provider() -> HeightProvider:
	var hp := HeightProvider.new()
	var ref_lat := (MIN_LAT + MAX_LAT) / 2.0
	var ref_lon := (MIN_LON + MAX_LON) / 2.0
	var ok := hp.load_from_files(ref_lat, ref_lon, _tmp_png, _tmp_json)
	assert_bool(ok) \
		.override_failure_message("HeightProvider loads the test DEM fixture").is_true()
	hp.set_mesh_grid(TILE_SIZE, TERRAIN_SUBS)
	return hp


## Build a minimal OSMData with two nodes forming a north→south road segment.
## The road runs at a fixed longitude (constant X) so the east–west elevation
## gradient creates a cross-slope perpendicular to the road.
func _make_road_osm_data(hp: HeightProvider) -> OSMParser.OSMData:
	var ref_lat := (MIN_LAT + MAX_LAT) / 2.0
	var ref_lon := (MIN_LON + MAX_LON) / 2.0
	var m_per_deg_lat := 111132.0
	var m_per_deg_lon := 111132.0 * cos(deg_to_rad(ref_lat))

	# Place two nodes at the dataset center longitude, offset north/south.
	var lat_a := ref_lat + 0.002   # slightly north
	var lat_b := ref_lat - 0.002   # slightly south
	var lon := ref_lon             # center longitude → middle of slope

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
