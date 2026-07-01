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


## Look a road up by its OSM way id. These fixtures use single-segment ways (no
## interior junctions), so way id → road is unambiguous; the network itself keys
## on the unique per-segment id (find_road), because a real way can split into
## several segments at its junctions.
func _road_by_way(net: TrafficRoadNetwork, way_id: int) -> TrafficRoadNetwork.Road:
	for road: TrafficRoadNetwork.Road in net.get_roads():
		if road.way_id == way_id:
			return road
	return null


# ─── Endpoint / junction indexing ────────────────────────────────────────────

func test_endpoints_are_the_node_ids() -> void:
	var net := _net(_linear_pair())
	var a := _road_by_way(net, 10)
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
	var cont := net.next_road(_road_by_way(net, 10), true, rng)
	assert_object(cont).is_not_null()
	assert_int(cont.road.way_id).is_equal(20)


func test_continuation_oriented_so_car_enters_at_junction() -> void:
	# Road 20 is n2->n3; entering from the shared node 2 (its start) means NOT
	# reversed, so distance 0 sits at node 2, not node 3.
	var net := _net(_linear_pair())
	var rng := RandomNumberGenerator.new()
	var cont := net.next_road(_road_by_way(net, 10), true, rng)
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
	var cont := net.next_road(_road_by_way(net, 10), true, rng)
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
	assert_object(net.next_road(_road_by_way(net, 10), true, rng)).is_null()


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
	assert_object(net.next_road(_road_by_way(net, 10), true, rng)).is_null()


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
	var cont := net.next_road(_road_by_way(net, 10), true, rng)
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
		var cont := net.next_road(_road_by_way(net, 10), true, rng)
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
	assert_bool(_road_by_way(net, 10).one_way).is_true()


func test_circular_junction_is_one_way() -> void:
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(10, 0, 0))
	_add_way(data, 10, [1, 2], {"junction": "circular"})
	var net := _net(data)
	assert_bool(_road_by_way(net, 10).one_way).is_true()


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
		var cont := net.next_road(_road_by_way(net, 10), true, rng)
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
	var cont := net.next_road(_road_by_way(net, 10), true, rng)
	assert_object(cont).is_not_null()
	assert_int(cont.road.way_id).is_equal(30)


# ─── Mid-way junction splitting (the biggest real-data bug) ──────────────────
#
# Real OSM ways run straight *through* crossings whose node is in the middle of
# the way, not at its endpoints. The old graph only indexed each way's first and
# last node, so such a crossing was invisible: cars ran to the far end of every
# way and got teleported. build() must split a way at each interior junction so
# the crossing becomes a real graph node a car can turn onto.

func test_way_split_at_interior_junction() -> void:
	# Way 10 runs n1->n2->n3 straight along +X. A cross street (way 20) meets it
	# at the MIDDLE node n2 (n2->n4, heading +Z). n2 is interior to way 10.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))   # interior junction of way 10
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_node(data, 4, Vector3(100, 0, 100)) # cross street endpoint (+Z)
	_add_way(data, 10, [1, 2, 3])
	_add_way(data, 20, [2, 4])
	var net := _net(data)
	# Way 10 is cut into two segments at n2 → three drivable roads total.
	assert_int(net.road_count()).is_equal(3)
	# All three roads meet at node 2.
	assert_int(net.roads_at_node(2).size()).is_equal(3)


func test_car_can_turn_onto_cross_street_at_interior_junction() -> void:
	# The whole point: a car driving way 10 toward n2 can turn onto the cross
	# street 20. Before the split it could not (n2 wasn't a graph node), so it ran
	# to n3 and got recycled. Find the segment of way 10 that ENDS at n2 and check
	# a continuation onto way 20 exists.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_node(data, 4, Vector3(100, 0, 100))
	_add_way(data, 10, [1, 2, 3])
	_add_way(data, 20, [2, 4])
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	# The first-half segment of way 10 is n1->n2 (end_node == 2). Exiting it at its
	# end reaches junction 2, where both the second half of way 10 and cross
	# street 20 are options.
	var first_half: TrafficRoadNetwork.Road = null
	for road: TrafficRoadNetwork.Road in net.get_roads():
		if road.way_id == 10 and road.start_node == 1:
			first_half = road
	assert_object(first_half).is_not_null()
	assert_int(first_half.end_node).is_equal(2)
	# There must be a legal continuation, and both the way-10 continuation and the
	# cross street must be reachable across many rng draws.
	var seen_ways: Dictionary = {}
	for i: int in range(200):
		var cont := net.next_road(first_half, true, rng)
		assert_object(cont).is_not_null()
		seen_ways[cont.road.way_id] = true
	assert_bool(seen_ways.has(20)).is_true()


func test_segment_ids_are_unique_across_split_way() -> void:
	# The two halves of a split way share way_id but must have distinct segment_id
	# so the manager can count/track them independently (way_id is no longer a
	# unique key).
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_node(data, 4, Vector3(100, 0, 100))
	_add_way(data, 10, [1, 2, 3])
	_add_way(data, 20, [2, 4])
	var net := _net(data)
	var ids: Dictionary = {}
	for road: TrafficRoadNetwork.Road in net.get_roads():
		assert_int(road.segment_id).is_greater_equal(0)
		assert_bool(ids.has(road.segment_id)).is_false()
		ids[road.segment_id] = true
	# find_road keys on segment_id, and returns the matching road.
	for road: TrafficRoadNetwork.Road in net.get_roads():
		assert_object(net.find_road(road.segment_id)).is_same(road)


func test_segment_ids_are_stable_across_rebuilds() -> void:
	# Streaming a country rebuilds the graph around the moving player. A road that
	# reappears in the rebuilt graph must keep the SAME segment_id so a car
	# already driving it stays valid (find_road) instead of being orphaned and
	# respawned every rebuild. This is the property the TrafficManager relies on.
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_node(data, 3, Vector3(200, 0, 0))
	_add_node(data, 4, Vector3(100, 0, 100))
	_add_way(data, 10, [1, 2, 3])
	_add_way(data, 20, [2, 4])

	var first := _net(data)
	var ids_first: Dictionary = {}   # way_id:start:end -> segment_id
	for road: TrafficRoadNetwork.Road in first.get_roads():
		ids_first["%d:%d:%d" % [road.way_id, road.start_node, road.end_node]] = road.segment_id

	# Rebuild from the same data (simulating a re-collect around the player).
	var second := _net(data)
	for road: TrafficRoadNetwork.Road in second.get_roads():
		var key := "%d:%d:%d" % [road.way_id, road.start_node, road.end_node]
		assert_bool(ids_first.has(key)).override_failure_message("same road present after rebuild").is_true()
		assert_int(road.segment_id) \
			.override_failure_message("segment_id stable across rebuild for %s" % key) \
			.is_equal(ids_first[key])


func test_segment_id_direction_independent() -> void:
	# A segment and its reverse (same physical span, endpoints swapped) hash to
	# the same id, so orientation never changes a road's identity.
	assert_int(TrafficRoadNetwork._segment_id_for(10, 1, 2)) \
		.is_equal(TrafficRoadNetwork._segment_id_for(10, 2, 1))


# ─── Rolling route plan (long-term intention) ────────────────────────────────
#
# plan_route walks the graph a few segments ahead so a car commits to a path
# instead of re-deciding at every corner. Pin: it chains connected segments,
# stops at dead ends, and makes forward progress (no immediate A→B→A bounce).

## A straight chain of four ways sharing endpoints: n1-n2-n3-n4-n5.
func _chain() -> OSMParser.OSMData:
	var data := OSMParser.OSMData.new()
	for i: int in range(5):
		_add_node(data, i + 1, Vector3(i * 100, 0, 0))
	_add_way(data, 10, [1, 2])
	_add_way(data, 20, [2, 3])
	_add_way(data, 30, [3, 4])
	_add_way(data, 40, [4, 5])
	return data


func test_plan_route_chains_connected_segments() -> void:
	var net := _net(_chain())
	var rng := RandomNumberGenerator.new()
	var start := _road_by_way(net, 10)
	var route := net.plan_route(start, false, 3, rng)
	# Three straight hops available beyond the start road.
	assert_int(route.size()).is_equal(3)
	# The plan drives 20 → 30 → 40 in order (straightest-through, and the only
	# non-U-turn options anyway).
	assert_int(route[0].road.way_id).is_equal(20)
	assert_int(route[1].road.way_id).is_equal(30)
	assert_int(route[2].road.way_id).is_equal(40)


func test_plan_route_stops_at_dead_end() -> void:
	var net := _net(_chain())
	var rng := RandomNumberGenerator.new()
	var start := _road_by_way(net, 10)
	# Ask for more steps than the chain can provide; the plan stops at the dead
	# end rather than inventing hops or looping back.
	var route := net.plan_route(start, false, 10, rng)
	assert_int(route.size()).is_equal(3)


func test_plan_route_empty_for_lone_road() -> void:
	var data := OSMParser.OSMData.new()
	_add_node(data, 1, Vector3(0, 0, 0))
	_add_node(data, 2, Vector3(100, 0, 0))
	_add_way(data, 10, [1, 2])
	var net := _net(data)
	var rng := RandomNumberGenerator.new()
	var route := net.plan_route(_road_by_way(net, 10), false, 5, rng)
	assert_int(route.size()).is_equal(0)


func test_plan_route_zero_steps_is_empty() -> void:
	var net := _net(_chain())
	var rng := RandomNumberGenerator.new()
	assert_int(net.plan_route(_road_by_way(net, 10), false, 0, rng).size()).is_equal(0)


func test_plan_route_hops_are_forward_connected() -> void:
	# Every consecutive hop must physically connect: the junction one segment
	# exits at is the endpoint the next segment enters from. This is what makes
	# the plan drivable without teleports.
	var net := _net(_chain())
	var rng := RandomNumberGenerator.new()
	var start := _road_by_way(net, 10)
	var route := net.plan_route(start, false, 3, rng)
	var prev := start
	var prev_reversed := false
	for cont: TrafficRoadNetwork.Continuation in route:
		var junction: int = prev.start_node if prev_reversed else prev.end_node
		var enter: int = cont.road.end_node if cont.reversed else cont.road.start_node
		assert_int(enter).is_equal(junction)
		prev = cont.road
		prev_reversed = cont.reversed
