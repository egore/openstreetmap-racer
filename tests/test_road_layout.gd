extends GdUnitTestSuite

## Road-layout improvements in OSMWayBuilder:
##
##   (a) Width by lane count. When a road carries more than one lane — whether
##       tagged (lanes=N) or defaulted by RoadLaneSpec for its highway type — and
##       has no explicit `width` tag, the carriageway width scales with the lane
##       count (lane_count × LANE_WIDTH) instead of the flat per-type default,
##       never shrinking below that default. An explicit `width` tag still wins.
##
##   (b) Lane attachment. A single-lane street that TERMINATES at the terminal
##       end of a two-lane street is nudged sideways so its centreline meets one
##       of that street's two lane centres, not its middle. Two single-lane
##       branches sharing that end take the two DIFFERENT lanes.

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMWayBuilder := preload("res://scripts/osm_way_builder.gd")
const RoadLaneSpec := preload("res://scripts/road_lane_spec.gd")


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


# ─── (b) lane attachment ─────────────────────────────────────────────────────

## Two-lane trunk running S→N and ENDING at node N=(0,0). Two single-lane
## residential branches continue north from N. Each branch's near end should be
## nudged onto one of the trunk's two lane centres (±width/4 in X), and the two
## branches must land on DIFFERENT lanes.
func _forked_end() -> OSMParser.OSMData:
	# Branches run STRAIGHT north (X≈0) through the whole 8 m taper zone before
	# angling away, so the tapered tip's lateral shift lands purely in X and the
	# near-end centreline is cleanly measurable as the midpoint of its X extent.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, -60.0),   # trunk south end
		2: _node(2, 0.0, 0.0),     # shared junction N
		5: _node(5, 0.0, 12.0),    # branch A straight run out of taper zone
		3: _node(3, -20.0, 60.0),  # branch A far end (leans left / -X)
		6: _node(6, 0.0, 12.0),    # branch B straight run out of taper zone
		4: _node(4, 20.0, 60.0),   # branch B far end (leans right / +X)
	}
	data.ways = {
		# Two-lane anchor terminating at node 2.
		1: _way(1, [1, 2], {"highway": "trunk", "lanes": "2"}),
		# Single-lane branches, each terminating at node 2, running straight first.
		2: _way(2, [2, 5, 3], {"highway": "residential", "lanes": "1", "oneway": "yes"}),
		3: _way(3, [2, 6, 4], {"highway": "residential", "lanes": "1", "oneway": "yes"}),
	}
	return data


func test_branch_end_attaches_to_a_lane_not_center() -> void:
	# The anchor is a two-lane trunk. Its width is max(2×3.5, trunk default 10)=10,
	# so each lane is 5 m wide and its two lane centres sit at ±2.5 m from the
	# centreline. The two single-lane branches must be nudged onto those centres.
	var data := _forked_end()
	var anchor_spec := RoadLaneSpec.from_tags("trunk", {"lanes": "2"})
	var builder := OSMWayBuilder.new()
	var anchor_width := builder._road_width("trunk", {"lanes": "2"}, anchor_spec)
	var lane_offset := anchor_width / 4.0  # 2-lane road: lane centre = width/4

	var off_a := builder._lane_attach_offset(2, data.ways[2], data)
	var off_b := builder._lane_attach_offset(2, data.ways[3], data)

	# Offset is lateral (perpendicular to the N–S trunk → along X), magnitude =
	# lane_offset, and NOT along the trunk (no Z component).
	assert_float(off_a.z).is_equal_approx(0.0, 0.001)
	assert_float(off_b.z).is_equal_approx(0.0, 0.001)
	assert_float(absf(off_a.x)).override_failure_message(
		"branch A must land on a lane centre (|x|≈%.2f), got %.3f"
		% [lane_offset, off_a.x]).is_equal_approx(lane_offset, 0.01)
	assert_float(absf(off_b.x)).override_failure_message(
		"branch B must land on a lane centre (|x|≈%.2f), got %.3f"
		% [lane_offset, off_b.x]).is_equal_approx(lane_offset, 0.01)
	# The two branches take OPPOSITE lanes (one -X, one +X).
	assert_bool(signf(off_a.x) != signf(off_b.x)).override_failure_message(
		"two branches must attach to different lanes, got a=%.3f b=%.3f"
		% [off_a.x, off_b.x]).is_true()


func test_branch_end_shift_shows_in_mesh() -> void:
	# End-to-end: the built branch mesh's near-junction (Z≈0) extent is shifted
	# sideways vs the same branch built with NO anchor (baseline centred at X=0).
	var data := _forked_end()
	var builder := OSMWayBuilder.new()
	var mi := builder.build_road(data.ways[2], data)
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var shifted := _near_end_x_extent(mi.mesh)
	mi.free()

	# Baseline: drop the wide anchor so no attachment happens.
	var base_data := _forked_end()
	base_data.ways.erase(1)
	var mi_base := builder.build_road(base_data.ways[2], base_data)
	var base := _near_end_x_extent(mi_base.mesh)
	mi_base.free()

	# Both extent bounds move the same way (a rigid lateral shift), by ~2.5 m.
	var shift: float = shifted["min_x"] - base["min_x"]
	assert_float(shift).override_failure_message(
		"branch near-end should shift laterally onto its lane, got %.3f" % shift) \
		.is_equal_approx(-2.5, 0.4)


## [min_x, max_x] of the vertices nearest the junction end (Z≈min_z), as a dict.
func _near_end_x_extent(mesh: Mesh) -> Dictionary:
	var mdt := MeshDataTool.new()
	mdt.create_from_surface(mesh, 0)
	var min_z := INF
	for vi: int in range(mdt.get_vertex_count()):
		min_z = minf(min_z, mdt.get_vertex(vi).z)
	var out := {"min_x": INF, "max_x": -INF}
	for vi: int in range(mdt.get_vertex_count()):
		var v := mdt.get_vertex(vi)
		if absf(v.z - min_z) < 2.0:
			out["min_x"] = minf(out["min_x"], v.x)
			out["max_x"] = maxf(out["max_x"], v.x)
	return out


func test_no_attachment_without_wide_anchor() -> void:
	# Single-lane road meeting a single-lane road: no 2+ lane anchor, so no
	# lateral shift is computed.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, -60.0), 2: _node(2, 0.0, 0.0), 3: _node(3, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [1, 2], {"highway": "residential", "lanes": "1", "oneway": "yes"}),
		2: _way(2, [2, 3], {"highway": "residential", "lanes": "1", "oneway": "yes"}),
	}
	var off := OSMWayBuilder.new()._lane_attach_offset(2, data.ways[2], data)
	assert_vector(off).override_failure_message(
		"no wide anchor → no lateral shift, got %s" % off).is_equal(Vector3.ZERO)
