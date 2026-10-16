---
name: shortnote
description: Use when you need to annotate a screenshot or image (boxes, arrows, circles, text) and hand it to the user, show the user a visual note on their screen, or read what is drawn on their ShortNote canvas. ShortNote is a macOS menu-bar sticky-note paint tool; this skill drives its CLI (render / draw / get / export / clear).
---

# Driving ShortNote from the CLI

ShortNote is a macOS menu-bar sticky-note paint tool. A human draws on its canvas; **an agent can add shapes, text and images to that canvas through a shell CLI** (even while the human is typing or dragging, without breaking their input). There is no MCP server; this skill documents the CLI.

```sh
SN=$(command -v snote || echo /Applications/ShortNote.app/Contents/MacOS/ShortNote)
# `snote` is a symlink to the app's executable that the human can install from ShortNote's menu-bar menu.
# Without it, use the full path above (for a local build: build/ShortNote.app/Contents/MacOS/ShortNote).
```

## Which command

| Goal | Command | Needs the app running? |
|---|---|---|
| Annotate an image and produce a PNG (start here) | `render` | No. Headless |
| Add an annotation to the canvas the human is looking at | `draw` | Starts it if needed, without taking keyboard focus |
| Read what is on the canvas, as JSON | `get` | Yes |
| Get the canvas as a PNG | `export` | Yes |
| Remove everything drawn | `clear` | Yes |

**Iterate with `render`.** There is no CLI command to undo one `draw` (the human can undo each `draw` as a single step with Cmd+Z). `clear` removes **what the human drew too** (they can undo it with Cmd+Z). Put things on the human's canvas only once the result is settled.

## Operations JSON

```json
{"version": 1, "ops": [
  {"op": "rect", "x": 40, "y": 60, "w": 200, "h": 80, "color": "#ff0000", "size": 4},
  {"op": "line", "from": [240, 100], "to": [320, 160], "color": "#ff0000"},
  {"op": "text", "x": 325, "y": 150, "text": "Fix this", "color": "#ff0000", "fontSize": 20}
]}
```

- **Coordinates are canvas points (pt): origin at the top-left, x grows right, y grows down, fractions allowed.** A coordinate outside the canvas is not an error; it is clamped to the canvas edge. The result reports `clamped` (indices of operations that were clamped) and `skipped` (indices of operations that shrank to nothing after clamping and were not added).
- `color`: `"#RRGGBB"` or `"#RRGGBBAA"` (default `#000000`). `size`: stroke width in pt, 1–40 (default 4).

| `op` | Required | Optional | Meaning |
|---|---|---|---|
| `pen` | `points`: `[[x,y],...]` (1–10000 points) | `color` `size` | Freehand polyline (one point = a round dot) |
| `line` | `from` `to` (length ≥ 1) | `color` `size` | Straight line |
| `ellipse` | `x` `y` (top-left) `w` `h` (≥ 1) | `color` `size` | Outline of the ellipse inscribed in the box |
| `rect` | same as `ellipse` | `color` `size` | Rectangle outline |
| `text` | `x` `y` (top-left) `text` (1–10000 chars, `\n` for a newline, not whitespace-only) | `color` `fontSize` (8–200, default 18) | Text |
| `image` | `path` `x` `y` (top-left) | `w` `h` (≥ 1) | Image. Without `w`/`h`: natural size (shrunk to fit if larger than the canvas). With only one: aspect ratio kept |

- **An unknown `op`, an unknown key or an out-of-range value is an error** (typos are never silently ignored). If any operation is invalid, **nothing is applied**. The error carries the 0-based index of the offending operation (`op`).
- Limits: 1 MiB per request, 1000 ops, 20 images. UTF-8 JSON only.
- `rect` and `ellipse` are outlines only (no fill). To emphasize something, draw a frame around it.
- Text width is roughly `fontSize` per full-width (CJK) character and `fontSize × 0.55` per half-width character (a rule of thumb). After placing text, **always look at the output** to check it.
- **There is no arrow op. Build one from 3 `line`s**: the shaft (tail → tip) and two arrowhead strokes from the tip. With tip `T`, tail `S`, `u` the unit vector from `T` toward `S`, and `L` the head length (20–25 pt is a good size), the head ends are `T + L·rot(u, +25°)` and `T + L·rot(u, −25°)`. Illustrative numbers (not tied to any image): tail (600,400), tip (310,245), L=24 → head ends (324.4,264.2) and (334,246.3). Put a label about 5 pt beyond the tail, along `u` reversed.
- A stroke is centered on the shape's edge, extending `size/2` to each side. When **framing** a target without covering it, keep the frame at least `size/2` pt outside the target.

## Annotating an image (`render`)

```sh
$SN render [--size WxH] [--transparent] <background image | -> <ops JSON file | -> -o <out.png>
```

- Background `-` means a blank page. Ops `-` means read stdin: `echo '{...}' | $SN render shot.png - -o out.png`.
- On success, stdout is `{"path","width","height","clamped","skipped"}`. **Read the output PNG as an image and check placement and text overlap.**
- **Mapping coordinates to the image**: set `--size` to the background image's **pixel size** (WxH; both even, at least 960x640, long side at most 8192). The background then fills the canvas exactly, and **1 pt in the ops equals 2 pixels of the image** (`x_pt = image_x_px / 2`). The output PNG has the same pixel size as the image.
  - Example: to frame (1000, 600) px in a 2560x1440 px screenshot, use `--size 2560x1440` and `x=500, y=300` (pt).
  - This holds for Retina images (144 dpi) and 72 dpi images alike, as long as `--size` equals the pixel size.
  - Without `--size` the canvas is 960x640 px (480x320 pt). The image is shrunk to fit and centered (never enlarged); a different aspect ratio leaves margins.
  - An image smaller than 960x640 px cannot be matched with `--size` (below the minimum). It is centered at its natural size (pt) with margins; specify coordinates in canvas space, margins included.
- `--transparent`: make the margins (blank background, area outside the background image) transparent.
- Image viewers (the `read` tool, etc.) may show a large image downscaled (a scale factor is usually reported). To measure a position, multiply the displayed coordinates by that factor to get real pixels, then divide by 2 to get pt. Worked example: a button edge displayed at x=340 with a reported factor of 1.02 → 340 × 1.02 ≈ 347 px → 173.5 pt. After rewriting the same output path, a viewer may show a stale image; write to a new filename if in doubt.

## Driving the resident canvas

```sh
$SN draw ops.json     # or:  echo '{...}' | $SN draw -
$SN get
$SN export
$SN clear
```

- `draw` success: `{"added":N,"clamped":[...],"skipped":[...]}`. **One `draw` is one undo step (Cmd+Z) for the human.** Added items are stacked on top.
- `get`: `{"canvas":{"width","height"},"background":{"x","y","w","h"}|null,"editing":bool,"items":[...]}`. `items` are in stacking order (0 is the bottom) and have the same shape as the ops JSON plus `index`. Image items have no `path`, only position and size. The `background` box uses the same coordinate system (pt) as `draw`. **Decide where to draw over a background image from `get`'s `background`.**
- `editing: true` means the human is typing text or dragging. **`draw`, `clear` and `export` still work and the human's input is not broken** (text being typed lands above your items when committed). `get` and `export` reflect **committed** content only (text still being typed is not included).
- `export`: writes the committed canvas to a PNG and returns `{"path":"/tmp/shortnote/note-….png"}`. If nothing changed, the same path as last time.
- `clear`: `{"cleared":true|false}`.
- `draw` brings the window to the front but never takes keyboard focus.
- `get` and `export` do not change the canvas (safe to call repeatedly). In `get`, colors are normalized to uppercase `#RRGGBB`, an omitted `size` appears as its default (4), and numbers are rounded to 3 decimals.
- The `export` PNG is 2 pixels per canvas pt (a 480x320 pt canvas gives 960x640 px).
- The reply to `draw` does not say whether it had to launch the app; it simply succeeds.

## Errors and exit codes

On failure, stderr gets `{"error":{"code":"…","message":"…","op":N}}` (`op` only for operation problems).

| Exit | `code` | Meaning and what to do |
|---|---|---|
| 0 | — | Success |
| 1 | `invalid_ops` | The ops JSON is invalid. Read `message` and `op`, fix it (nothing was applied) |
| 2 | `usage` | Bad arguments. Read the usage in `message` |
| 3 | `unreachable` | Cannot reach the app. `get`, `export` and `clear` need a running app (ask the human to start it). If `draw` cannot reach it either, an old version without the socket may be running (ask the human to quit and relaunch ShortNote) |
| 4 | `io` | A file cannot be read or written (an `image`, the background, the output path, or the ops JSON file) |

## Cautions

- A relative `image` path is relative to the directory you call the CLI from, and may be written as-is for `draw` too (the CLI makes it absolute). However, with a relative image path, a large request (roughly 350 KB or more, with many decimals) may be refused; write absolute paths in that case.
- To open an image file named like a subcommand, pass it as a path such as `./draw`.
- The app operates on the human's canvas. **Do not erase what the human drew without being asked** (before `clear`, look at `get` and decide whether it is really needed).
- Nothing leaves the machine. The only channel is a Unix domain socket usable only by the same user (`~/Library/Application Support/ShortNote/`).
