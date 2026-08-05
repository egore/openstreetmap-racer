extends GdUnitTestSuite

## Road-layout improvements in OSMWayBuilder:
##
##   (a) Width by lane count. When a road carries more than one lane — whether
##       tagged (lanes=N) or defaulted by RoadLaneSpec for its highway type — and
##       has no explicit `width` tag, the carriageway width scales with the lane
##       count (lane_count × LANE_WIDTH) instead of the flat per-type default,
##       never shrinking below that default. An explicit `width` tag still wins.
##
##   (b) Junction trimming. A road that ends at a real intersection is pulled
##       back so the intersection cap can fill the crossing. A road that merely
##       continues into another way is NOT trimmed, so straight streets stay
##       unbroken.
##
## The old "lane attachment" behaviour (nudging a narrow road sideways onto a
## wider road's lane centre) was a workaround for having no intersections at
## all. Real junction geometry replaces it, so those tests are gone.

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMWayBuilder := preload("res://scripts/osm_way_builder.gd")
const RoadLaneSpec := preload("res://scripts/road_lane_spec.gd")
const RoadNetworkContext := preload("res://scripts/road_network_context.gd")


func _node(id: int, x: float, z: float) -> OSMParser.OSMNode:
	var n := OSMParser.OSMNode.new()
	n.id = id
	n.local_pos = Vector3(x, 0.0, z)
	return n


func _way(id: int, node_ids: Array, tags: Dictionary) -> OSMParser.OSMWay:
	var w := OSMParser.OSMWay.new()
	w.id = id
	var ids: Array[int] = []
	for n: int in node_ids:
		ids.append(n)
	w.node_ids = ids
	# Default sidewalk off so bounds reflect only the carriageway width.
	var t := {"sidewalk": "no"}
	t.merge(tags)
	w.tags = t
	return w


func _bounds_of_mesh(mesh: Mesh) -> Dictionary:
	var mdt := MeshDataTool.new()
	if mdt.create_from_surface(mesh, 0) != OK:
		return {}
	var b := {"min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF}
	for vi: int in range(mdt.get_vertex_count()):
		var v := mdt.get_vertex(vi)
		b["min_x"] = minf(b["min_x"], v.x)
		b["max_x"] = maxf(b["max_x"], v.x)
		b["min_z"] = minf(b["min_z"], v.z)
		b["max_z"] = maxf(b["max_z"], v.z)
	return b


## A single straight road running along +Z (X≈0), so the mesh X extent equals the
## carriageway width. No junctions.
func _single_road(tags: Dictionary) -> Dictionary:
	var data := OSMParser.OSMData.new()
	data.nodes = {1: _node(1, 0.0, 0.0), 2: _node(2, 0.0, 100.0)}
	var way := _way(1, [1, 2], tags)
	data.ways = {1: way}
	return {"data": data, "way": way}


func _width_of(tags: Dictionary) -> float:
	var fx := _single_road(tags)
	var mi := OSMWayBuilder.new().build_road(fx["way"], fx["data"])
	assert_object(mi).is_not_null()
	if mi == null:
		return -1.0
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	return b["max_x"] - b["min_x"]


# ─── (a) width by lane count ─────────────────────────────────────────────────

func test_multilane_tag_widens_beyond_type_default() -> void:
	# residential default is 5 m; four lanes → 4 × 3.5 = 14 m.
	var w := _width_of({"highway": "residential", "lanes": "4"})
	assert_float(w).is_equal_approx(14.0, 0.05)


func test_three_lane_tag_widens() -> void:
	var w := _width_of({"highway": "residential", "lanes": "3"})
	assert_float(w).is_equal_approx(3 * RoadLaneSpec.LANE_WIDTH, 0.05)


func test_oneway_single_lane_is_one_lane_wide_not_type_default() -> void:
	# The reported bug: a one-way single-lane residential must render as ONE lane
	# (per-lane = max(5/2, 3.5) = 3.5 m), NOT the two-lane type default of 5 m.
	var w := _width_of({"highway": "residential", "lanes": "1", "oneway": "yes"})
	assert_float(w).is_equal_approx(3.5, 0.05)


func test_oneway_tertiary_is_half_of_two_lane_tertiary() -> void:
	# Exactly the reported topology's widths: a two-lane tertiary vs a one-way,
	# no-lanes tertiary. The one-way must be clearly NARROWER (≈ half), not the
	# near-equal width the flat type default used to give (7 m vs 6 m).
	var two_lane := _width_of({"highway": "tertiary", "lanes": "2"})
	var oneway := _width_of({"highway": "tertiary", "oneway": "yes"})
	assert_float(two_lane).is_equal_approx(7.0, 0.05)   # 2 × max(6/2, 3.5) = 7
	assert_float(oneway).is_equal_approx(3.5, 0.05)     # 1 × max(6/2, 3.5) = 3.5
	assert_float(oneway).is_less(two_lane * 0.75)


func test_default_two_lane_scales_with_lanes() -> void:
	# No lanes tag: residential defaults to 2 lanes → 2 × max(5/2, 3.5) = 7 m.
	var w := _width_of({"highway": "residential"})
	assert_float(w).is_equal_approx(7.0, 0.05)


func test_explicit_width_tag_overrides_lane_count() -> void:
	var w := _width_of({"highway": "residential", "lanes": "4", "width": "9.5"})
	assert_float(w).is_equal_approx(9.5, 0.05)


func test_motorway_uses_wide_per_lane_from_type_default() -> void:
	# motorway per-lane = max(12/2, 3.5) = 6 m, so a 2-lane motorway is 12 m.
	var w := _width_of({"highway": "motorway", "lanes": "2"})
	assert_float(w).is_equal_approx(12.0, 0.05)


func test_unmarked_footway_keeps_literal_type_default() -> void:
	# Footways aren't carriageways: their (defaulted) lane count must NOT scale
	# the width. A footway stays at its 1.5 m literal default, not 2 × 3.5.
	var w := _width_of({"highway": "footway"})
	assert_float(w).is_equal_approx(1.5, 0.05)


# ─── (b) junction trimming ───────────────────────────────────────────────────

## A + crossing of two roads at the origin, plus the solved network context that
## OSMWayBuilder consults to know where to cut each ribbon.
func _crossing() -> Dictionary:
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -60.0, 0.0), 2: _node(2, 0.0, 0.0), 3: _node(3, 60.0, 0.0),
		4: _node(4, 0.0, -60.0), 5: _node(5, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [1, 2, 3], {"highway": "residential"}),
		2: _way(2, [4, 2, 5], {"highway": "residential"}),
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	var net := RoadNetworkContext.build(ways, ways, data.nodes, [])
	return {"data": data, "net": net}


func test_road_ending_at_a_junction_is_trimmed_back() -> void:
	# A road that terminates at an intersection must stop short of it so the
	# junction cap can fill the crossing; running to the node would overlap.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, 0.0), 2: _node(2, 60.0, 0.0),
		3: _node(3, -60.0, 0.0), 4: _node(4, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [3, 1, 2], {"highway": "residential"}),  # through road
		2: _way(2, [1, 4], {"highway": "residential"}),     # spur from the node
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	var builder := OSMWayBuilder.new()
	builder.network = RoadNetworkContext.build(ways, ways, data.nodes, [])

	var mi := builder.build_road(data.ways[2], data)
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_z"]) \
		.override_failure_message(
			"spur must stop short of the junction, got min_z=%.2f" % b["min_z"]) \
		.is_greater(0.5)


func test_road_not_at_a_junction_runs_to_its_node() -> void:
	# Two ways simply meeting end to end is a continuation, not an intersection.
	# Trimming there would tear a hole in a straight street.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, 0.0), 2: _node(2, 0.0, 60.0), 3: _node(3, 0.0, -60.0),
	}
	data.ways = {
		1: _way(1, [3, 1], {"highway": "residential"}),
		2: _way(2, [1, 2], {"highway": "residential"}),
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	var builder := OSMWayBuilder.new()
	builder.network = RoadNetworkContext.build(ways, ways, data.nodes, [])

	var mi := builder.build_road(data.ways[2], data)
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_z"]) \
		.override_failure_message(
			"a continuing road must not be trimmed, got min_z=%.2f" % b["min_z"]) \
		.is_less_equal(0.01)


func test_trimming_preserves_the_far_end() -> void:
	# Only the junction end moves; the far end must still reach its own node.
	var fx := _crossing()
	var builder := OSMWayBuilder.new()
	builder.network = fx["net"]
	var mi := builder.build_road(fx["data"].ways[1], fx["data"])
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_x"]).is_less_equal(-59.9)
	assert_float(b["max_x"]).is_greater_equal(59.9)


func test_trimmed_road_keeps_its_full_width() -> void:
	# Trimming shortens a road; it must not narrow it.
	var fx := _crossing()
	var builder := OSMWayBuilder.new()
	builder.network = fx["net"]
	var mi := builder.build_road(fx["data"].ways[1], fx["data"])
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	var width: float = b["max_z"] - b["min_z"]
	assert_float(width) \
		.override_failure_message("trimmed road must keep its width") \
		.is_equal_approx(7.0, 0.1)


func test_no_network_means_no_trimming() -> void:
	# With no solved network (flat/legacy path, or a way built in isolation) the
	# builder must fall back to full-length ribbons rather than crashing.
	var fx := _crossing()
	var builder := OSMWayBuilder.new()
	builder.network = null
	var mi := builder.build_road(fx["data"].ways[2], fx["data"])
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_z"]).is_less_equal(-59.9)


func test_footway_crossing_a_road_does_not_trim_it() -> void:
	# A footpath crossing a street is a painted crossing, not an intersection.
	# Carving a junction cap there would gouge the carriageway.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -60.0, 0.0), 2: _node(2, 0.0, 0.0), 3: _node(3, 60.0, 0.0),
		4: _node(4, 0.0, -60.0), 5: _node(5, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [1, 2, 3], {"highway": "residential"}),
		2: _way(2, [4, 2, 5], {"highway": "footway"}),
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	var builder := OSMWayBuilder.new()
	builder.network = RoadNetworkContext.build(ways, ways, data.nodes, [])
	var mi := builder.build_road(data.ways[1], data)
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_x"]) \
		.override_failure_message("a footway must not trim a road") \
		.is_less_equal(-59.9)


func test_tunnel_road_is_not_drawn_on_the_surface() -> void:
	var fx := _single_road({"highway": "primary", "tunnel": "yes"})
	var mi := OSMWayBuilder.new().build_road(fx["way"], fx["data"])
	assert_object(mi) \
		.override_failure_message("a tunnel must not render on the surface") \
		.is_null()


func test_bridge_road_is_lifted_above_ground() -> void:
	var fx := _single_road({"highway": "primary", "bridge": "yes"})
	var mi := OSMWayBuilder.new().build_road(fx["way"], fx["data"])
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var y := mi.position.y
	mi.free()
	assert_float(y) \
		.override_failure_message("a bridge must ride above ground level") \
		.is_greater(2.0)
