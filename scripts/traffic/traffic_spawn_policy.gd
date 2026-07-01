class_name TrafficSpawnPolicy
extends RefCounted

## Pure policy for "which nearby roads should carry AI cars, and how many each".
##
## Split out from the TrafficManager node so the interesting decisions — cars
## follow roads within a radius of the player, and *the larger the street the
## more cars* — are unit-testable without a scene tree or physics. The manager
## calls select_active_roads() every refresh with the player position and the
## network, and gets back a plan it turns into spawned/recycled TrafficCars.

## One planned road: the road plus how many cars it should carry right now.
class RoadPlan:
	var road: TrafficRoadNetwork.Road
	var desired_cars: int

	func _init(r: TrafficRoadNetwork.Road, cars: int) -> void:
		road = r
		desired_cars = cars


## Choose the roads near `center` that should carry traffic and how many cars
## each wants, capped so the total never exceeds `max_cars`.
##
## Selection: a road is in range if any of its points is within `radius` of the
## center. Roads are then sorted widest-first so that when the car budget is
## tight the big arterials fill before the side streets — this is what makes
## "larger street = more cars" hold even under the global cap. Each road's share
## is its own capacity (already width-scaled in the network), clamped to at least
## one car for any in-range drivable road so quiet streets aren't completely dead.
static func select_active_roads(
		roads: Array[TrafficRoadNetwork.Road],
		center: Vector3,
		radius: float,
		max_cars: int) -> Array[RoadPlan]:
	var plans: Array[RoadPlan] = []
	if max_cars <= 0 or radius <= 0.0:
		return plans

	var in_range: Array[TrafficRoadNetwork.Road] = []
	for road: TrafficRoadNetwork.Road in roads:
		if _road_in_range(road, center, radius):
			in_range.append(road)

	# Widest first: arterials get their cars before residential side streets when
	# the budget runs out, so busy roads stay busy.
	in_range.sort_custom(_wider_first)

	var budget := max_cars
	for road: TrafficRoadNetwork.Road in in_range:
		if budget <= 0:
			break
		# At least one car for any in-range drivable road, but never more than the
		# road's width-scaled capacity nor the remaining global budget.
		var want: int = clampi(maxi(1, road.capacity), 1, budget)
		plans.append(RoadPlan.new(road, want))
		budget -= want
	return plans


## Total cars a plan asks for (handy for the manager and tests).
static func total_desired(plans: Array[RoadPlan]) -> int:
	var total := 0
	for p: RoadPlan in plans:
		total += p.desired_cars
	return total


# --- Internals -------------------------------------------------------------

## True if any centreline point of the road is within `radius` (XZ) of center.
static func _road_in_range(road: TrafficRoadNetwork.Road, center: Vector3, radius: float) -> bool:
	var r2 := radius * radius
	for p: Vector3 in road.points:
		var dx := p.x - center.x
		var dz := p.z - center.z
		if dx * dx + dz * dz <= r2:
			return true
	return false


## Sort comparator: wider roads first, breaking ties by length (longer first) so
## ordering is deterministic for the tests.
static func _wider_first(a: TrafficRoadNetwork.Road, b: TrafficRoadNetwork.Road) -> bool:
	if a.width == b.width:
		return a.length > b.length
	return a.width > b.width
