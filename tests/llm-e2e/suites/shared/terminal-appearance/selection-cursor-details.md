Godot Windows: run `python tests/platform/windows/windows_appearance_e2e.py --mode details --evidence <fresh-directory> --project <frozen-project>`. This uses an isolated window station, real ConPTY and projected Godot controls, then checks native/window pixels. Review captures as described below.

## Inspect selection and outlines

Compare `appearance-details-before.png`, `appearance-details-selected.png` and `appearance-details-selection-red.png`. The actual terminal run `MMM->MMM` must remain legible. The selected glyphs change to green and then red on a blue selection background; a colored wash over white text is insufficient. Inspect the arrow boundary and adjacent unselected cells for stale ligatures or spilled selection color.

Compare `appearance-details-outline.png` with the baseline. White text must gain a red outline, while the title/header remains pixel-identical. Check small details and surrounding empty cells for excessive halos, overwritten neighboring glyphs or clipped outlines. CPU tests independently verify cached alpha-mask reuse and run splitting.

## Inspect cursor policies

Compare forced hollow, hidden, application block and unfocused cursor images. Forced hollow must have visible edges and an empty center even while the application requests a bar. Under auto, the application block must appear normally; losing window focus makes that same cursor hollow. Keep these claims distinct from unverified native hardware focus events. Examine blink-on and blink-off image pairs for actual changing and steady pixels respectively.

Compare the two `appearance-details-scrolled-blink-*.png` images. The PTY moves its cursor to row 8, column 12 before scrolling one history row; the still-visible cursor must blink at viewport row 9, column 12. The fixture then restores the bottom viewport and original cursor position before checking the remaining controls.

## Inspect Appearance controls

Inspect `appearance-details-dialog.png`, opened via the actual Terminal menu. Selection text color, outline width/color, shape policy, blink policy/interval and separate beam/underline widths must be reachable through the scrollable dialog, without overlapping buttons or clipped labels. Record `visual-review.json` with exact files and failures; a passing state assertion alone does not prove readable controls.
