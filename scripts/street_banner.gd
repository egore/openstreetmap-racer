extends Control

## Slides the name of the street the car has turned onto in under the HUD title,
## e.g. "PRIMARY ROAD / N57" over "Oostdijk", then fades it out.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")
const StreetNameTrackerScript := preload("res://scripts/street_name_tracker.gd")

@export var car_node_path: NodePath
@export var traffic_manager_node_path: NodePath

## Seconds between checks of the road under the car.
const POLL_INTERVAL := 0.25
const HOLD_TIME := 3.0

const CLASS_LABELS := {
	"motorway": "MOTORWAY",
	"motorway_link": "MOTORWAY LINK",
	"trunk": "TRUNK ROAD",
	"trunk_link": "TRUNK ROAD",
	"primary": "PRIMARY ROAD",
	"primary_link": "PRIMARY ROAD",
	"secondary": "SECONDARY ROAD",
	"secondary_link": "SECONDARY ROAD",
	"tertiary": "TERTIARY ROAD",
	"tertiary_link": "TERTIARY ROAD",
	"residential": "RESIDENTIAL STREET",
	"living_street": "LIVING STREET",
	"unclassified": "LOCAL ROAD",
	"service": "SERVICE ROAD",
}

var _car: Node3D = null
var _traffic: Node = null
var _tracker := StreetNameTrackerScript.new()
var _since_poll: float = 0.0
var _tween: Tween = null
## Authored x, which the slide-in eases back to.
var _rest_x: float = 0.0
var _detail_label: Label
var _name_label: Label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	modulate.a = 0.0
	_rest_x = position.x
	_build_ui()
	_car = get_node_or_null(car_node_path) as Node3D
	_traffic = get_node_or_null(traffic_manager_node_path)


func _process(delta: float) -> void:
	_since_poll += delta
	if _since_poll < POLL_INTERVAL or _car == null or _traffic == null:
		return
	var road: TrafficRoadNetwork.Road = _traffic.road_under(
		_car.global_position, _car.global_transform.basis.z)
	var street := display_name(road)
	var announce := _tracker.update(street, _since_poll)
	_since_poll = 0.0
	if announce != "":
		show_street(announce, detail_for(road))


## The name to show for a road: its name, else its route number, else "".
static func display_name(road: TrafficRoadNetwork.Road) -> String:
	if road == null:
		return ""
	return road.name if road.name != "" else road.ref


## The small line above the name: road class, plus the route number when the
## road also has a name.
static func detail_for(road: TrafficRoadNetwork.Road) -> String:
	var label: String = CLASS_LABELS.get(road.highway_type, "ROAD")
	if road.name != "" and road.ref != "":
		label += "  /  " + road.ref
	return label


func show_street(street: String, detail: String) -> void:
	_name_label.text = street
	_detail_label.text = detail
	if _tween != null and _tween.is_valid():
		_tween.kill()
	position.x = _rest_x - 16.0
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.tween_property(self, "modulate:a", 1.0, 0.25)
	_tween.tween_property(self, "position:x", _rest_x, 0.35) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.chain().tween_property(self, "modulate:a", 0.0, 0.6).set_delay(HOLD_TIME)


## Hide the banner and forget the current street, so it is announced afresh.
## Main calls this as the loading screen lifts: the street the car spawned on
## was announced unseen behind it.
func reset() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	modulate.a = 0.0
	position.x = _rest_x
	_tracker.reset()


func get_street_text() -> String:
	return _name_label.text


func _build_ui() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	var bar := ColorRect.new()
	bar.color = InterfaceTheme.ACCENT
	bar.custom_minimum_size = Vector2(3, 0)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(bar)
	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", -2)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(stack)
	_detail_label = InterfaceTheme.label("", 11, InterfaceTheme.ACCENT)
	_detail_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_detail_label.add_theme_constant_override("shadow_offset_y", 1)
	stack.add_child(_detail_label)
	_name_label = InterfaceTheme.label("", 34, InterfaceTheme.PAPER, true)
	_name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.75))
	_name_label.add_theme_constant_override("outline_size", 6)
	stack.add_child(_name_label)
