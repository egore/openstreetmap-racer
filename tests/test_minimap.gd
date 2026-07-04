extends GdUnitTestSuite

## Unit tests for the Minimap north-indicator direction math.
##
## The minimap rotates with the car: everything is drawn relative to the car's
## heading so the car's forward always points up. The red north arrow must
## therefore counter-rotate so it keeps pointing at true world north. This
## direction is produced by Minimap.north_screen_direction(); these tests pin
## it against the same rotation convention used by _world_to_minimap() so a
## future refactor can't silently send the arrow the wrong way.

const Minimap := preload("res://scripts/minimap.gd")


func test_north_direction_is_up_when_heading_north() -> void:
	# car_angle == 0 means the car faces +Z (world north maps to screen up).
	# Screen up is -Y, so the north arrow points straight up (0, +1) in the
	# minimap's draw space where +Y is down... note: north_dir uses cos(0)=+1
	# on the Y component, matching _world_to_minimap's sy for a north point.
	var dir := Minimap.north_screen_direction(0.0)
	assert_float(dir.x).override_failure_message("north x is 0 when heading north").is_equal_approx(0.0, 0.0001)
	assert_float(dir.y).override_failure_message("north y is +1 when heading north").is_equal_approx(1.0, 0.0001)


func test_north_direction_is_unit_length() -> void:
	# Must always be a unit vector so the arrow sits a fixed distance from the rim.
	for deg: int in range(0, 360, 15):
		var dir := Minimap.north_screen_direction(deg_to_rad(deg))
		assert_float(dir.length()).override_failure_message(
			"north direction is unit length at %d deg" % deg).is_equal_approx(1.0, 0.0001)


func test_north_direction_counter_rotates_with_heading() -> void:
	# Rotating the car by +90 degrees must swing the north arrow by -90 degrees
	# on screen (the world stays fixed while the map spins under it).
	var at_zero := Minimap.north_screen_direction(0.0)
	var at_quarter := Minimap.north_screen_direction(deg_to_rad(90.0))
	# Heading +90 deg: north_dir = (-sin90, cos90) = (-1, 0).
	assert_float(at_quarter.x).override_failure_message("north x is -1 at 90 deg").is_equal_approx(-1.0, 0.0001)
	assert_float(at_quarter.y).override_failure_message("north y is 0 at 90 deg").is_equal_approx(0.0, 0.0001)
	# The two directions must be perpendicular (90 deg apart).
	assert_float(at_zero.dot(at_quarter)).override_failure_message(
		"90 deg heading change rotates north by 90 deg").is_equal_approx(0.0, 0.0001)


func test_north_direction_matches_world_to_minimap_convention() -> void:
	# Independently reproduce the mapping a world point due north of the car
	# (dx=0, dz=-1) undergoes in _world_to_minimap(), then normalize. The north
	# arrow direction must agree with it for arbitrary headings.
	for deg: int in range(0, 360, 30):
		var car_angle := deg_to_rad(deg)
		var sin_a := sin(car_angle)
		var cos_a := cos(car_angle)
		# dx = 0, dz = -1 (north is world -Z).
		var sx := -(0.0 * cos_a - (-1.0) * sin_a)
		var sy := -(0.0 * sin_a + (-1.0) * cos_a)
		var expected := Vector2(sx, sy).normalized()
		var dir := Minimap.north_screen_direction(car_angle)
		assert_float(dir.distance_to(expected)).override_failure_message(
			"north direction matches _world_to_minimap at %d deg" % deg).is_less(0.0001)
