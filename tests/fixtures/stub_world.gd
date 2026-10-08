extends Node

## Stands in for main.tscn in loading-screen tests: reports a couple of progress
## steps over a few frames, then declares itself ready.

signal loading_progress(fraction: float, status: String)
signal world_ready

## Set by a test to hold the world in its loading state.
static var hold: bool = false


func _ready() -> void:
	_build.call_deferred()


func _build() -> void:
	loading_progress.emit(0.5, "Building streets")
	await get_tree().process_frame
	while hold:
		await get_tree().process_frame
	loading_progress.emit(1.0, "Warming up")
	await get_tree().process_frame
	world_ready.emit()
