# Every connected surface stays in one tab

## Prepare real connected surfaces

1. Start an isolated workspace with SOURCE and TARGET tabs. Keep an unrelated
   terminal in each tab so both tabs survive every move.
2. In SOURCE create an OWNER terminal, its connected filetree, a Neovim editor
   opened by that filetree, an HTML/image/PDF chromium preview opened by the
   filetree, and a second chromium created directly by OWNER. Connect another
   agent pane to the editor with a paused graph link. Do not connect the two
   unrelated terminals.
3. Use real Neovim and chromium processes. The deterministic fixture may use an
   isolated Neovim configuration with its built-in explorer instead of downloading
   Fyler; this case tests live ownership and transfers, not plugin installation.
4. Note every `%N`, terminal/editor PID, chromium PID, URL, and ownership link.
   Arrange different pane positions and sizes; zoom out to see the full group.

## Move from the chromium

1. Press the directly attached chromium's pane header, hover TARGET until it
   opens, and move into its canvas. Inspect the preview before releasing.
2. The preview must carry OWNER, both chromiums, the filetree, its opened Neovim,
   and the linked agent, including every association wire and paused graph link.
   Neither unrelated terminal may appear in the carried group.
3. Release. All six surfaces must be in TARGET. For every graph, chromium-owner,
   owner-filetree, and filetree-editor edge, assert that both endpoints have the
   same tab. Compare all pane offsets and sizes to the pointer-down snapshot.

## Move from the filetree

1. Drag the filetree header back into SOURCE using tab hover and content drop.
2. Verify the same complete group moves, including the parent OWNER. Assert all
   connection endpoints are tab-local, all wire previews are present, and geometry,
   IDs, processes, editor contents and chromium pages survive.

## Move from the opened Neovim and preview chromium

1. Drag the opened Neovim header into TARGET. Its parent filetree, OWNER,
   chromiums and connected agent must follow; verify every link and process.
2. Drag the filetree's preview-chromium header back into SOURCE. Perform the same
   checks. Being the child endpoint must never allow a connection across tabs.

## Move from the owner and cancel

1. Drag OWNER into TARGET. Verify the same group, geometry and live identities.
2. Drag the linked agent toward SOURCE, inspect the complete preview, then press
   Escape. All membership, positions, connections and processes must be unchanged.
3. Attempt API/CLI graph connections between the group and either unrelated
   terminal in another tab; they must fail without creating an edge.
4. Open another file through the filetree after the moves: reuse the same live
   editor, in the same tab. Open another HTML preview and confirm its chromium
   stays with its controller. Independently opened, unconnected panes remain
   independent; unrelated OS subprocesses are not pane connections.
5. Report PASS, FAIL or BLOCKED with before/preview/after/cancellation evidence
   for each starting surface. A parent-only move or mocked topology is insufficient.
