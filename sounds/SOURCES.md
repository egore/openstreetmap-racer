All sound files were downloaded from https://freesound.org.

## Game assets (in this folder)

| Asset | Source file | Processing |
|---|---|---|
| car_engine.mp3 | 512558__modman34__car-engine.mp3 | None — byte-for-byte copy of the original (20.09s, 44.1 kHz stereo, 128 kbps MP3), just renamed. Looped and pitch-shifted by RPM as the single-gear engine sample via `engine_sound.gd`. |
| dirt_driving.ogg | 268175__gis_sweden__gravel1_kilanasan_sweden.wav | Transcoded whole (no trim; 2.56s, 44.1 kHz stereo) from the source WAV (1411 kbps PCM) to Vorbis OGG (~355 kbps, 452 KB → 114 KB). Looped while any wheel is on grass, with speed-driven volume/pitch, via `car_controller.gd`. |
| tire_screech.wav | 71737__audible-edge__chrysler-lhs-tire-squeal-02-04-25-2009.wav | Cut the first real tyre squeal (4.05–4.78s — a clear ~1 kHz tonal squeal), mono 44.1 kHz, +6 dB gain (~-16 dB mean / -2.6 dB peak), 10 ms edge fades for a click-free loop. Played as the looping tyre-screech via `car_controller.gd`. |
| impact.wav | 682371__pnmcarrierailfan__car-crash-elements-sideswipe-01.mp3 | Trimmed to the impact body (0–0.78s, the tail was silent), mono 44.1 kHz, loudness-normalised down from the original 0 dB clipping to a game-safe level (peak ~-4 dB). Played as the crash one-shot via `car_controller.gd`. |

`tire_screech.wav` is looped at runtime (`AudioStreamWAV.LOOP_FORWARD`); `impact.wav`
is a one-shot. Both are WAV rather than OGG because this ffmpeg build lacks a
working Vorbis encoder, and Godot imports WAV losslessly and natively.

**Runtime looping gotcha:** when enabling a loop on an `AudioStreamWAV` in code,
`loop_end` must be set to the real last sample frame (data bytes / bytes-per-frame),
NOT `-1`. The `-1` "end of sample" sentinel is only valid in the import settings;
at runtime it creates an empty `[0, -1]` loop and the stream plays completely
silent while still reporting `playing = true`. `car_controller.gd` computes the
frame count via `_wav_frame_count()` for exactly this reason.

## Raw sources

The unedited originals are kept in the top-level `raw_sources/` directory (with a
`.gdignore` so Godot skips them and an `exclude_filter` so they never ship in an
export). Keep them there for re-cutting other segments later. Notably:

- `492940__timbre__short-scrape-like-car-body-or-window-scratch.flac` — four
  metallic "clear-coat scratch" scrapes (~5.2 kHz, brighter/harsher than a tyre
  squeal). Currently UNUSED; a good candidate for a future body/building-scrape
  or sideswipe-grind sound rather than tyre slip.
- `71737__audible-edge__chrysler-lhs-tire-squeal-02-04-25-2009.wav` — three real
  rubber tyre squeals with a strong ~1 kHz tonal component: one quieter at
  4.02–4.81s, a louder one at 5.85–6.28s, and a decaying tail after ~6.6s. The
  first squeal (4.05–4.78s) became `tire_screech.wav`. (Note: the region after
  ~7.9s is just a quiet decaying tail, NOT a squeal — don't use it.)
- `682371__pnmcarrierailfan__car-crash-elements-sideswipe-01.mp3` — one sideswipe
  crash impact. Became `impact.wav`.
