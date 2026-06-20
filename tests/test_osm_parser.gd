extends GdUnitTestSuite

## Unit tests for OSMParser XML parsing and coordinate projection.
##
## OSMParser is the data backbone of the whole pipeline: it turns an .osm XML
## file into structured nodes/ways/relations and projects every node into local
## meter coordinates. These tests pin that contract so refactors can't silently
## drop tags, mis-handle self-closing elements, or skew the projection:
##
##   1. Element parsing: nodes, ways (with nd refs), relations (with members),
##      and tags attached to the correct current element.
##   2. Self-closing vs open elements — `xml.is_empty()` paths must commit the
##      element immediately (osm_parser.gd:73,80,87) AND the END-tag paths must
##      commit open elements (osm_parser.gd:115).
##   3. Bounds: taken from a <bounds> tag when present, else computed from node
##      extents (osm_parser.gd:128), with center derived from bounds.
##   4. Projection: _latlon_to_local is Y-up, X=east, Z=south, ref point at origin.
##   5. apply_elevation=false (and absent DEM) keeps the world flat at y=0.
##   6. Missing file degrades to empty data instead of crashing.

const OSMParser := preload("res://scripts/osm_parser.gd")

var _tmp_osm := "user://_test_parser.osm"


# ─── Lifecycle ───────────────────────────────────────────────────────────────

func after() -> void:
	_cleanup()


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Write the given XML body to the temp .osm path and return its globalized
## filesystem path (parse_file opens via FileAccess + XMLParser which accept
## res:// / user:// paths, so the user:// path is passed straight through).
func _write_osm(body: String) -> String:
	var f := FileAccess.open(_tmp_osm, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	return _tmp_osm


func _cleanup() -> void:
	if FileAccess.file_exists(_tmp_osm):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp_osm))


## A small but complete document exercising bounds, nodes (open + self-closing),
## a tagged way with nd refs, and a relation with members. apply_elevation is
## left false by the caller so no DEM asset is required.
const _FULL_DOC := """<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6">
  <bounds minlat="49.00" minlon="8.00" maxlat="49.02" maxlon="8.02"/>
  <node id="1" lat="49.005" lon="8.005">
    <tag k="amenity" v="cafe"/>
  </node>
  <node id="2" lat="49.015" lon="8.015"/>
  <node id="3" lat="49.010" lon="8.018"/>
  <way id="100">
    <nd ref="1"/>
    <nd ref="2"/>
    <nd ref="3"/>
    <tag k="highway" v="residential"/>
    <tag k="name" v="Test Street"/>
  </way>
  <relation id="200">
    <member type="way" ref="100" role="outer"/>
    <member type="node" ref="1" role=""/>
    <tag k="type" v="multipolygon"/>
  </relation>
</osm>
"""


# ─── Element parsing ─────────────────────────────────────────────────────────

func test_parses_node_way_relation_counts() -> void:
	var data := OSMParser.parse_file(_write_osm(_FULL_DOC), false)
	assert_int(data.nodes.size()) \
		.override_failure_message("3 nodes parsed").is_equal(3)
	assert_int(data.ways.size()) \
		.override_failure_message("1 way parsed").is_equal(1)
	assert_int(data.relations.size()) \
		.override_failure_message("1 relation parsed").is_equal(1)


func test_node_tags_attach_to_correct_node() -> void:
	var data := OSMParser.parse_file(_write_osm(_FULL_DOC), false)
	var node: OSMParser.OSMNode = data.nodes[1]
	assert_str(node.tags.get("amenity", "")) \
		.override_failure_message("node 1 carries its amenity tag").is_equal("cafe")
	# The self-closing node 2 must exist and carry no tags.
	assert_bool(data.nodes.has(2)) \
		.override_failure_message("self-closing node 2 committed").is_true()
	assert_int((data.nodes[2] as OSMParser.OSMNode).tags.size()) \
		.override_failure_message("self-closing node has no tags").is_equal(0)


func test_way_node_refs_and_tags() -> void:
	var data := OSMParser.parse_file(_write_osm(_FULL_DOC), false)
	var way: OSMParser.OSMWay = data.ways[100]
	assert_array(way.node_ids) \
		.override_failure_message("way preserves nd ref order").is_equal([1, 2, 3])
	assert_str(way.tags.get("highway", "")) \
		.override_failure_message("way highway tag parsed").is_equal("residential")
	assert_str(way.tags.get("name", "")) \
		.override_failure_message("way name tag parsed").is_equal("Test Street")


func test_relation_members_and_tags() -> void:
	var data := OSMParser.parse_file(_write_osm(_FULL_DOC), false)
	var rel: OSMParser.OSMRelation = data.relations[200]
	assert_int(rel.members.size()) \
		.override_failure_message("relation has 2 members").is_equal(2)
	var first: Dictionary = rel.members[0]
	assert_str(first["type"]).override_failure_message("member type").is_equal("way")
	assert_int(first["ref"]).override_failure_message("member ref").is_equal(100)
	assert_str(first["role"]).override_failure_message("member role").is_equal("outer")
	assert_str(rel.tags.get("type", "")) \
		.override_failure_message("relation type tag").is_equal("multipolygon")


# ─── Bounds and center ───────────────────────────────────────────────────────

func test_bounds_from_bounds_tag() -> void:
	var data := OSMParser.parse_file(_write_osm(_FULL_DOC), false)
	# Rect2(minlon, minlat, lon_span, lat_span)
	assert_float(data.bounds.position.x).override_failure_message("min lon").is_equal_approx(8.00, 1e-6)
	assert_float(data.bounds.position.y).override_failure_message("min lat").is_equal_approx(49.00, 1e-6)
	assert_float(data.bounds.size.x).override_failure_message("lon span").is_equal_approx(0.02, 1e-6)
	assert_float(data.bounds.size.y).override_failure_message("lat span").is_equal_approx(0.02, 1e-6)
	assert_float(data.center_lat).override_failure_message("center lat").is_equal_approx(49.01, 1e-6)
	assert_float(data.center_lon).override_failure_message("center lon").is_equal_approx(8.01, 1e-6)


func test_bounds_computed_from_nodes_when_tag_absent() -> void:
	# No <bounds> tag => extents derived from node lat/lon (osm_parser.gd:128).
	var doc := """<?xml version="1.0"?>
<osm version="0.6">
  <node id="1" lat="49.00" lon="8.00"/>
  <node id="2" lat="49.04" lon="8.06"/>
</osm>
"""
	var data := OSMParser.parse_file(_write_osm(doc), false)
	assert_float(data.bounds.position.x).override_failure_message("min lon from nodes").is_equal_approx(8.00, 1e-6)
	assert_float(data.bounds.position.y).override_failure_message("min lat from nodes").is_equal_approx(49.00, 1e-6)
	assert_float(data.bounds.size.x).override_failure_message("lon span from nodes").is_equal_approx(0.06, 1e-6)
	assert_float(data.bounds.size.y).override_failure_message("lat span from nodes").is_equal_approx(0.04, 1e-6)
	assert_float(data.center_lat).override_failure_message("center lat from nodes").is_equal_approx(49.02, 1e-6)
	assert_float(data.center_lon).override_failure_message("center lon from nodes").is_equal_approx(8.03, 1e-6)


# ─── Projection ──────────────────────────────────────────────────────────────

func test_reference_node_projects_to_origin_xz() -> void:
	# A node exactly at the center lat/lon must land at local X=0, Z=0.
	var doc := """<?xml version="1.0"?>
<osm version="0.6">
  <bounds minlat="49.00" minlon="8.00" maxlat="49.02" maxlon="8.02"/>
  <node id="1" lat="49.01" lon="8.01"/>
</osm>
"""
	var data := OSMParser.parse_file(_write_osm(doc), false)
	var p := (data.nodes[1] as OSMParser.OSMNode).local_pos
	assert_float(p.x).override_failure_message("center node X==0").is_equal_approx(0.0, 1e-3)
	assert_float(p.z).override_failure_message("center node Z==0").is_equal_approx(0.0, 1e-3)


func test_projection_axes_east_positive_north_negative_z() -> void:
	# X grows east (higher lon), Z grows south (so north => negative Z).
	var doc := """<?xml version="1.0"?>
<osm version="0.6">
  <bounds minlat="49.00" minlon="8.00" maxlat="49.02" maxlon="8.02"/>
  <node id="1" lat="49.01" lon="8.01"/>
  <node id="2" lat="49.01" lon="8.02"/>
  <node id="3" lat="49.02" lon="8.01"/>
</osm>
"""
	var data := OSMParser.parse_file(_write_osm(doc), false)
	var east := (data.nodes[2] as OSMParser.OSMNode).local_pos
	var north := (data.nodes[3] as OSMParser.OSMNode).local_pos
	assert_float(east.x).override_failure_message("east node has positive X").is_greater(0.0)
	assert_float(north.z).override_failure_message("north node has negative Z").is_less(0.0)


func test_latlon_to_local_matches_manual_formula() -> void:
	# Pin the exact projection used by HeightProvider's inverse and the renderer.
	var ref_lat := 49.01
	var ref_lon := 8.01
	var lat := 49.015
	var lon := 8.018
	var got := OSMParser._latlon_to_local(lat, lon, ref_lat, ref_lon)
	var m_per_deg_lat := 111132.0
	var m_per_deg_lon := 111132.0 * cos(deg_to_rad(ref_lat))
	var expect_x := (lon - ref_lon) * m_per_deg_lon
	var expect_z := -(lat - ref_lat) * m_per_deg_lat
	assert_float(got.x).override_failure_message("projection X matches formula").is_equal_approx(expect_x, 1e-3)
	assert_float(got.z).override_failure_message("projection Z matches formula").is_equal_approx(expect_z, 1e-3)
	assert_float(got.y).override_failure_message("projection Y is 0").is_equal_approx(0.0, 1e-6)


# ─── Elevation ───────────────────────────────────────────────────────────────

func test_apply_elevation_false_keeps_world_flat() -> void:
	var data := OSMParser.parse_file(_write_osm(_FULL_DOC), false)
	for node: OSMParser.OSMNode in data.nodes.values():
		assert_float(node.local_pos.y) \
			.override_failure_message("node %d stays at y=0 without elevation" % node.id) \
			.is_equal_approx(0.0, 1e-6)
	assert_object(data.height_provider) \
		.override_failure_message("no height provider when apply_elevation is false").is_null()


# ─── Error handling ──────────────────────────────────────────────────────────

func test_missing_file_returns_empty_data() -> void:
	var data := OSMParser.parse_file("user://does_not_exist.osm", false)
	assert_object(data).override_failure_message("returns a non-null OSMData").is_not_null()
	assert_int(data.nodes.size()).override_failure_message("no nodes from missing file").is_equal(0)
	assert_int(data.ways.size()).override_failure_message("no ways from missing file").is_equal(0)
	assert_int(data.relations.size()).override_failure_message("no relations from missing file").is_equal(0)
