class_name RecoveryTracker
extends RefCounted

## Remembers where the car was last driving safely, so a stuck, wedged or flipped
## car can be put back on the road ("recover", R).
##
## Pure logic: each physics frame the car reports its position, heading and
## whether the moment counts as safe (upright, wheels down, on a road, moving).
## The tracker keeps a short trail of such breadcrumbs and, when asked, hands
## back the one to recover to.
##
## The newest breadcrumb is usually the wrong answer: it was laid a fraction of a
## second before the crash, pointing straight at the wall. So recovery prefers the
## newest breadcrumb that is at least `min_age` old, and drops everything newer
## than the point it used, so a second press doesn't jump forward into the crash.

## A remembered safe pose. `forward` is the car's flat nose direction.
class SafePoint:
	extends RefCounted
	var position: Vector3
	var forward: Vector3
	var time: float

	func _init(p_position: Vector3, p_forward: Vector3, p_time: float) -> void:
		position = p_position
		forward = p_forward
		time = p_time


## Seconds between breadcrumbs. Frequent enough to land near where things went
## wrong, sparse enough that the trail covers several seconds of driving.
var sample_interval: float = 0.5
## Breadcrumbs kept. With the interval above this is ~10 s of safe driving.
var max_points: int = 20
## Preferred minimum age (s) of the breadcrumb to recover to. Two seconds back is
## far enough to undo the line that led into the crash.
var min_age: float = 2.0
## A new breadcrumb is skipped unless the car moved at least this far (m) from
## the previous one, so creeping along a kerb doesn't flush the useful history.
var min_spacing: float = 3.0

var _points: Array[SafePoint] = []
var _time: float = 0.0
var _since_sample: float = INF


## Advance the clock and, if this frame is safe and a breadcrumb is due, record it.
func update(delta: float, position: Vector3, forward: Vector3, is_safe: bool) -> void:
	_time += delta
	_since_sample += delta
	if not is_safe or _since_sample < sample_interval:
		return
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length_squared() < 0.0001:
		return
	if not _points.is_empty() and _points.back().position.distance_to(position) < min_spacing:
		return
	_record(position, flat.normalized())


## Record a breadcrumb unconditionally, e.g. the spawn point, so there is always
## somewhere to recover to even before the player has driven anywhere.
func remember(position: Vector3, forward: Vector3) -> void:
	var flat := Vector3(forward.x, 0.0, forward.z)
	if flat.length_squared() < 0.0001:
		flat = Vector3.FORWARD
	_record(position, flat.normalized())


## The breadcrumb to recover to, or null when none has been recorded. Points
## newer than the returned one are discarded (see the class comment).
func take_recovery_point() -> SafePoint:
	if _points.is_empty():
		return null
	var chosen: SafePoint = _points[0]
	for i: int in range(_points.size() - 1, -1, -1):
		if _time - _points[i].time >= min_age:
			chosen = _points[i]
			break
	_points.resize(_points.find(chosen) + 1)
	# The car is now sitting on the chosen point; don't immediately lay a
	# duplicate on top of it.
	_since_sample = 0.0
	return chosen


func point_count() -> int:
	return _points.size()


func clear() -> void:
	_points.clear()
	_since_sample = INF


func _record(position: Vector3, forward: Vector3) -> void:
	_points.append(SafePoint.new(position, forward, _time))
	if _points.size() > max_points:
		_points.pop_front()
	_since_sample = 0.0
