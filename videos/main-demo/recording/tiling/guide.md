# A connected workspace

Keep your editor, terminal, and chromium together.

## Write and preview

Markdown stays in Neovim.
The rendered page stays beside it.

Scroll the document to keep both views in sync.

- Write in the editor.
- Review in Chromium.
- Keep your place in both views.

## Organize your work

Split the workspace into related panes.

| Pane | Purpose |
| --- | --- |
| Terminal | Run commands |
| Editor | Change the document |
| Chromium | Preview the result |

Move a pane when the task changes.
Your running processes stay alive.

## Test the interface

A chromium can be part of an agent's workflow.

1. Open the local application.
2. Inspect the available controls.
3. Interact with the page.
4. Check the actual result.

```sh
gft chromium snapshot --target "$chromium"
gft chromium click --target "$chromium" --ref "$button"
```

## Keep the context

Connections show which terminal owns each chromium.

Move a chromium outside the main area when you need room.
The page keeps running and the connection remains visible.

Return to Main View to focus on the active work.

## Review together

Use the filetree to open notes and images.
Keep related tasks in their own tabs.

- One place for commands.
- One place for documents.
- One place for tests.

Everything stays connected.
