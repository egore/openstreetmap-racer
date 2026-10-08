class_name StreetNameTracker
extends RefCounted

## Decides when to announce the street the car is on.
##
## Fed the name of the road under the car a few times a second, it announces a
## street once the car has stayed on it for `settle_time`, so clipping the corner
## of a side street at a junction doesn't flash its name. Unnamed roads are
## ignored entirely: driving A -> unnamed link -> A announces A only once.

var settle_time: float = 0.6

var _announced: String = ""
var _candidate: String = ""
var _candidate_time: float = 0.0


## `street` is the current road's name, or "" when unnamed / off-road. Returns
## the name to announce now, or "".
func update(street: String, delta: float) -> String:
	if street == "" or street == _announced:
		_candidate = ""
		_candidate_time = 0.0
		return ""
	if street != _candidate:
		_candidate = street
		_candidate_time = 0.0
	_candidate_time += delta
	if _candidate_time < settle_time:
		return ""
	_announced = street
	_candidate = ""
	_candidate_time = 0.0
	return street


## Forget the current street, e.g. after the car was moved by hand, so the
## street it lands on is announced even if it is the same one.
func reset() -> void:
	_announced = ""
	_candidate = ""
	_candidate_time = 0.0
