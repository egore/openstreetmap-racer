extends GdUnitTestSuite

## Unit tests for RoadMarkingSpec — the parser that finds transverse road
## markings (zebra crossings, stop lines, give-way lines) from OSM nodes placed
## ON a road way and computes each marking's metres-along distance for the
## asphalt shader.
##
## These pin:
##   • node classification (crossing/stop/give_way → Kind, unmarked → none)
##   • along-road distance measured on the raw polyline (matches ribbon UV.x)
##   • the MAX_MARKINGS cap and ordering
## plus the RoadMaterialFactory wiring that pushes them into the shader uniforms.

const OSMParser := preload("res://scripts/osm_parser.gd")
const RoadMarkingSpec := preload("res://scripts/road_marking_spec.gd")
const RoadMaterialFactory := preload("res://scripts/road_material_factory.gd")
const RoadLaneSpec := preload("res://scripts/road_lane_spec.gd")


func _node(id: int, x: float, z: float, tags: Dictionary = {}) -> OSMParser.OSMNode:
	var n := OSMParser.OSMNode.new()
	n.id = id
	n.local_pos = Vector3(x, 0.0, z)
	n.tags = tags
	return n


## A straight 100 m road with the given per-node tag overrides keyed by node id.
func _road_nodes(marking_tags: Dictionary) -> Dictionary:
	var nodes := {}
	# 0 m, 25 m, 50 m, 75 m, 100 m along +Z.
	var zs := [0.0, 25.0, 50.0, 75.0, 100.0]
	for i in range(zs.size()):
		var id := i + 1
		nodes[id] = _node(id, 0.0, zs[i], marking_tags.get(id, {}))
	return nodes


func _ids() -> Array[int]:
	return [1, 2, 3, 4, 5] as Array[int]


func test_no_markings_when_no_tagged_nodes() -> void:
	var spec := RoadMarkingSpec.from_way(_ids(), _road_nodes({}))
	assert_bool(spec.is_empty()).is_true()
	assert_int(spec.along_positions().size()).is_equal(0)


func test_zebra_crossing_at_midpoint() -> void:
	# A marked crossing at the 50 m node.
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({3: {"highway": "crossing", "crossing": "zebra"}}))
	assert_int(spec.markings.size()).is_equal(1)
	assert_float(spec.markings[0].along).is_equal_approx(50.0, 0.001)
	assert_int(spec.markings[0].kind).is_equal(RoadMarkingSpec.Kind.ZEBRA)


func test_plain_crossing_defaults_to_zebra() -> void:
	# highway=crossing with no crossing=* still reads as a marked crossing.
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({2: {"highway": "crossing"}}))
	assert_int(spec.markings.size()).is_equal(1)
	assert_int(spec.markings[0].kind).is_equal(RoadMarkingSpec.Kind.ZEBRA)


func test_unmarked_crossing_is_skipped() -> void:
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({2: {"highway": "crossing", "crossing": "unmarked"}}))
	assert_bool(spec.is_empty()).is_true()


func test_crossing_markings_no_is_skipped() -> void:
	# crossing:markings=no overrides an otherwise-marked crossing value.
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({2: {"highway": "crossing", "crossing:markings": "no"}}))
	assert_bool(spec.is_empty()).is_true()


func test_stop_line() -> void:
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({5: {"highway": "stop"}}))
	assert_int(spec.markings.size()).is_equal(1)
	assert_float(spec.markings[0].along).is_equal_approx(100.0, 0.001)
	assert_int(spec.markings[0].kind).is_equal(RoadMarkingSpec.Kind.STOP)


func test_give_way_line() -> void:
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({4: {"highway": "give_way"}}))
	assert_int(spec.markings.size()).is_equal(1)
	assert_float(spec.markings[0].along).is_equal_approx(75.0, 0.001)
	assert_int(spec.markings[0].kind).is_equal(RoadMarkingSpec.Kind.GIVE_WAY)


func test_stop_wins_over_crossing_on_same_node() -> void:
	# A node tagged both a crossing and a stop paints the stop bar (stronger cue).
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({3: {"highway": "stop", "crossing": "zebra"}}))
	assert_int(spec.markings.size()).is_equal(1)
	assert_int(spec.markings[0].kind).is_equal(RoadMarkingSpec.Kind.STOP)


func test_multiple_markings_sorted_by_distance() -> void:
	var spec := RoadMarkingSpec.from_way(_ids(), _road_nodes({
		4: {"highway": "stop"},
		2: {"highway": "crossing", "crossing": "zebra"},
	}))
	assert_int(spec.markings.size()).is_equal(2)
	# Sorted ascending by along-distance: 25 m crossing, then 75 m stop.
	assert_float(spec.markings[0].along).is_equal_approx(25.0, 0.001)
	assert_int(spec.markings[0].kind).is_equal(RoadMarkingSpec.Kind.ZEBRA)
	assert_float(spec.markings[1].along).is_equal_approx(75.0, 0.001)
	assert_int(spec.markings[1].kind).is_equal(RoadMarkingSpec.Kind.STOP)


func test_arrays_line_up_and_respect_cap() -> void:
	# More markings than MAX_MARKINGS keeps only the earliest ones, and the two
	# parallel arrays stay index-aligned.
	var nodes := {}
	var ids: Array[int] = []
	var count := RoadMarkingSpec.MAX_MARKINGS + 3
	for i in range(count):
		var id := i + 1
		nodes[id] = _node(id, 0.0, float(i) * 10.0, {"highway": "crossing", "crossing": "zebra"})
		ids.append(id)
	var spec := RoadMarkingSpec.from_way(ids, nodes)
	var along := spec.along_positions()
	var kinds := spec.kinds()
	assert_int(along.size()).is_equal(RoadMarkingSpec.MAX_MARKINGS)
	assert_int(kinds.size()).is_equal(RoadMarkingSpec.MAX_MARKINGS)
	# Earliest kept: first entry is the 0 m marking.
	assert_float(along[0]).is_equal_approx(0.0, 0.001)


func test_missing_node_ids_are_skipped() -> void:
	# way references a node id that isn't in the map: it's silently skipped and
	# does not shift the along distances of the present nodes.
	var nodes := _road_nodes({3: {"highway": "stop"}})
	var ids: Array[int] = [1, 999, 3, 5]  # 999 absent
	var spec := RoadMarkingSpec.from_way(ids, nodes)
	assert_int(spec.markings.size()).is_equal(1)
	# node 3 is at 50 m; with 999 skipped, distance is 1→3 = 50 m directly.
	assert_float(spec.markings[0].along).is_equal_approx(50.0, 0.001)


# ─── Material wiring ─────────────────────────────────────────────────────────


func test_material_sets_transverse_uniforms() -> void:
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({3: {"highway": "crossing", "crossing": "zebra"}}))
	var lane := RoadLaneSpec.from_tags("residential", {})
	var mat := RoadMaterialFactory.create_road_material(
		"residential", Color(0.2, 0.2, 0.2), lane, 5.0, 100.0, spec) as ShaderMaterial
	assert_object(mat).is_not_null()
	assert_int(mat.get_shader_parameter("transverse_count")).is_equal(1)
	var along: PackedFloat32Array = mat.get_shader_parameter("transverse_along")
	var kinds: PackedFloat32Array = mat.get_shader_parameter("transverse_kind")
	assert_float(along[0]).is_equal_approx(50.0, 0.001)
	assert_float(kinds[0]).is_equal(float(RoadMarkingSpec.Kind.ZEBRA))


func test_material_disables_transverse_when_empty() -> void:
	var spec := RoadMarkingSpec.from_way(_ids(), _road_nodes({}))
	var lane := RoadLaneSpec.from_tags("residential", {})
	var mat := RoadMaterialFactory.create_road_material(
		"residential", Color(0.2, 0.2, 0.2), lane, 5.0, 100.0, spec) as ShaderMaterial
	assert_int(mat.get_shader_parameter("transverse_count")).is_equal(0)


func test_material_disables_transverse_when_no_width() -> void:
	# Zero carriageway width can't span a band, so markings stay off even with a
	# non-empty spec.
	var spec := RoadMarkingSpec.from_way(
		_ids(), _road_nodes({3: {"highway": "stop"}}))
	var lane := RoadLaneSpec.from_tags("residential", {})
	var mat := RoadMaterialFactory.create_road_material(
		"residential", Color(0.2, 0.2, 0.2), lane, 0.0, 100.0, spec) as ShaderMaterial
	assert_int(mat.get_shader_parameter("transverse_count")).is_equal(0)
