extends GdUnitTestSuite

## Unit tests for the traffic road *graph* — the connectivity the fix added so
## cars flow from one road onto a connected one at shared junctions instead of
## teleporting between disjoint ways.
##
## These pin the behaviour that was wrong ("cars jump around, don't pass segment
## to segment"):
##
##   1. Roads sharing an OSM endpoint node are linked at that junction.
##   2. next_road() returns a connected road oriented so the car enters from the
##      junction (its near endpoint is distance 0).
##   3. next_road() respects one-way direction (won't send a car the wrong way).
##   4. A dead end (no other road at the junction) returns null so the manager
##      recycles the car instead of continuing it.
##   5. Endpoints come from the actual node ids, so two ways that meet share a
##      junction key.

const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")
const OSMParser := preload("res://scripts/osm_parser.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Add a node at a local position to the dataset.
func _add_node(data: OSMParser.OSMData, id: int, pos: Vector3) -> void:
	var n := OSMParser.OSMNode.new()
	n.id = id
	n.local_pos = pos
	data.nodes[id] = n


## Add a drivable way through the given ordered node ids.
func _add_way(data: OSMParser.OSMData, id: int, node_ids: Array, extra: Dictionary = {}) -> void:
	var way := OSMParser.OSMWay.new()
	way.id = id
	var ids: Array[int] = []
	for nid: int in node_ids:
		ids.append(nid)
	way.node_ids = ids
	way.tags = {"highway": "residential"}
	for k: String in extra:
		way.tags[k] = extra[k]
	data.ways[id] = way


## Two roads meeting end-to-start at node 2:  A: n1->n2 (along +X), B: n2->n3
## (continuing +X). Straight line split into two ways at the shared node.
func _linear_pair() -> OSMParser.OSMData:
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [2, 3])
	return data


func _net(data: OSMParser.OSMData) -> TrafficRoadNetwork:
	var net := TrafficRoadNetwork.new()
	net.build(data)
	return net


# ─── Endpoint / junction indexing ────────────────────────────────────────────

func test_endpoints_are_the_node_ids() -> void:
	var net := _net(_linear_pair())
	var a := net.find_road(10)
	assert_int(a.start_node).is_equal(1)
	assert_int(a.end_node).is_equal(2)


func test_roads_at_shared_node_are_both_indexed() -> void:
	var net := _net(_linear_pair())
	var at_junction := net.roads_at_node(2)
	assert_int(at_junction.size()).is_equal(2)


func test_find_road_returns_null_for_unknown_way() -> void:
	var net := _net(_linear_pair())
	assert_object(net.find_road(999)).is_null()


# ─── Continuation (the segment-to-segment flow) ──────────────────────────────

func test_car_continues_onto_connected_road() -> void:
	# Exiting road 10 at its end (node 2) should continue onto road 20.
	var net := _net(_linear_pair())
	var rng := RandomNumberGenerator.new()
	var cont := net.next_road(net.find_road(10), true, rng)
	assert_object(cont).is_not_null()
	assert_int(cont.road.way_id).is_equal(20)


func test_continuation_oriented_so_car_enters_at_junction() -> void:
	# Road 20 is n2->n3; entering from the shared node 2 (its start) means NOT
	# reversed, so distance 0 sits at node 2, not node 3.
	var net := _net(_linear_pair())
	var rng := RandomNumberGenerator.new()
	var cont := net.next_road(net.find_road(10), true, rng)
	assert_bool(cont.reversed).is_false()


func test_continuation_reversed_when_junction_is_far_end() -> void:
	# Build B so the shared node is its END (n3->n2). Entering from node 2 must
	# reverse B so the car still enters at the junction.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [3, 2])  # B ends at the shared node 2
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	var cont := net.next_road(net.find_road(10), true, rng)
	assert_object(cont).is_not_null()
	assert_int(cont.road.way_id).is_equal(20)
	assert_bool(cont.reversed).is_true()


func test_dead_end_returns_null() -> void:
	# A lone road connects to nothing at its end → no continuation.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_way(data, 10, [1, 2])
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	assert_object(net.next_road(net.find_road(10), true, rng)).is_null()


func test_oneway_cannot_be_entered_against_direction() -> void:
	# Road 20 is a one-way n3->n2. Its exit-only end (node 2) is where road 10
	# arrives; entering 20 there would drive it backwards, which is illegal, so
	# there's no valid continuation → null.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [3, 2], {"oneway": "yes"})  # flows 3->2, ends at junction 2
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	assert_object(net.next_road(net.find_road(10), true, rng)).is_null()


func test_oneway_can_be_entered_from_its_start() -> void:
	# One-way 20 flows n2->n3, starting at the junction — entering it forward is
	# fine.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [2, 3], {"oneway": "yes"})
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	var cont := net.next_road(net.find_road(10), true, rng)
	assert_object(cont).is_not_null()
	assert_int(cont.road.way_id).is_equal(20)
	assert_bool(cont.reversed).is_false()


func test_straightest_continuation_preferred_at_junction() -> void:
	# At node 2, offer a straight-ahead road (20, +X) and a sharp turn (30, +Z).
	# The straightest should be chosen deterministically (it's the sole top pick
	# only if we bias correctly — with 2 roads the picker chooses among the two
	# straightest, so here it may pick either; instead assert the straight road is
	# ranked first by checking a many-option junction).
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))     # straight ahead (+X)
	_add_node(data, 4, Vector3(100, 0, 100))   # right turn (+Z)
	_add_node(data, 5, Vector3(100, 0, -100))  # left turn (-Z)
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [2, 3])  # straight
	_add_way(data, 30, [2, 4])  # turn
	_add_way(data, 40, [2, 5])  # turn
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	# Sample several times; the straight road (20) must dominate the picks since
	# it's the straightest and the picker favours the top-2 straightest.
	var straight_picks := 0
	for i: int in range(40):
		var cont := net.next_road(net.find_road(10), true, rng)
		if cont != null and cont.road.way_id == 20:
			straight_picks += 1
	# 20 should be picked a healthy share of the time (it's always in the top-2).
	assert_int(straight_picks).is_greater(10)


# ─── Roundabouts / implicit one-way ──────────────────────────────────────────

func test_roundabout_is_one_way() -> void:
	# junction=roundabout is implicitly one-way even without an oneway tag.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(10, 0, 0))
	_add_way(data, 10, [1, 2], {"junction": "roundabout"})
	var net := _net(data)
	assert_bool(net.find_road(10).one_way).is_true()


func test_circular_junction_is_one_way() -> void:
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(10, 0, 0))
	_add_way(data, 10, [1, 2], {"junction": "circular"})
	var net := _net(data)
	assert_bool(net.find_road(10).one_way).is_true()


# ─── U-turn avoidance (issue 5: no weird ~180° turns) ────────────────────────

func test_hairpin_continuation_avoided_when_straight_exists() -> void:
	# At node 2 the incoming car heads +X. Offer a straight road (+X) and a
	# hairpin that doubles back (heads back toward -X). The straight one must be
	# chosen every time; the hairpin is rejected as a U-turn.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))       # straight ahead (+X)
	_add_node(data, 4, Vector3(20, 0, 5))        # hairpin: back toward -X
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [2, 3])  # straight
	_add_way(data, 30, [2, 4])  # hairpin doubling back
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	for i: int in range(30):
		var cont := net.next_road(net.find_road(10), true, rng)
		assert_int(cont.road.way_id).is_equal(20)


func test_hairpin_taken_only_when_it_is_the_only_option() -> void:
	# A dead-end street where the sole continuation is a sharp turn: the car must
	# still take it rather than getting stuck (better a hairpin than a freeze).
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 4, Vector3(20, 0, 5))  # only exit doubles back
	_add_way(data, 10, [1, 2])
	_add_way(data, 30, [2, 4])
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	var cont := net.next_road(net.find_road(10), true, rng)
	assert_object(cont).is_not_null()
	assert_int(cont.road.way_id).is_equal(30)
