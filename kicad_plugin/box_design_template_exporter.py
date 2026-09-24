#!/usr/bin/env python3
"""Box Design template exporter -- a KiCad pcbnew Action Plugin.

Generates a box_design_flutter template JSON (the same shape as the files in
assets/templates/*.json, and produced by tool/dxf_to_json.py) directly from
the board that's currently open in KiCad, instead of going through a DXF
export/import round trip:

    {
      "id": "...",
      "name": "...",
      "category": "controller" | "controllerAddon" | "receiver" | "powerSupply" | "powerDistribution" | "box",
      "entities": [
        {"type": "line", "start": {"x":.., "y":..}, "end": {"x":.., "y":..}},
        {"type": "circle", "center": {"x":.., "y":..}, "radius": ..},
        {"type": "arc", "center": {...}, "radius": .., "startAngle": .., "endAngle": ..},
        {"type": "polyline", "closed": bool, "vertices": [{"x":.., "y":.., "bulge":..}, ...]}
      ],
      "annotations": [
        {"type": "line", "start": {"x":.., "y":..}, "end": {"x":.., "y":..}},
        {"type": "rect", "x": .., "y": .., "width": .., "height": ..},
        {"type": "circle", "center": {"x":.., "y":..}, "radius": ..}
      ]
    }

The board outline comes from the Edge.Cuts layer; mounting/mechanical holes
come from footprint pads (round NPTH holes by default, with an option to
also pull in round/slotted PTH pads above a size threshold). Graphics on
the chosen layers (silkscreen by default; also courtyard and the user layers) become "annotations" -- lines, rectangles, circles, arcs (as
short segments) and polygons on the drawing layer, drawn for reference but
never cut.

Install (KiCad plugin):
    Copy this file into KiCad's scripting/plugins folder, e.g. on Windows:
        %APPDATA%\\kicad\\<version>\\scripting\\plugins\\
    or use Tools > External Plugins > Open Plugin Directory from the PCB
    Editor to find the right folder, then Tools > External Plugins > Refresh.
    It then shows up as "Export box_design Template..." under
    Tools > External Plugins.

Standalone CLI (no KiCad GUI needed, useful for scripting/CI):
    "C:\\Program Files\\KiCad\\9.0\\bin\\python.exe" box_design_template_exporter.py ^
        board.kicad_pcb --id my_board_controller --name "My Board" --category controller
    Run with --help for all options.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
from pathlib import Path

try:
    import pcbnew
except ImportError:  # pure-geometry helpers below are still importable/testable
    pcbnew = None

# Must match TemplateCategory in lib/models/controller_template.dart.
VALID_CATEGORIES = ("controller", "controllerAddon", "receiver", "powerSupply", "powerDistribution", "box")

PLUGIN_DIR = Path(__file__).resolve().parent

# Layers that can be exported as drawing-layer notes: key -> (GUI label,
# pcbnew layer attribute).
NOTE_LAYERS = {
    "silk_front": ("Front silkscreen (F.Silkscreen)", "F_SilkS"),
    "silk_back": ("Back silkscreen (B.Silkscreen)", "B_SilkS"),
    "courtyard_front": ("Front courtyard (F.Courtyard)", "F_CrtYd"),
    "courtyard_back": ("Back courtyard (B.Courtyard)", "B_CrtYd"),
    "dwgs_user": ("User drawings (Dwgs.User)", "Dwgs_User"),
    "cmts_user": ("User comments (Cmts.User)", "Cmts_User"),
}
DEFAULT_NOTE_LAYERS = ("silk_front",)


def parse_note_layers(text: str) -> tuple[str, ...]:
    """"silk_front, courtyard_front" -> ("silk_front", "courtyard_front"); "none" or "" -> ()."""
    keys = tuple(k.strip().lower() for k in re.split(r"[,\s]+", text or "") if k.strip())
    keys = tuple(k for k in keys if k != "none")
    bad = [k for k in keys if k not in NOTE_LAYERS]
    if bad:
        raise ValueError(f"unknown note layer(s) {bad}; choose from {list(NOTE_LAYERS)}")
    return keys


def find_templates_dir() -> Path | None:
    """Best-effort: if this plugin lives inside (or next to) a
    box_design_flutter checkout, point the default output straight at
    assets/templates instead of making the user browse for it every time.
    """
    for base in (PLUGIN_DIR, *PLUGIN_DIR.parents):
        for candidate in (base / "flutter_app" / "assets" / "templates", base / "assets" / "templates"):
            if candidate.is_dir():
                return candidate
    return None


def slugify(name: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "_", name.strip()).strip("_").lower()
    return s or "template"


# ---------------------------------------------------------------------------
# Pure geometry helpers -- no pcbnew dependency, unit-testable on their own.
# All points are plain (x, y) tuples in mm, already in output (Y-flipped if
# requested) coordinate space.
# ---------------------------------------------------------------------------

def _norm_deg(a: float) -> float:
    a = a % 360.0
    return a + 360.0 if a < 0 else a


def arc_angles_from_points(center, start, end, mid):
    """Return (startAngle, endAngle) in degrees such that sweeping
    counter-clockwise from startAngle to endAngle passes through mid --
    matching box_design's ARC convention (DxfArc.toPoints in
    lib/models/dxf_entity.dart always sweeps CCW, adding 360 deg if the raw
    sweep comes out <= 0).
    """
    def ang(p):
        return _norm_deg(math.degrees(math.atan2(p[1] - center[1], p[0] - center[0])))

    a_start, a_end, a_mid = ang(start), ang(end), ang(mid)

    sweep = (a_end - a_start) % 360.0
    if sweep <= 1e-9:
        sweep = 360.0
    rel_mid = (a_mid - a_start) % 360.0
    if rel_mid <= sweep + 1e-6:
        return a_start, a_start + sweep

    # mid doesn't lie on the CCW arc from start->end: the arc actually runs
    # the other way around, so swap which endpoint we call "start".
    sweep2 = (a_start - a_end) % 360.0
    if sweep2 <= 1e-9:
        sweep2 = 360.0
    return a_end, a_end + sweep2


def line_entity(start, end) -> dict:
    return {"type": "line", "start": {"x": start[0], "y": start[1]}, "end": {"x": end[0], "y": end[1]}}


def circle_entity(center, radius) -> dict:
    return {"type": "circle", "center": {"x": center[0], "y": center[1]}, "radius": radius}


def arc_entity(center, radius, start, end, mid) -> dict:
    a0, a1 = arc_angles_from_points(center, start, end, mid)
    return {"type": "arc", "center": {"x": center[0], "y": center[1]}, "radius": radius,
            "startAngle": a0, "endAngle": a1}


def polyline_entity(points, closed: bool, bulges=None) -> dict:
    verts = []
    for i, p in enumerate(points):
        b = bulges[i] if bulges else 0.0
        verts.append({"x": p[0], "y": p[1], "bulge": b})
    return {"type": "polyline", "closed": closed, "vertices": verts}


def line_annotation(start, end) -> dict:
    """A drawing-layer note (see lib/models/annotation.dart): shown on the
    canvas/PDF/DXF but never cut, unlike the "entities" that make up the plate.
    """
    return {"type": "line", "start": {"x": start[0], "y": start[1]}, "end": {"x": end[0], "y": end[1]}}


def rect_annotation(a, c) -> dict:
    """Rectangle note from two opposite corners."""
    return {"type": "rect", "x": min(a[0], c[0]), "y": min(a[1], c[1]),
            "width": abs(c[0] - a[0]), "height": abs(c[1] - a[1])}


def circle_annotation(center, radius) -> dict:
    return {"type": "circle", "center": {"x": center[0], "y": center[1]}, "radius": radius}


def arc_annotations(center, radius, start, end, mid, step_deg: float = 10.0) -> list[dict]:
    """Notes have no arc type, so an arc becomes a run of short line segments."""
    a0, a1 = arc_angles_from_points(center, start, end, mid)
    n = max(1, math.ceil((a1 - a0) / step_deg))
    pts = []
    for i in range(n + 1):
        rad = math.radians(a0 + (a1 - a0) * i / n)
        pts.append((center[0] + radius * math.cos(rad), center[1] + radius * math.sin(rad)))
    return [line_annotation(pts[i], pts[i + 1]) for i in range(n)]


def polygon_annotations(points) -> list[dict]:
    """A closed polygon becomes one rectangle note if it is an axis-aligned
    rectangle, otherwise one line note per edge.
    """
    if len(points) == 4:
        xs = {round(p[0], 6) for p in points}
        ys = {round(p[1], 6) for p in points}
        if len(xs) == 2 and len(ys) == 2:
            return [rect_annotation(points[0], points[2])]
    return [line_annotation(points[i], points[(i + 1) % len(points)]) for i in range(len(points))
            if points[i] != points[(i + 1) % len(points)]]


def parse_ref_prefixes(text: str) -> tuple[str, ...]:
    """"J, U" -> ("J", "U"): reference-designator letters, upper-cased."""
    return tuple(p.strip().upper() for p in re.split(r"[,\s]+", text or "") if p.strip())


def ref_matches(ref: str, prefixes) -> bool:
    """True if the reference designator's letters are exactly one of
    [prefixes] (J1 and J12 match "J"; JP1 doesn't). No prefixes matches all.
    """
    if not prefixes:
        return True
    m = re.match(r"([A-Za-z]+)\d", ref or "")
    return bool(m) and m.group(1).upper() in prefixes


def shift_annotations(annotations, dx: float, dy: float):
    """Translate notes by (-dx, -dy), the same shift normalize_entities applies."""
    if abs(dx) < 1e-9 and abs(dy) < 1e-9:
        return annotations
    out = []
    for a in annotations:
        a = dict(a)
        if a["type"] == "line":
            a["start"] = {"x": a["start"]["x"] - dx, "y": a["start"]["y"] - dy}
            a["end"] = {"x": a["end"]["x"] - dx, "y": a["end"]["y"] - dy}
        elif a["type"] == "rect":
            a["x"] -= dx; a["y"] -= dy
        elif a["type"] == "circle":
            a["center"] = {"x": a["center"]["x"] - dx, "y": a["center"]["y"] - dy}
        out.append(a)
    return out


def round_annotations(annotations, ndigits=4):
    def r(v):
        return round(v, ndigits)
    out = []
    for a in annotations:
        a = dict(a)
        for k in ("x", "y", "width", "height", "radius"):
            if k in a:
                a[k] = r(a[k])
        for k in ("start", "end", "center"):
            if k in a:
                a[k] = {"x": r(a[k]["x"]), "y": r(a[k]["y"])}
        out.append(a)
    return out


def stadium_vertices(length: float, width: float):
    """Mirrors stadiumVertices() in lib/models/dxf_entity.dart: a closed
    slot outline centered on the origin, long axis along +X, returned as
    ((x, y), bulge) pairs.
    """
    r = width / 2.0
    hl = length / 2.0 - r
    if hl <= 1e-9:
        return [((0.0, -r), 1.0), ((0.0, r), 1.0)]
    return [((hl, -r), 1.0), ((hl, r), 0.0), ((-hl, r), 1.0), ((-hl, -r), 0.0)]


def rotate_point(p, deg, pivot=(0.0, 0.0)):
    rad = math.radians(deg)
    c, s = math.cos(rad), math.sin(rad)
    dx, dy = p[0] - pivot[0], p[1] - pivot[1]
    return (pivot[0] + dx * c - dy * s, pivot[1] + dx * s + dy * c)


def bounding_box(entities):
    xs: list[float] = []
    ys: list[float] = []
    for e in entities:
        if e["type"] == "line":
            for k in ("start", "end"):
                xs.append(e[k]["x"]); ys.append(e[k]["y"])
        elif e["type"] in ("circle", "arc"):
            xs += [e["center"]["x"] - e["radius"], e["center"]["x"] + e["radius"]]
            ys += [e["center"]["y"] - e["radius"], e["center"]["y"] + e["radius"]]
        elif e["type"] == "polyline":
            for v in e["vertices"]:
                xs.append(v["x"]); ys.append(v["y"])
    if not xs:
        return None
    return min(xs), min(ys), max(xs), max(ys)


def normalize_entities(entities):
    """Translate geometry so the bounding box's min corner sits at ~(0, 0),
    matching the convention every bundled template follows (and what
    dxf_to_json.py's normalize() does).
    """
    bbox = bounding_box(entities)
    if bbox is None:
        return entities
    min_x, min_y, _, _ = bbox
    if abs(min_x) < 1e-9 and abs(min_y) < 1e-9:
        return entities

    def shift(p):
        return {"x": p["x"] - min_x, "y": p["y"] - min_y}

    out = []
    for e in entities:
        e = dict(e)
        if e["type"] == "line":
            e["start"] = shift(e["start"]); e["end"] = shift(e["end"])
        elif e["type"] in ("circle", "arc"):
            e["center"] = shift(e["center"])
        elif e["type"] == "polyline":
            e["vertices"] = [{**shift(v), "bulge": v["bulge"]} for v in e["vertices"]]
        out.append(e)
    return out


def round_entities(entities, ndigits=4):
    def r(v):
        return round(v, ndigits)
    out = []
    for e in entities:
        e = dict(e)
        if e["type"] == "line":
            e["start"] = {"x": r(e["start"]["x"]), "y": r(e["start"]["y"])}
            e["end"] = {"x": r(e["end"]["x"]), "y": r(e["end"]["y"])}
        elif e["type"] == "circle":
            e["center"] = {"x": r(e["center"]["x"]), "y": r(e["center"]["y"])}
            e["radius"] = r(e["radius"])
        elif e["type"] == "arc":
            e["center"] = {"x": r(e["center"]["x"]), "y": r(e["center"]["y"])}
            e["radius"] = r(e["radius"])
            e["startAngle"] = r(e["startAngle"]); e["endAngle"] = r(e["endAngle"])
        elif e["type"] == "polyline":
            e["vertices"] = [{"x": r(v["x"]), "y": r(v["y"]), "bulge": r(v["bulge"])} for v in e["vertices"]]
        out.append(e)
    return out


# ---------------------------------------------------------------------------
# pcbnew-specific extraction.
# ---------------------------------------------------------------------------

class ExtractOptions:
    def __init__(self, flip_y=True, hole_min_mm=2.9, hole_max_mm=None,
                 include_npth=True, include_pth=False, include_slots=True,
                 scale=1.0, note_layers=DEFAULT_NOTE_LAYERS, part_refs=("J", "U", "TB")):
        self.note_layers = tuple(note_layers)  # NOTE_LAYERS keys exported as drawing-layer notes
        # Reference-designator letters whose footprints contribute notes; empty = all
        # footprints plus the board's own graphics.
        self.part_refs = tuple(part_refs)
        self.flip_y = flip_y
        self.hole_min_mm = hole_min_mm
        self.hole_max_mm = hole_max_mm
        self.include_npth = include_npth
        self.include_pth = include_pth
        self.include_slots = include_slots
        self.scale = scale


def _pt_mm(vec, opts: ExtractOptions):
    x = pcbnew.ToMM(vec.x) * opts.scale
    y = pcbnew.ToMM(vec.y) * opts.scale
    if opts.flip_y:
        y = -y
    return (x, y)


def extract_edge_cuts(board, opts: ExtractOptions, warnings: list[str]) -> list[dict]:
    """KiCad's own DXF plotter negates Y (DXF is Y-up, KiCad board space is
    Y-down) -- flip_y=True reproduces that, so geometry matches what
    dxf_to_json.py would have produced from a File > Plot > DXF export of
    the same board.
    """
    entities: list[dict] = []
    rect_t = getattr(pcbnew, "SHAPE_T_RECTANGLE", None) or getattr(pcbnew, "SHAPE_T_RECT", None)
    for item in board.GetDrawings():
        if item.GetClass() != "PCB_SHAPE":
            continue
        if item.GetLayer() != pcbnew.Edge_Cuts:
            continue
        shape_t = item.GetShape()
        if shape_t == pcbnew.SHAPE_T_SEGMENT:
            entities.append(line_entity(_pt_mm(item.GetStart(), opts), _pt_mm(item.GetEnd(), opts)))
        elif shape_t == pcbnew.SHAPE_T_CIRCLE:
            center = _pt_mm(item.GetCenter(), opts)
            radius = pcbnew.ToMM(item.GetRadius()) * opts.scale
            entities.append(circle_entity(center, radius))
        elif shape_t == pcbnew.SHAPE_T_ARC:
            center = _pt_mm(item.GetCenter(), opts)
            start = _pt_mm(item.GetStart(), opts)
            end = _pt_mm(item.GetEnd(), opts)
            mid = _pt_mm(item.GetArcMid(), opts)
            radius = pcbnew.ToMM(item.GetRadius()) * opts.scale
            entities.append(arc_entity(center, radius, start, end, mid))
        elif rect_t is not None and shape_t == rect_t:
            a = _pt_mm(item.GetStart(), opts)
            c = _pt_mm(item.GetEnd(), opts)
            b, d = (c[0], a[1]), (a[0], c[1])
            entities.append(polyline_entity([a, b, c, d], closed=True))
        elif shape_t == pcbnew.SHAPE_T_POLY:
            poly = item.GetPolyShape()
            if poly.OutlineCount() > 0:
                outline = poly.Outline(0)
                pts = [_pt_mm(outline.CPoint(i), opts) for i in range(outline.PointCount())]
                entities.append(polyline_entity(pts, closed=True))
            else:
                warnings.append("skipped an empty polygon shape on Edge.Cuts")
        else:
            warnings.append(
                f"skipped an unsupported Edge.Cuts shape (type {shape_t}, e.g. a Bezier curve) "
                "-- redraw it as lines/arcs on Edge.Cuts"
            )
    if not entities:
        warnings.append("no Edge.Cuts geometry found -- the board outline will be missing")
    return entities


def _note_layer_ids(opts: ExtractOptions) -> set:
    ids = set()
    for key in opts.note_layers:
        attr = NOTE_LAYERS[key][1]
        if hasattr(pcbnew, attr):
            ids.add(getattr(pcbnew, attr))
    return ids


def _shape_annotations(item, opts: ExtractOptions, rect_t) -> list[dict] | None:
    """Notes for one PCB_SHAPE, or None if its shape type has no equivalent."""
    shape_t = item.GetShape()
    if shape_t == pcbnew.SHAPE_T_SEGMENT:
        a, b = _pt_mm(item.GetStart(), opts), _pt_mm(item.GetEnd(), opts)
        return [] if a == b else [line_annotation(a, b)]
    if shape_t == pcbnew.SHAPE_T_CIRCLE:
        return [circle_annotation(_pt_mm(item.GetCenter(), opts), pcbnew.ToMM(item.GetRadius()) * opts.scale)]
    if shape_t == pcbnew.SHAPE_T_ARC:
        return arc_annotations(
            _pt_mm(item.GetCenter(), opts), pcbnew.ToMM(item.GetRadius()) * opts.scale,
            _pt_mm(item.GetStart(), opts), _pt_mm(item.GetEnd(), opts), _pt_mm(item.GetArcMid(), opts),
        )
    if rect_t is not None and shape_t == rect_t:
        return [rect_annotation(_pt_mm(item.GetStart(), opts), _pt_mm(item.GetEnd(), opts))]
    if shape_t == pcbnew.SHAPE_T_POLY:
        poly = item.GetPolyShape()
        if poly.OutlineCount() == 0:
            return []
        outline = poly.Outline(0)
        return polygon_annotations([_pt_mm(outline.CPoint(i), opts) for i in range(outline.PointCount())])
    return None


def extract_notes(board, opts: ExtractOptions, warnings: list[str]) -> list[dict]:
    """Lines, rectangles, circles, arcs and polygons from the chosen layers
    (see NOTE_LAYERS) as drawing-layer notes. Text and Bezier curves are skipped.
    """
    notes: list[dict] = []
    layers = _note_layer_ids(opts)
    if not layers:
        return notes
    rect_t = getattr(pcbnew, "SHAPE_T_RECTANGLE", None) or getattr(pcbnew, "SHAPE_T_RECT", None)

    # With a part filter, only those parts' graphics count: loose board
    # graphics (logos, labels) aren't parts.
    items = [] if opts.part_refs else list(board.GetDrawings())
    for fp in board.GetFootprints():
        if ref_matches(fp.GetReference(), opts.part_refs):
            items.extend(fp.GraphicalItems())

    skipped_text = skipped_other = 0
    for item in items:
        if item.GetLayer() not in layers:
            continue
        if item.GetClass() not in ("PCB_SHAPE", "FP_SHAPE"):
            if "TEXT" in item.GetClass():
                skipped_text += 1
            continue
        result = _shape_annotations(item, opts, rect_t)
        if result is None:
            skipped_other += 1
        else:
            notes.extend(result)
    if skipped_text:
        warnings.append(f"skipped {skipped_text} text item(s) on the note layers -- add text in Template Maker instead")
    if skipped_other:
        warnings.append(f"skipped {skipped_other} unsupported shape(s) on the note layers (e.g. Bezier curves)")
    return notes


def extract_holes(board, opts: ExtractOptions, warnings: list[str]) -> list[dict]:
    entities: list[dict] = []
    for fp in board.GetFootprints():
        for pad in fp.Pads():
            drill = pad.GetDrillSize()
            dx_mm, dy_mm = pcbnew.ToMM(drill.x), pcbnew.ToMM(drill.y)
            if dx_mm <= 1e-6 and dy_mm <= 1e-6:
                continue  # SMD pad, no hole

            is_npth = pad.GetAttribute() == pcbnew.PAD_ATTRIB_NPTH
            if is_npth and not opts.include_npth:
                continue
            if not is_npth and not opts.include_pth:
                continue

            min_dim = min(dx_mm, dy_mm)
            if min_dim < opts.hole_min_mm or (opts.hole_max_mm is not None and min_dim > opts.hole_max_mm):
                continue

            pos = _pt_mm(pad.GetPosition(), opts)
            is_oblong = pad.GetDrillShape() == pcbnew.PAD_DRILL_SHAPE_OBLONG or abs(dx_mm - dy_mm) > 1e-3

            if not is_oblong:
                radius = (dx_mm / 2.0) * opts.scale
                entities.append(circle_entity(pos, radius))
                continue

            if not opts.include_slots:
                continue
            length_mm = max(dx_mm, dy_mm) * opts.scale
            width_mm = min(dx_mm, dy_mm) * opts.scale
            orient_deg = pad.GetOrientationDegrees()
            long_axis_deg = orient_deg if dx_mm >= dy_mm else orient_deg + 90.0
            if opts.flip_y:
                long_axis_deg = -long_axis_deg
            stadium = stadium_vertices(length_mm, width_mm)
            verts = [(pos[0] + rotate_point(p, long_axis_deg)[0], pos[1] + rotate_point(p, long_axis_deg)[1])
                     for p, _ in stadium]
            bulges = [b for _, b in stadium]
            entities.append(polyline_entity(verts, closed=True, bulges=bulges))
    return entities


def build_template(board, *, id_: str, name: str, category: str, opts: ExtractOptions,
                    normalize: bool = True) -> tuple[dict, list[str]]:
    if category not in VALID_CATEGORIES:
        raise ValueError(f"category must be one of {VALID_CATEGORIES}, got {category!r}")

    warnings: list[str] = []
    edge_entities = extract_edge_cuts(board, opts, warnings)
    hole_entities = extract_holes(board, opts, warnings)
    if not hole_entities:
        hints = []
        if not opts.include_npth:
            hints.append("NPTH (mounting) holes are excluded")
        if not opts.include_pth:
            hints.append("plated (PTH) holes are excluded")
        if not opts.include_slots:
            hints.append("slotted holes are excluded")
        hints.append(f"holes under {opts.hole_min_mm:g} mm are ignored")
        warnings.append(
            "no mounting holes found -- the template will have only an outline. "
            "Check that the board has NPTH/mechanical hole pads (" + "; ".join(hints) + ")."
        )
    entities = edge_entities + hole_entities
    annotations = extract_notes(board, opts, warnings)

    if normalize:
        # Notes share the plate's origin, so they get the plate's shift.
        bbox = bounding_box(entities)
        if bbox is not None:
            annotations = shift_annotations(annotations, bbox[0], bbox[1])
        entities = normalize_entities(entities)
    entities = round_entities(entities)

    template = {"id": id_, "name": name, "category": category, "entities": entities}
    if annotations:
        template["annotations"] = round_annotations(annotations)
    return template, warnings


def write_template(template: dict, output_path: Path, update_index: bool) -> None:
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(template, indent=2) + "\n", encoding="utf-8")

    if not update_index:
        return
    index_path = output_path.parent / "index.json"
    entries = []
    if index_path.exists():
        try:
            entries = json.loads(index_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            entries = []
    file_name = output_path.name
    entries = [e for e in entries if e.get("id") != template["id"]]
    entries.append({"id": template["id"], "file": file_name})
    index_path.write_text(json.dumps(entries, indent=2) + "\n", encoding="utf-8")


# ---------------------------------------------------------------------------
# KiCad Action Plugin (GUI) entry point.
# ---------------------------------------------------------------------------

def _run_gui(board) -> None:
    import wx

    class ExportDialog(wx.Dialog):
        def __init__(self, parent, board):
            super().__init__(
                parent,
                title="Export box_design Template",
                style=wx.DEFAULT_DIALOG_STYLE | wx.RESIZE_BORDER,
            )
            self.board = board

            default_name = Path(board.GetFileName()).stem if board.GetFileName() else "New Board"
            templates_dir = find_templates_dir()

            panel = wx.Panel(self)
            sizer = wx.BoxSizer(wx.VERTICAL)
            grid = wx.FlexGridSizer(0, 2, 6, 8)
            grid.AddGrowableCol(1, 1)

            def add_row(label, ctrl):
                grid.Add(wx.StaticText(panel, label=label), flag=wx.ALIGN_CENTER_VERTICAL)
                grid.Add(ctrl, flag=wx.EXPAND)

            self.name_ctrl = wx.TextCtrl(panel, value=default_name)
            add_row("Name:", self.name_ctrl)

            self.id_ctrl = wx.TextCtrl(panel, value=slugify(default_name))
            add_row("Template ID:", self.id_ctrl)
            self.name_ctrl.Bind(wx.EVT_TEXT, self._on_name_changed)
            self._id_auto = True
            self.id_ctrl.Bind(wx.EVT_TEXT, self._on_id_edited)

            self.category_ctrl = wx.Choice(panel, choices=list(VALID_CATEGORIES))
            self.category_ctrl.SetSelection(0)
            add_row("Category:", self.category_ctrl)

            self.min_hole_ctrl = wx.TextCtrl(panel, value="2.9")
            add_row("Min hole diameter (mm):", self.min_hole_ctrl)

            self.include_npth_ctrl = wx.CheckBox(panel, label="Include NPTH (mounting) holes")
            self.include_npth_ctrl.SetValue(True)
            grid.Add(wx.StaticText(panel, label=""))
            grid.Add(self.include_npth_ctrl)

            self.include_pth_ctrl = wx.CheckBox(panel, label="Include plated (PTH) holes too")
            self.include_pth_ctrl.SetValue(False)
            grid.Add(wx.StaticText(panel, label=""))
            grid.Add(self.include_pth_ctrl)

            self.include_slots_ctrl = wx.CheckBox(panel, label="Include oblong/slotted holes")
            self.include_slots_ctrl.SetValue(True)
            grid.Add(wx.StaticText(panel, label=""))
            grid.Add(self.include_slots_ctrl)

            self.note_layers_ctrl = wx.CheckListBox(
                panel, choices=[label for label, _ in NOTE_LAYERS.values()], size=(-1, 130))
            for idx, key in enumerate(NOTE_LAYERS):
                self.note_layers_ctrl.Check(idx, key in DEFAULT_NOTE_LAYERS)
            add_row("Layers as notes:", self.note_layers_ctrl)

            self.part_refs_ctrl = wx.TextCtrl(panel, value="J, U, TB")
            self.part_refs_ctrl.SetToolTip(
                "Reference-designator letters whose footprint graphics are exported, e.g. J, U. "
                "Leave empty for every part plus the board's own graphics.")
            add_row("Parts (ref letters):", self.part_refs_ctrl)

            self.normalize_ctrl = wx.CheckBox(panel, label="Normalize origin to bounding-box corner")
            self.normalize_ctrl.SetValue(True)
            grid.Add(wx.StaticText(panel, label=""))
            grid.Add(self.normalize_ctrl)

            self.update_index_ctrl = wx.CheckBox(panel, label="Add/update entry in index.json")
            self.update_index_ctrl.SetValue(templates_dir is not None)
            grid.Add(wx.StaticText(panel, label=""))
            grid.Add(self.update_index_ctrl)

            out_row = wx.BoxSizer(wx.HORIZONTAL)
            default_out = str((templates_dir or Path.home()) / f"{self.id_ctrl.GetValue()}.json")
            self.output_ctrl = wx.TextCtrl(panel, value=default_out)
            browse_btn = wx.Button(panel, label="Browse...")
            browse_btn.Bind(wx.EVT_BUTTON, self._on_browse)
            out_row.Add(self.output_ctrl, proportion=1, flag=wx.EXPAND | wx.RIGHT, border=4)
            out_row.Add(browse_btn)
            add_row("Output file:", out_row)

            sizer.Add(grid, flag=wx.EXPAND | wx.ALL, border=12)

            self.log_ctrl = wx.TextCtrl(panel, style=wx.TE_MULTILINE | wx.TE_READONLY, size=(-1, 110))
            sizer.Add(wx.StaticText(panel, label="Log:"), flag=wx.LEFT | wx.TOP, border=12)
            sizer.Add(self.log_ctrl, flag=wx.EXPAND | wx.ALL, border=12)

            btn_sizer = wx.StdDialogButtonSizer()
            ok_btn = wx.Button(panel, wx.ID_OK, label="Export")
            ok_btn.SetDefault()
            cancel_btn = wx.Button(panel, wx.ID_CANCEL, label="Close")
            btn_sizer.AddButton(ok_btn)
            btn_sizer.AddButton(cancel_btn)
            btn_sizer.Realize()
            sizer.Add(btn_sizer, flag=wx.ALIGN_RIGHT | wx.ALL, border=12)

            panel.SetSizer(sizer)

            # Size the dialog to what its content actually needs (a
            # hardcoded pixel size doesn't scale with font/DPI settings and
            # was clipping the longer labels, and on some systems the
            # Export/Cancel buttons entirely -- there was no way to save).
            outer = wx.BoxSizer(wx.VERTICAL)
            outer.Add(panel, proportion=1, flag=wx.EXPAND)
            self.SetSizerAndFit(outer)
            self.SetMinSize(self.GetSize())

            ok_btn.Bind(wx.EVT_BUTTON, self._on_export)

        def _log(self, message: str) -> None:
            self.log_ctrl.AppendText(message + "\n")

        def _on_name_changed(self, evt):
            if self._id_auto:
                self.id_ctrl.ChangeValue(slugify(self.name_ctrl.GetValue()))
            evt.Skip()

        def _on_id_edited(self, evt):
            self._id_auto = False
            evt.Skip()

        def _on_browse(self, evt):
            with wx.FileDialog(self, "Save template JSON", wildcard="JSON files (*.json)|*.json",
                                defaultDir=str(Path(self.output_ctrl.GetValue()).parent),
                                defaultFile=Path(self.output_ctrl.GetValue()).name,
                                style=wx.FD_SAVE | wx.FD_OVERWRITE_PROMPT) as dlg:
                if dlg.ShowModal() == wx.ID_OK:
                    self.output_ctrl.ChangeValue(dlg.GetPath())

        def _on_export(self, evt):
            try:
                min_hole = float(self.min_hole_ctrl.GetValue())
            except ValueError:
                self._log("ERROR: Min hole diameter must be a number.")
                return

            opts = ExtractOptions(
                flip_y=True,
                hole_min_mm=min_hole,
                include_npth=self.include_npth_ctrl.GetValue(),
                include_pth=self.include_pth_ctrl.GetValue(),
                include_slots=self.include_slots_ctrl.GetValue(),
                note_layers=tuple(key for idx, key in enumerate(NOTE_LAYERS)
                                  if self.note_layers_ctrl.IsChecked(idx)),
                part_refs=parse_ref_prefixes(self.part_refs_ctrl.GetValue()),
            )
            try:
                template, warnings = build_template(
                    self.board,
                    id_=self.id_ctrl.GetValue() or slugify(self.name_ctrl.GetValue()),
                    name=self.name_ctrl.GetValue() or "Untitled",
                    category=VALID_CATEGORIES[self.category_ctrl.GetSelection()],
                    opts=opts,
                    normalize=self.normalize_ctrl.GetValue(),
                )
            except Exception as exc:  # surface the failure instead of a silent no-op
                self._log(f"ERROR: Export failed: {exc}")
                return

            for w in warnings:
                self._log(f"WARNING: {w}")

            out_path = Path(self.output_ctrl.GetValue())
            try:
                write_template(template, out_path, update_index=self.update_index_ctrl.GetValue())
            except OSError as exc:
                self._log(f"ERROR: Could not write {out_path}: {exc}")
                return

            summary = (f"Wrote {out_path} ({len(template['entities'])} entities, "
                       f"{len(template.get('annotations', []))} notes)")
            if warnings:
                summary += f" with {len(warnings)} warning(s)"
            self._log(summary + ".")

    dlg = ExportDialog(None, board)
    dlg.ShowModal()
    dlg.Destroy()


if pcbnew is not None:

    class BoxDesignTemplateExporter(pcbnew.ActionPlugin):
        def defaults(self):
            self.name = "Export box_design Template..."
            self.category = "Export"
            self.description = (
                "Export the board outline and mounting holes as a box_design "
                "controller/receiver template JSON"
            )
            self.show_toolbar_button = True
            self.icon_file_name = ""

        def Run(self):
            board = pcbnew.GetBoard()
            _run_gui(board)

    # register() asserts (hard-crashes, not a catchable exception) if no
    # KiCad application instance is running -- which is exactly the case
    # when this file is imported as a plain library (the CLI entry point
    # below, or a test), since KiCad's own plugin loader imports it the
    # same way a script would. A running app always has a wx.App instance;
    # a bare python.exe invocation doesn't, so use that as the precondition.
    import wx
    if wx.App.Get() is not None:
        BoxDesignTemplateExporter().register()


# ---------------------------------------------------------------------------
# Standalone CLI, for use without opening the KiCad GUI, e.g.:
#   "C:\Program Files\KiCad\9.0\bin\python.exe" box_design_template_exporter.py board.kicad_pcb --id foo --name Foo --category controller
# ---------------------------------------------------------------------------

def _cli_main(argv: list[str]) -> int:
    if pcbnew is None:
        print("This script needs KiCad's pcbnew Python module. Run it with KiCad's "
              "own python.exe (see the module docstring for the path).", file=sys.stderr)
        return 1

    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("board_path", type=Path, help="Input .kicad_pcb file")
    parser.add_argument("--id", dest="id_", help="Template id (default: slugified --name)")
    parser.add_argument("--name", required=True, help="Display name shown in the palette")
    parser.add_argument("--category", required=True, choices=VALID_CATEGORIES)
    parser.add_argument("-o", "--output", type=Path, default=None,
                         help="Output JSON path (default: assets/templates/<id>.json if found, else ./<id>.json)")
    parser.add_argument("--min-hole-mm", type=float, default=2.9,
                         help="Skip round/slotted holes smaller than this diameter (default: 2.9)")
    parser.add_argument("--max-hole-mm", type=float, default=None,
                         help="Skip holes larger than this diameter (default: no limit)")
    parser.add_argument("--include-pth", action="store_true",
                         help="Also include plated (PTH) holes, not just NPTH mounting holes")
    parser.add_argument("--no-npth", action="store_true", help="Exclude NPTH mounting holes")
    parser.add_argument("--no-slots", action="store_true", help="Exclude oblong/slotted holes")
    parser.add_argument("--note-layers", default=",".join(DEFAULT_NOTE_LAYERS),
                         help="Comma separated layers to export as drawing-layer notes, from "
                              f"{', '.join(NOTE_LAYERS)} (default: {','.join(DEFAULT_NOTE_LAYERS)}; "
                              "'none' for no notes)")
    parser.add_argument("--part-refs", default="J,U,TB",
                         help="Reference-designator letters whose footprint graphics are exported, comma "
                              "separated (default: J,U,TB). Pass '' for every part plus the board's own "
                              "graphics")
    parser.add_argument("--no-normalize", action="store_true",
                         help="Don't translate geometry so its bounding box starts at (0, 0)")
    parser.add_argument("--no-flip-y", action="store_true",
                         help="Don't flip Y (by default Y is flipped to match KiCad's own DXF export convention)")
    parser.add_argument("--update-index", action="store_true",
                         help="Add/update this template's entry in index.json next to the output file")
    args = parser.parse_args(argv)

    if not args.board_path.exists():
        print(f"No such file: {args.board_path}", file=sys.stderr)
        return 1

    id_ = args.id_ or slugify(args.name)
    output_path = args.output
    if output_path is None:
        templates_dir = find_templates_dir()
        output_path = (templates_dir or Path.cwd()) / f"{id_}.json"

    board = pcbnew.LoadBoard(str(args.board_path))
    opts = ExtractOptions(
        flip_y=not args.no_flip_y,
        hole_min_mm=args.min_hole_mm,
        hole_max_mm=args.max_hole_mm,
        include_npth=not args.no_npth,
        include_pth=args.include_pth,
        include_slots=not args.no_slots,
        note_layers=parse_note_layers(args.note_layers),
        part_refs=parse_ref_prefixes(args.part_refs),
    )
    template, warnings = build_template(
        board, id_=id_, name=args.name, category=args.category, opts=opts,
        normalize=not args.no_normalize,
    )
    write_template(template, output_path, update_index=args.update_index)

    print(f"Wrote {output_path} ({len(template['entities'])} entities, "
          f"{len(template.get('annotations', []))} notes)")
    for w in warnings:
        print(f"  warning: {w}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli_main(sys.argv[1:]))
