# box_design template exporter (KiCad plugin)

A KiCad pcbnew Action Plugin that exports the currently-open board's outline
(Edge.Cuts) and mounting holes as a `box_design_flutter` template JSON --
the same format used by `assets/templates/*.json` and produced by
`tool/dxf_to_json.py`, just generated straight from the PCB instead of via a
DXF export/import round trip. Good for turning a
controller or receiver board's KiCad project into a droppable template for
the box designer.

## Install

1. Open KiCad's PCB Editor, then **Tools > External Plugins > Open Plugin
   Directory**. That opens the per-user scripting plugins folder (on
   Windows, normally `%APPDATA%\kicad\<version>\scripting\plugins\`).
2. Copy `box_design_template_exporter.py` into that folder.
3. Back in KiCad: **Tools > External Plugins > Refresh Plugins**.
4. It now shows up as **Export box_design Template...** under
   **Tools > External Plugins** (and as a toolbar button).

Requires KiCad 7 or newer (uses the modern `PCB_SHAPE`/`PAD` scripting API).
Tested against KiCad 9.

## Use

1. Open the controller/receiver board in the PCB Editor.
2. Run **Tools > External Plugins > Export box_design Template...**.
3. Fill in:
   - **Name** / **Template ID** -- the ID auto-fills from the name
     (slugified) until you edit it directly.
   - **Category** -- `controller`, `controllerAddon`, `receiver`, `powerSupply`,
     `powerDistribution`, or `box`.
   - **Min hole diameter (mm)** -- round/slotted holes smaller than this
     are skipped (default 1.4mm), so component leads and vias don't get
     pulled in as if they were mounting holes.
   - **Include NPTH / PTH / slotted holes** -- NPTH (non-plated mechanical)
     holes are on by default, since that's what `MountingHole` footprints
     use; turn on PTH too if the board uses plated holes for mounting.
   - **Layers as notes** -- tick the layers to export as drawing-layer notes:
     shown on the canvas, PDF and DXF for reference, but never cut. Front
     silkscreen is ticked by default; courtyards and the user layers are there
     too. See [Notes from layers](#notes-from-layers).
   - **Parts (ref letters)** -- reference-designator letters whose footprint
     graphics are exported, `J, U` by default (connectors and ICs: `J1`, `U3`,
     but not `JP1`). Leave it empty for every part plus the board's own loose
     graphics.
   - **Normalize origin** -- shifts geometry so the bounding box's min
     corner sits at (0, 0), matching every bundled template's convention.
     Leave this on unless you have a specific reason not to.
   - **Output file** -- if this plugin folder lives inside (or next to) a
     `box_design_flutter` checkout, it defaults straight into
     `assets/templates/`.
   - **Add/update entry in index.json** -- registers the new template in
     `assets/templates/index.json` so the app's palette picks it up.
4. Click **Export**. Any skipped/unsupported geometry (e.g. a Bezier curve
   left on Edge.Cuts) is listed in the Log box, along with a warning if no mounting holes were found. Results and errors appear there instead of in popups.

## Coordinate convention

KiCad's board space has Y increasing downward; this plugin flips Y on the
way out (`y_out = -y_kicad`), matching what KiCad's own DXF plotter does and
what `dxf_to_json.py` then passes through unchanged -- so a template
exported here lines up with one exported via
*File > Plot > DXF* + `dxf_to_json.py` for the same board.

## Notes from layers

Graphics on the ticked layers become the template's drawing layer
(`"annotations"`), so you can see where connectors, keep-clear areas and
labelled regions sit when placing cut-outs. They use the same origin shift and
Y flip as the plate, so they line up with the outline and holes.

| Layer choice | Source |
| --- | --- |
| Front / back silkscreen | Footprint (and, with no part filter, board) graphics on F/B.Silkscreen |
| Front / back courtyard | Footprint courtyard outlines on F/B.Courtyard |
| User drawings / comments | Graphics on Dwgs.User / Cmts.User |

| KiCad shape | Note |
| --- | --- |
| Line | line |
| Rectangle, or a 4-point axis-aligned polygon | rectangle |
| Circle | circle (outline) |
| Arc | short line segments (10 degrees each) |
| Other polygon | one line per edge |

Text and Bezier curves are skipped (and listed in the log); add text in
Template Maker's drawing layer instead. Back layers are exported as seen from
the front, not mirrored. The CLI equivalents are
`--note-layers silk_front,courtyard_front` (`none` for no notes; keys are
`silk_front`, `silk_back`, `courtyard_front`, `courtyard_back`,
`dwgs_user`, `cmts_user`) and `--part-refs J,U` (`--part-refs ""` for all parts).

## Standalone CLI (no KiCad GUI needed)

Useful for scripting or batch-generating templates from multiple boards.
Run it with KiCad's own bundled Python (it needs the `pcbnew` module):

```
"C:\Program Files\KiCad\9.0\bin\python.exe" box_design_template_exporter.py ^
    board.kicad_pcb --name "My Board" --category controller ^
    -o ..\flutter_app\assets\templates\my_board_controller.json --update-index
```

Run with `--help` for every option (hole size thresholds, PTH/NPTH/slot
toggles, `--note-layers`, `--part-refs`, `--no-normalize`, `--no-flip-y`, etc.) -- they mirror the GUI
dialog's fields.

## Notes / limitations

- Board outline shapes on Edge.Cuts are read as lines, arcs, circles,
  rectangles, and filled polygons; anything else (e.g. Bezier curves) is
  reported as a warning and skipped -- redraw it as lines/arcs first.
- Mounting holes come from footprint pads with a drill hole (round or
  oblong/slotted); pads with no hole (SMD) are ignored. Vias are not
  treated as mounting holes.
- Multiple disjoint Edge.Cuts outlines (e.g. a board with a separate
  keepout island) all get exported as independent entities -- there's no
  attempt to detect which one is "the" outline.
