# Make It Forza — Status

This started as a to-do list for pushing the visuals toward a Forza-grade look.
Most of it has since shipped; this version tracks what's **done** vs. what's
**still open**, so it stays useful as a checklist rather than a stale wish-list.

## Where we started vs. Forza

Forza's "look" comes from a few things stacked together: PBR materials, strong
post-processing (bloom/HDR/tonemap/SSAO/SSR), high-contrast lighting with crisp
shadows, and reflective surfaces (car paint, wet roads). The engine already did
the hard structural work (procedural roads, terrain draping, day/night); the gap
was surface polish and post-processing — and most of that is now in.

## Highest-leverage changes

### 1. Post-processing on the Environment — ✅ DONE
Implemented as `scripts/post_processing.gd` on the `PostProcessing` node, each
effect an independent exported toggle, crossfading with day/night:
- ✅ **Glow/Bloom** — sun, headlights, street-lamp emissives, lit windows bloom (harder at night)
- ✅ **SSAO** — contact shadows where buildings meet ground / under cars
- ✅ **SSIL** — screen-space indirect bounce light
- ✅ **SSR** — screen-space reflections (glossy roads, car paint, glass) — the usual frame-rate cliff
- ✅ **Adjustments** — ACES tonemap + exposure/contrast/saturation grade
- ✅ **Far depth-of-field** blur (via `CameraAttributesPractical` on the player camera)

### 2. Real PBR / procedural materials — ✅ DONE (texture-free approach)
Rather than image texture maps, the surfaces use **procedural-PBR shaders**
(world-space noise, no image files) — same spirit as the asphalt shader:
- ✅ **Asphalt** — grain + varied roughness + faked bump, and a wet sheen driven by the global `wetness` uniform (wet roads collapse to a near-mirror for SSR)
- ✅ **Buildings** — `building_wall.gdshader` / `roof.gdshader` via `BuildingMaterialFactory`: plaster / masonry (brick courses) / panel walls, and tile / membrane / standing-seam roofs keyed off OSM `building:material` / `roof:material`
- ✅ **Terrain/grass** — `terrain.gdshader` two-tint patchiness + blade grain, with a damp sheen when wet
- ↔️ *Open*: real tiling normal/roughness **image** maps were the original idea; the procedural route was taken instead. Swap in image maps only if a surface needs detail the noise can't fake.

### 3. Car paint shader (hero asset) — ✅ DONE
`scripts/car_paint.gd` swaps the imported flat materials for PBR by surface name:
metallic base coat under a clear-coat lacquer (body), near-mirror dark glass,
mirror chrome, self-illuminated rear lights (bloom at night), matte tyres. Reflects
the world under SSR. Body colour exposed as `paint_color`.

### 4. Lighting contrast & shadows — ✅ DONE
Day/night presets in `sky_controller.gd` drive high-contrast sun + the ACES grade;
CSM shadows configured in the scene. (Further split-distance tuning is always available.)

### 5. Driving feel & driver aids — ✅ DONE
Forza's identity is as much the *car* as the picture. The visuals shipped first;
this closes the input/handling half:
- ✅ **Analog input / gamepad** — steering, throttle and brake are bound to stick
  and trigger axes (`project.godot`), so `get_action_strength` returns real
  partial values instead of 0/1. Deadzones tightened for fine control.
- ✅ **Steering rack** (`scripts/steering_model.gd`) — the wheels no longer snap
  to full lock the frame a key goes down. Rate-limited turn-in, faster
  self-centring (caster), and a speed-sensitive lock taper scaled to the car's
  own top speed.
- ✅ **Countersteer assist** — steers into a slide proportionally to slip, and
  yields once the driver corrects, so drifts are catchable rather than a coin flip.
- ✅ **TCS / ABS / stability control** (`scripts/driving_assists.gd`) — Forza's
  assist suite. Each independently switchable; all intervene smoothly and
  partially so the car never feels like it stalled or is fighting your hands. The
  handbrake deliberately bypasses ABS and mostly escapes stability control, so
  deliberate drifting still works.

### 6. Instrument cluster — ✅ DONE
The plain "0 km/h" / "N" corner labels are gone, replaced by a drawn dial
(`scripts/dial_cluster.gd` + `scripts/tachometer_model.gd`):
- ✅ **Swept rev counter** with tick marks, a red zone, and a needle that eases
  rather than teleporting — so an upshift reads as a quick sweep down, the
  familiar tacho sawtooth.
- ✅ **Shift light** — the rim, hub and needle wash to red as the limiter nears,
  ramping with how deep into the redline the engine is.
- ✅ **Gear in the hub** and a digital speed readout below it.
- ✅ **TC / ABS / ESC telltales** — lit while the corresponding driver aid is
  intervening, so the assists are visible instead of invisible magic.

Revs are derived from the existing `Transmission` gear band (bottom of a gear =
just-shifted revs, top = the limiter), so the dial needs no new physics. Drawn
with Godot primitives, matching the project's texture-free approach.

## Medium-effort polish

- ✅ **Wet-road / rain weather mode** — `scripts/weather_controller.gd`, global `wetness` uniform, toggle with **F5** (or the pause-menu checkbox). Reuses SSR beautifully.
- ✅ **Depth-of-field far-blur** — done (see post-processing).
- ✅ **Crosswalks / lane paint** — shipped as **shader-painted** markings (`RoadLaneSpec` longitudinal lines + `RoadMarkingSpec` zebra/stop/give-way bands in `asphalt.gdshader`), not modelled 3D geometry. The z-fighting that plagued overlapping ribbons was solved with Mapnik-style `render_priority` draw ordering.
- ✅ **Camera feel** — trauma-based **camera shake** on impact/landing (`camera_shake.gd`) and **speed-scaled FOV** expansion (`car_controller.gd`) add the racing-game sensation.
- ✅ **Impact feedback** — one-shot spark/debris **impact particles** (`impact_particles.gd`) plus **tire-screech** and **impact** audio (`car_audio_triggers.gd`).

### Still open
- ↔️ **Motion blur** at speed — not implemented.
- ↔️ **Better trees / vegetation** — still placeholder boxes / simple models; instanced billboard/LOD trees would fill the world.
- ↔️ **Reflection probes** in dense areas — SSR only reflects on-screen geometry; probes would give off-screen local reflections.
- ↔️ **Real 3D crosswalk/lane geometry** — currently shader bands; modelled geometry remains an option if the shader bands ever look flat under grazing angles.

## Recommendation

The core Forza-look stack (post-processing + PBR-ish surfaces + car paint + wet
roads + contrast lighting) is in. The remaining items are incremental world-dressing
(vegetation, reflection probes, motion blur) rather than the big perceptual jumps.
