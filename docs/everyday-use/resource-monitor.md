# Resource Monitor

Open **View → Resource Monitor** to compare panes. Use **View → Pane Status**
for only the focused pane. Click a pane row to focus it.

## Arrange the list

| Task | Control |
| --- | --- |
| Sort | Click a column heading; unknown values sort last |
| Reorder columns | Drag a heading; hold at an edge to scroll |
| Resize a column | Drag its right edge |
| Filter | Choose Server and Session values |

Changing the server filter clears the session filter. Column and filter choices
are saved across windows.

## Fold connected panes

The **Connections** column groups related panes within each server/session.
Graph links, spawned panes, filetrees, and browsers establish these groups.
Muted graph links still count as relationships.

Click a group's unnamed summary row to fold or expand it. The row shows a pane
count rather than a parent agent. Its PID and pane key stay blank.
Sorting keeps each group together; individual rows still focus their panes.

## Read totals

- Each pane counts once, even when visible in several windows.
- Group CPU, RAM, and process counts sum their members. A missing measurement
  makes that group metric unknown.
- Footer totals cover the filtered rows; folding does not change them.
- Footer CPU averages the server totals, because 100% represents all CPUs on
  one server. RAM and process counts add together.

Unknown or stale measurements are not measured zero usage.
