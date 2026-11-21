# Live terminals inside a 3D world

Use disposable configuration and fresh shell processes. The fixture shell is
`/bin/sh`; never type test commands into the user's existing session. Evidence
must include terminal history or screen state from the real terminal backend,
not an expected string inserted into the UI model.

## Use a real shell

1. Type a command that prints a random test marker, `$$`, and `pwd`.
2. Wait for output and verify the marker from a completed output line, the PID
   against backend process metadata, and the isolated working directory.
3. Print Unicode, ANSI colors, and an OSC title. Confirm the title and visible
   glyphs update in the application. Capture the rendered terminal and UI.
4. Change the cursor shape with DECSCUSR. The backend and drawn cursor agree.

## Split and resize

1. Split horizontally, then vertically. Each new terminal has a distinct live
   process, and focus routes input to exactly one pane.
2. Resize the split. Compare the real terminal rows/columns (`stty size`) with
   the intended pane area. Merely clipping a pane offscreen must not resize it.
3. Drag one pane outside the main area, fit it by double-clicking its title,
   restore its prior view, and bring it back. Its PID and output survive.
4. Close that pane. Its process ends; all other panes continue responding.

## Inspect weighted layouts and tab transfer

1. Enable horizontal tiling with two live terminals. Drag the divider and inspect
   the changed widths; drag to the edge and confirm neither pane collapses.
   Undo and redo restore the exact divider position and the original processes.
2. Split one pane vertically. Drag its title onto another pane's bottom edge.
   Inspect `tiling-drop-preview.png`: two distinct preview colors identify the
   proposed regions. Compare `tiling-drop-committed.png`; their boundaries must
   match the proposal. Undo restores the nested arrangement.
3. Open a chromium beside a terminal and type into its page. Drag the terminal's
   title onto another tab using the visible tab bar. Inspect the arriving
   terminal and chromium: the page's existing state and terminal output remain.
4. Move the chromium alone into a new tab. Inspect the recognizable page in
   `surface-chromium-only-tab.png`; its content remains proportional. Undo/redo
   must restore the same tab identity, not recreate the Chromium document.
5. Create and close a terminal in that chromium-only tab. The page stays alive.
   Then close its original owner from another tab; the chromium and newly empty
   presentation tab disappear while an unrelated shell remains usable.

## Navigate independent tabs

1. Create another tab, change its zoom and pan, and return to the first tab.
2. The first tab retains its layout and camera view. Reorder the second tab;
   its live shell moves with it to the destination assigned to its new index.
3. Switch tabs during a flight, then type immediately after arrival. Input
   reaches the visible focused pane, with no duplicate or leaked characters.

## Inspect scrolling and input

1. Produce at least 100 numbered lines. Scroll half a row using the same input
   route as a trackpad; capture the top and bottom partial rows and scrollbar.
2. Enter an alternate-screen application or deterministic alternate-screen
   fixture. It retains its full grid and receives appropriate mouse/scroll
   input. It does not expose unrelated main-screen scrollback.
3. Select Unicode text and copy it. Paste text through bracketed-paste mode;
   verify exact received bytes using a raw-PTY fixture.
4. Report unsupported actions as BLOCKED. They do not count as passed feature
   parity, even when the smaller automated smoke scenario passes.
