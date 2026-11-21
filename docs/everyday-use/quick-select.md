# Quick Select

Copy a path, URL, or other recognizable text without selecting it with the mouse.

1. Press **Ctrl+Shift+Space** in a terminal.
2. Find the letter label beside the text you want.
3. Type the label to copy it.

## Copy or paste

| Label you type | Result |
| --- | --- |
| Lowercase, such as `f` or `af` | Copy |
| Any uppercase letter, such as `F` or `aF` | Copy and paste into the same terminal |

Paste does not press Enter. Identical text shares a label.

## Controls

| Key | Action |
| --- | --- |
| **Escape** | Close without copying |
| **Backspace** | Remove the last label character |
| **Ctrl+U** | Clear the label input |
| **Up / Ctrl+P / Enter** | Previous match |
| **Down / Ctrl+N** | Next match |
| **PageUp / PageDown** | Move a page of matches |

## What it recognizes

- URLs and Markdown link destinations.
- Unix and Windows paths, including relative and diff paths.
- Hashes, colors, UUIDs, and IP/IPFS addresses.
- Hexadecimal addresses and numbers with at least four digits.

Search covers the visible terminal and nearby scrollback, up to 1,000 rows on each side.
Paths stop at whitespace. Switching between the normal and alternate terminal screen closes Quick Select.

For custom patterns and label letters, see [terminal settings](../customize/terminal-settings.md#scrolling-and-selection).
