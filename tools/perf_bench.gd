extends SceneTree

## Drives the real world scene for a fixed time and reports frame cost.
## Needs a window (no --headless) and vsync off to see true frame times:
##   godot --path . --disable-vsync --resolution 1280x720 -s tools/perf_bench.gd
##
## Env knobs, to A/B a single effect: BENCH_SECONDS, BENCH_NIGHT=1, and
## BENCH_OFF=ssr,ssao,ssil,glow,dof,msaa,shadows,fog (comma separated).

const WARMUP_S := 3.0

var _main: Node
var _t := 0.0
var _started := false
var _cpu: Array[float] = []
var _gpu: Array[float] = []
var _frame: Array[float] = []
var _draws: Array[float] = []
var _prims: Array[float] = []
var _objects: Array[float] = []
var _process_ms: Array[float] = []
var _physics_ms: Array[float] = []
var _seconds := 20.0
var _pre_t := 0
var _post_t := 0
var _min_clearance := INF
var _shot_taken := false
var _draw_ms: Array[float] = []
var _logic_ms: Array[float] = []


func _on_pre_draw() -> void:
	_pre_t = Time.get_ticks_usec()
	if _post_t > 0 and _started and _t >= WARMUP_S:
		_logic_ms.append((_pre_t - _post_t) / 1000.0)


func _on_post_draw() -> void:
	_post_t = Time.get_ticks_usec()
	if _started and _t >= WARMUP_S:
		_draw_ms.append((_post_t - _pre_t) / 1000.0)


func _initialize() -> void:
	if OS.has_environment("BENCH_SECONDS"):
		_seconds = OS.get_environment("BENCH_SECONDS").to_float()
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	_main.world_ready.connect(_on_ready)
	RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	RenderingServer.frame_pre_draw.connect(_on_pre_draw)
	RenderingServer.frame_post_draw.connect(_on_post_draw)


func _on_ready() -> void:
	_apply_overrides()
	_plan_route()
	_started = true
	_t = 0.0


## Car speed along the route (m/s). ~90 km/h, a typical cruising speed.
var DRIVE_SPEED := 25.0

var _route: SprintRoute
var _route_dist := 0.0


func _plan_route() -> void:
	if OS.has_environment("BENCH_SPEED"):
		DRIVE_SPEED = OS.get_environment("BENCH_SPEED").to_float()
	var car: CarController = _main.car
	_route = SprintRoute.plan(_main.traffic_manager.road_network(),
		car.global_position, car.global_transform.basis.z, 3000.0, 8000.0, 1000.0)
	_route_dist = 0.0
	if _route == null:
		push_error("BENCH: no route planned")
		quit(1)


## Slides the car along the road line instead of steering it, so the run never
## stalls on a wall and every run covers the same ground. Y and vertical speed
## stay with the physics so the wheels still ride the terrain.
func _physics_process(delta: float) -> bool:
	if not _started or _route == null or OS.get_environment("BENCH_FREE") == "1":
		return false
	_route_dist += DRIVE_SPEED * delta
	var pts := _route.points
	var d := _route_dist
	for i in pts.size() - 1:
		var seg := pts[i + 1] - pts[i]
		seg.y = 0.0
		var l := seg.length()
		if d <= l or i == pts.size() - 2:
			var dir := seg / maxf(l, 0.001)
			var car: CarController = _main.car
			var pos := pts[i] + seg * clampf(d / maxf(l, 0.001), 0.0, 1.0)
			var t := car.global_transform
			t.basis = Basis(Vector3.UP.cross(dir), Vector3.UP, dir)
			t.origin = Vector3(pos.x, maxf(t.origin.y, 0.0), pos.z)
			car.global_transform = t
			car.linear_velocity = dir * DRIVE_SPEED + Vector3.UP * car.linear_velocity.y
			car.angular_velocity = Vector3.ZERO
			return false
		d -= l
	_plan_route()
	return false


func _apply_overrides() -> void:
	if OS.has_environment("BENCH_SCALE"):
		root.scaling_3d_scale = OS.get_environment("BENCH_SCALE").to_float()
	print("BENCH window=%s viewport=%s screen_scale=%.1f 3d_scale=%.2f msaa=%d" % [
		DisplayServer.window_get_size(), root.get_visible_rect().size,
		DisplayServer.screen_get_scale(), root.scaling_3d_scale, root.msaa_3d])
	var off := OS.get_environment("BENCH_OFF").split(",", false)
	var pp: PostProcessing = _main.get_node("PostProcessing")
	var env: Environment = _main.get_node("WorldEnvironment").environment
	if "ssr" in off: pp.ssr_enabled = false
	if "ssao" in off: pp.ssao_enabled = false
	if "ssil" in off: pp.ssil_enabled = false
	if "glow" in off: pp.glow_enabled = false
	if "dof" in off: pp.dof_enabled = false
	if "fog" in off: env.fog_enabled = false
	if "shadows" in off:
		_main.get_node("DirectionalLight3D").shadow_enabled = false
	if "msaa" in off:
		root.msaa_3d = Viewport.MSAA_DISABLED
	if "minimap" in off:
		var mm: Control = _main.get_node("HUD/Minimap")
		mm.process_mode = Node.PROCESS_MODE_DISABLED
		mm.visible = false
	if "traffic" in off:
		_main.traffic_manager.process_mode = Node.PROCESS_MODE_DISABLED
	if "world" in off:
		_main.tile_manager.visible = false
	if "all_pp" in off:
		pp.enabled = false
	if OS.get_environment("BENCH_NIGHT") == "1":
		_main.sky_controller.set_day(false)


func _process(delta: float) -> bool:
	if not _started:
		return false
	_t += delta
	if _t < WARMUP_S:
		return false
	var car_pos: Vector3 = _main.car.global_position
	_min_clearance = minf(_min_clearance, car_pos.y - _main.tile_manager.get_terrain_height(car_pos))
	var vp := root.get_viewport_rid()
	_frame.append(delta * 1000.0)
	_cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(vp))
	_gpu.append(RenderingServer.viewport_get_measured_render_time_gpu(vp))
	_draws.append(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	_prims.append(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
	_objects.append(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
	_process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	_physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	if OS.has_environment("BENCH_SHOT") and _t >= WARMUP_S + _seconds - 1.0 and not _shot_taken:
		_shot_taken = true
		root.get_texture().get_image().save_png(OS.get_environment("BENCH_SHOT"))
	if _t >= WARMUP_S + _seconds:
		_report()
		FrameTracer.dump_summary()
		quit()
	return false


func _geometry_census() -> void:
	var tris := {}
	var insts := {}
	var stack: Array[Node] = [_main.tile_manager]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		stack.append_array(n.get_children())
		if n is MultiMeshInstance3D and n.multimesh != null and n.multimesh.mesh != null:
			var mm: MultiMesh = n.multimesh
			var key := "MM:" + String(n.name).rstrip("0123456789_")
			var t := 0
			t = mm.mesh.get_faces().size() / 3
			tris[key] = tris.get(key, 0) + t * mm.visible_instance_count if mm.visible_instance_count >= 0 else t * mm.instance_count
			insts[key] = insts.get(key, 0) + 1
		elif n is MeshInstance3D and n.mesh != null:
			var key := String(n.name).rstrip("0123456789_")
			if n.get_parent() != null and String(n.get_parent().name).begins_with("Tile_"):
				key = "TILE/" + key
			var t := 0
			if n.mesh is ArrayMesh:
				for s in n.mesh.get_surface_count():
					var il: int = n.mesh.surface_get_array_index_len(s)
					t += (il if il > 0 else n.mesh.surface_get_array_len(s)) / 3
			else:
				t = n.mesh.get_faces().size() / 3
			tris[key] = tris.get(key, 0) + t
			insts[key] = insts.get(key, 0) + 1
	var keys := tris.keys()
	keys.sort_custom(func(a, b): return tris[a] > tris[b])
	for k in keys.slice(0, 18):
		print("CENSUS %-28s tris=%8d nodes=%d" % [k, tris[k], insts[k]])


func _report() -> void:
	if OS.get_environment("BENCH_CENSUS") == "1":
		_geometry_census()
	var f := _frame.duplicate()
	f.sort()
	var avg := _avg(_frame)
	print("BENCH frames=%d fps=%.1f frame_ms avg=%.2f p50=%.2f p95=%.2f p99=%.2f max=%.2f" % [
		f.size(), 1000.0 / avg, avg, f[f.size() / 2], f[int(f.size() * 0.95)],
		f[int(f.size() * 0.99)], f[-1]])
	print("BENCH render cpu_ms=%.2f gpu_ms=%.2f draws=%.0f prims=%.0f objects=%.0f" % [
		_avg(_cpu), _avg(_gpu), _avg(_draws), _avg(_prims), _avg(_objects)])
	print("BENCH min_car_height_above_terrain=%.2f final_y=%.2f" % [_min_clearance, _main.car.global_position.y])
	print("BENCH split logic_ms=%.2f draw_ms=%.2f" % [_avg(_logic_ms), _avg(_draw_ms)])
	print("BENCH tiles=%d process_ms=%.2f physics_ms=%.2f" % [
		_main.tile_manager.get_loaded_tile_count(), _avg(_process_ms), _avg(_physics_ms)])


func _avg(a: Array[float]) -> float:
	var s := 0.0
	for v in a:
		s += v
	return s / maxf(1.0, a.size())
