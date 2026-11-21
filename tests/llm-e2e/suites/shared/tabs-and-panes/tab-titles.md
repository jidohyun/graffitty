# Naming tabs from the command line

## Name tabs from the command line

1. Launch from the repository root:

   ```sh
   mise run dev -- --shell=/bin/sh --tabs=3
   ```

2. In the first tab run `"$GRAFFITTY_BIN" tab rename Build`.
   Expected: the first tab reads `Build`.
3. Still in the first tab, run `"$GRAFFITTY_BIN" tab rename --tab 2 Logs`.
   Expected: the second tab reads `Logs`; the first still reads `Build`.
4. Run `"$GRAFFITTY_BIN" tab list`. Expected: three tabs with positions
   1 to 3, the titles shown in the bar, and the first marked as `"self":true`.

## The name holds

1. In the first tab run `printf '\033]0;other\007'`, which sets the terminal's
   title the way shells and editors do. Expected: the tab still reads `Build`.
2. Drag the `Build` tab to the end of the bar. Expected: it still reads `Build`.
3. Rename position 1 after the drag: it must target the tab now shown first.
   Rename the same tab by its stable `--tab-id`, and check `--target :2` and
   `--target @ID` select the visible position and stable identity respectively.
   `list-tabs` must retain the displayed order and current automatic titles.

## Return to automatic

1. In `Build`, run `"$GRAFFITTY_BIN" tab rename` with no title.
   Expected: the tab reads `other`, the title the shell set.
2. Report PASS, FAIL or BLOCKED with a screenshot of the bar after each step.

## Focused pane and directory fallbacks

Split the automatically named tab. Set distinct OSC titles in its panes and
switch focus: the tab must follow the focused pane. Clear one pane's OSC title
and report a URL-encoded directory via OSC 7: both its header and the automatic
tab must show the decoded path. An explicit pane title overrides OSC and feeds
the automatic tab. An explicit tab title overrides both panes and survives
focus changes. Rename the tab from the second pane to verify the containing
tab is targeted. Clear each explicit name and verify automatic naming resumes.
