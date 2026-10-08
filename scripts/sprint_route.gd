class_name SprintRoute
extends RefCounted

## A point-to-point course through the real road graph, from where the car
## stands to a destination across town, with checkpoints along the way.
##
## Planning is a Dijkstra search over the traffic road graph (junction nodes
## joined by road segments, one-way streets only forwards). Of the junctions a
## suitable driving distance away, the one farthest from the start in a straight
## line becomes the finish, so the course crosses town rather than circling the
## block. Planning is deterministic: the same map and start always give the same
## course, which is what makes a best time on it meaningful.

const TrafficRoadNetworkScript := preload("res://scripts/traffic/traffic_road_network.gd")

## The driven line, start to finish, in world space.
var points := PackedVector3Array()
## Gate positions along `points`, in driving order; the last is the finish.
var checkpoints := PackedVector3Array()
## Driving distance (m) from the start to each checkpoint.
var checkpoint_distances := PackedFloat32Array()
var length: float = 0.0
## Stable identity of the course, for saving best times.
var id: String = ""


## Plan a course from `start`, initially driving along `heading`. Returns null
## when there is no road under the start or nowhere far enough to go.
static func plan(net: TrafficRoadNetworkScript, start: Vector3, heading: Vector3,
		min_length: float = 700.0, max_length: float = 1300.0,
		checkpoint_spacing: float = 150.0) -> SprintRoute:
	var start_road: TrafficRoadNetworkScript.Road = net.road_under(start, heading, 6.0)
	if start_road == null:
		var hit := net.nearest_point(start)
		if hit.is_empty():
			return null
		start_road = hit["road"]

	# Leave the start road in the direction the car faces (one-ways: forwards).
	var cut := _project(start_road.points, start)
	var tangent: Vector3 = start_road.points[cut["index"] + 1] - start_road.points[cut["index"]]
	var forwards := start_road.one_way or tangent.dot(heading) >= 0.0
	var lead := PackedVector3Array([cut["position"]])
	if forwards:
		lead.append_array(start_road.points.slice(cut["index"] + 1))
	else:
		var back := start_road.points.slice(0, cut["index"] + 1)
		back.reverse()
		lead.append_array(back)
	var exit_node: int = start_road.end_node if forwards else start_road.start_node

	var search := _dijkstra(net, exit_node, _polyline_length(lead), start_road.segment_id)
	var dist: Dictionary = search["dist"]
	var node_pos: Dictionary = search["pos"]
	node_pos[exit_node] = lead[lead.size() - 1]

	var target := -1
	var target_score := -INF
	for node: int in dist:
		var d: float = dist[node]
		var crow := _flat_distance(node_pos[node], start)
		# In the window, score by straight-line distance; outside it, only as a
		# fallback (strongly penalised) when nothing fits the window.
		var score := crow if d >= min_length and d <= max_length else d - 100000.0
		if score > target_score or (score == target_score and node < target):
			target = node
			target_score = score
	if target == -1:
		return null

	var route := SprintRoute.new()
	route.points = lead
	for step: Array in _path_to(search["prev"], target):
		var road: TrafficRoadNetworkScript.Road = step[0]
		var pts := road.points.duplicate()
		if step[1]:
			pts.reverse()
		route.points.append_array(pts.slice(1))
	route.length = _polyline_length(route.points)
	if route.length < min_length * 0.3:
		return null
	route._place_checkpoints(checkpoint_spacing)
	route.id = "%d_%d" % [start_road.segment_id, target]
	return route


## Driving distance from the start to a world position's closest point on the
## course, used to tell how far along the course the car is.
func distance_along(pos: Vector3) -> float:
	var cut := _project(points, pos)
	var along := 0.0
	for i: int in cut["index"]:
		along += _flat_distance(points[i], points[i + 1])
	return along + _flat_distance(points[cut["index"]], cut["position"])


func _place_checkpoints(spacing: float) -> void:
	checkpoints.clear()
	checkpoint_distances.clear()
	var next_at := spacing
	var travelled := 0.0
	for i: int in range(points.size() - 1):
		var seg := _flat_distance(points[i], points[i + 1])
		if seg < 0.001:
			continue
		# Leave room before the finish so the last two gates aren't stacked.
		while next_at <= travelled + seg and next_at <= length - spacing * 0.5:
			checkpoints.append(points[i].lerp(points[i + 1], (next_at - travelled) / seg))
			checkpoint_distances.append(next_at)
			next_at += spacing
		travelled += seg
	checkpoints.append(points[points.size() - 1])
	checkpoint_distances.append(length)


## Shortest driving distances from `source` (reached after `base` metres) to
## every reachable junction. Returns {dist, prev, pos}: prev maps a node to the
## [road, reversed] step that reached it, pos to its world position.
static func _dijkstra(net: TrafficRoadNetworkScript, source: int, base: float,
		excluded_segment: int) -> Dictionary:
	var dist := {source: base}
	var prev := {}
	var pos := {}
	var done := {}
	var frontier: Array[int] = [source]
	while not frontier.is_empty():
		var best_i := 0
		for i: int in range(1, frontier.size()):
			if dist[frontier[i]] < dist[frontier[best_i]]:
				best_i = i
		var node: int = frontier[best_i]
		frontier.remove_at(best_i)
		if done.has(node):
			continue
		done[node] = true
		for road: TrafficRoadNetworkScript.Road in net.roads_at_node(node):
			# No U-turn back down the road the car starts on.
			if road.segment_id == excluded_segment:
				continue
			var steps: Array = []
			if road.start_node == node:
				steps.append([road.end_node, false])
			if road.end_node == node and not road.one_way:
				steps.append([road.start_node, true])
			for step: Array in steps:
				var other: int = step[0]
				var d: float = dist[node] + road.length
				if not dist.has(other) or d < dist[other]:
					dist[other] = d
					prev[other] = [road, step[1]]
					pos[other] = road.points[0] if step[1] else road.points[road.points.size() - 1]
					frontier.append(other)
	return {"dist": dist, "prev": prev, "pos": pos}


static func _path_to(prev: Dictionary, target: int) -> Array:
	var path: Array = []
	var node := target
	while prev.has(node):
		var step: Array = prev[node]
		path.push_front(step)
		var road: TrafficRoadNetworkScript.Road = step[0]
		node = road.end_node if step[1] else road.start_node
	return path


## Closest point on a polyline to `pos` in the ground plane: {index, position}.
static func _project(pts: PackedVector3Array, pos: Vector3) -> Dictionary:
	var target := Vector2(pos.x, pos.z)
	var best := {"index": 0, "position": pts[0]}
	var best_d2 := INF
	for i: int in range(pts.size() - 1):
		var a := Vector2(pts[i].x, pts[i].z)
		var b := Vector2(pts[i + 1].x, pts[i + 1].z)
		var seg_len := a.distance_to(b)
		if seg_len < 0.001:
			continue
		var q := Geometry2D.get_closest_point_to_segment(target, a, b)
		var d2 := target.distance_squared_to(q)
		if d2 < best_d2:
			best_d2 = d2
			best = {"index": i, "position": pts[i].lerp(pts[i + 1], a.distance_to(q) / seg_len)}
	return best


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))


static func _polyline_length(pts: PackedVector3Array) -> float:
	var total := 0.0
	for i: int in range(pts.size() - 1):
		total += _flat_distance(pts[i], pts[i + 1])
	return total
