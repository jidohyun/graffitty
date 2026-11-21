shader_type spatial;
// Terminal sheet for Godot.
//
// Two things are layered here. The compositing is HeritageLiveInk:
// premultiplied ink over the masonry including native glyph outlines.
//
// On top of that is the *sheet* — the page the terminal is drawn on, which
// zooms, tilts, curves, ripples and splashes.
//
// Option names and defaults follow kitty/options/definition.py so a scene
// preset reads across unchanged.
render_mode unshaded, cull_disabled, blend_mix, shadows_disabled, depth_draw_always;

#include "res://scenes/terminal_sheet_common.gdshaderinc"
