# Box Design

A tool for laying out controller enclosures (Web + Windows/Linux/macOS): pick a box, drag controller boards / power supplies onto it, add screw holes and zip-tie slots, then export the result as DXF (for CNC/laser cutting), PDF (1:1 scale reference/print), or an STL/3MF solid plate for 3D printing.

**Try it live: [computergeek1507.github.io/box_design_flutter](https://computergeek1507.github.io/box_design_flutter/)**

**My Website [https://boxdesign.scottnation.com/](https://boxdesign.scottnation.com/)**

## Download (Windows)

Grab a build from the [Releases page](https://github.com/computergeek1507/box_design_flutter/releases):

- A **versioned release** (e.g. `v1.2.0`) is a stable tagged build — pick the installer (`.exe`, installs normally and adds a Start Menu shortcut) or the portable zip (`BoxDesign-portable-*.zip`, just extract and run, no install).
- The **[`rolling`](https://github.com/computergeek1507/box_design_flutter/releases/tag/rolling)** pre-release is rebuilt automatically from the latest `main` on every push, so it always has the newest changes but isn't guaranteed stable.

Both are built by [`.github/workflows/windows-installer.yml`](.github/workflows/windows-installer.yml).

## Features

- **Box templates**: pick an enclosure from the palette; the canvas resizes to fit it.
- **Controller / power-supply templates**: drag onto the box, move, rotate.
- **Generic hole presets**: drag screw or zip-tie hole presets onto the box; edit size/position/rotation afterward.
- **Measure tool**: toggle it in the toolbar, then click or drag on the canvas to see the distance (in mm) between two points — clicks snap to nearby holes, template origins, or edges.
- **Import DXF**: bring in a real DXF as a new template (box, controller, or power-supply).
- **Export**: DXF (minimal ASCII R12) and PDF (1:1 scale vector) of the assembled design.
- **3D export**: STL and 3MF of the box outline extruded into a solid plate at a chosen thickness (the "Plate mm" field next to the export buttons), with every screw/zip-tie/slot hole — including holes baked into the box template itself and every mounting hole on a placed controller/power-supply template — cut all the way through. Ready to send straight to a 3D printer.
- **Save/Open**: project files as JSON.
- **Auto-updating template set**: the bundled templates work immediately offline, then the app quietly checks this repo's `assets/templates/` for anything newer/added and merges it in — no app update needed to get new boards.
- **Delete / copy / paste**: Delete removes the selected item; Ctrl/Cmd+C and Ctrl/Cmd+V duplicate it (offset so the copy is visible).

## Getting started

Requires the Flutter SDK (3.x).

```
flutter pub get
flutter run -d chrome    # or: -d windows / -d linux / -d macos
```

## Testing

```
flutter test
flutter analyze
```

## Scripts

`tool/gen_placeholder_templates.dart` regenerates the bundled placeholder templates under `assets/templates/`.

To turn a real DXF into a bundled template JSON (rather than importing it at runtime via the app's Import button), use `tool/dxf_to_json.py`:

```
pip install -r tool/requirements.txt
python tool/dxf_to_json.py board.dxf --id my_board --name "My Board" --category controller -o assets/templates/my_board.json
```

It reads LINE/CIRCLE/ARC/LWPOLYLINE directly, explodes block INSERTs, and flattens anything else (old-style POLYLINE, SPLINE, ELLIPSE) to a straight-segment polyline approximation. Pass `--scale 25.4` if the source DXF is in inches. Run with `--help` for all options.

If you have the board's actual KiCad project, `kicad_plugin/box_design_template_exporter.py` skips the DXF round trip entirely: it's a pcbnew Action Plugin (also runnable standalone via KiCad's bundled Python) that reads the Edge.Cuts outline and mounting holes straight from the `.kicad_pcb` file and emits the same template JSON, optionally registering it in `assets/templates/index.json` too. See `kicad_plugin/README.md` for install/usage.

Failing either of those, `tool/pcb_drawing_to_json.py` can extract an outline and mounting holes from a vendor PDF/SVG assembly drawing (printed/exported at 1:1 scale) by finding the board outline's longest straight edges and locating circular, edge-adjacent holes within a diameter range -- a measurement aid, not a certified digitizer, so its report and rendered preview should be checked against the source drawing before fabrication. Same `pip install -r tool/requirements.txt` setup as `dxf_to_json.py`; run with `--help` for options.
