class_name ProfileStore
extends RefCounted

## The player's saved records and lifetime stats, in a small ConfigFile under
## user://. Missing or unreadable files just mean a fresh profile.

const DEFAULT_PATH := "user://profile.cfg"

var path: String
var _cfg := ConfigFile.new()


func _init(p_path: String = DEFAULT_PATH) -> void:
	path = p_path
	if FileAccess.file_exists(path):
		_cfg.load(path)


func best_score(mode_key: String) -> int:
	return int(_cfg.get_value("best", mode_key, 0))


func runs(mode_key: String) -> int:
	return int(_cfg.get_value("runs", mode_key, 0))


func total_distance_m() -> float:
	return float(_cfg.get_value("stats", "distance_m", 0.0))


## Record a finished run. Returns true when it beats the previous best; a first
## run only counts as a best if it scored anything.
func submit_score(mode_key: String, score: int) -> bool:
	_cfg.set_value("runs", mode_key, runs(mode_key) + 1)
	if score <= best_score(mode_key):
		return false
	_cfg.set_value("best", mode_key, score)
	return true


## Best (lowest) time in seconds, or 0 when there is none yet.
func best_time(key: String) -> float:
	return float(_cfg.get_value("best_time", key, 0.0))


## Record a finished timed run. Returns true when it is faster than the best.
func submit_time(key: String, seconds: float) -> bool:
	_cfg.set_value("runs", key, runs(key) + 1)
	var best := best_time(key)
	if best > 0.0 and seconds >= best:
		return false
	_cfg.set_value("best_time", key, seconds)
	return true


func add_distance(meters: float) -> void:
	_cfg.set_value("stats", "distance_m", total_distance_m() + maxf(meters, 0.0))


func save() -> Error:
	return _cfg.save(path)
