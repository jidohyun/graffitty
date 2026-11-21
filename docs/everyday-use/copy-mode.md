# Copy mode keys

Press **Ctrl+Shift+X** to open copy mode. Move with arrows, press **v** to
select, then **y** to copy and leave. Your program keeps running.

## Move

| Keys | Destination |
| --- | --- |
| `h j k l`, arrows | Adjacent cell or screen row |
| `w b e ge` | Next word, previous word, word end, previous word end |
| `W B E gE` | Same motions using whitespace-separated words |
| `0 ^ $` | Line start, first non-blank, line end |
| `gg G`, `{n}G`, `{n}%` | First, last, numbered line, percentage |
| `H M L` | Top, middle, bottom of visible output |

Counts repeat motions: `3w`. Line motions join soft wraps; `j`/`k` follow screen rows.
Letters use key positions even with a Hangul input source.

## Scroll and find

| Keys | Action |
| --- | --- |
| Ctrl-e/y/d/u/f/b, PageUp/Down | Scroll |
| `zz zt zb` | Place cursor row at middle, top, bottom |
| `f F t T ; ,` | Find a character; repeat forward/backward |
| `{ }`, `%`, `[[ ]]` | Paragraph, matching bracket, previous/next prompt |
| `/ ? n N * #`, F3/Shift+F3 | Search and repeat |

`f` accepts 두벌식 initials: `fr` matches `r`, 가, 까, …; `fR` matches `R`, 까, … .

## Select and copy

| Keys | Action |
| --- | --- |
| `v`, `V`, Ctrl-v | Character, line, block selection; repeat to cancel |
| `o` / `O`, `gv` | Swap ends; restore previous selection |
| `y`, `y{motion}`, `yy`, `Y` | Copy selection, motion, line, to line end |
| Enter, Ctrl+Shift+C, Cmd+C | Copy selection or current match |
| `gn` | Select search match |

Copying leaves the mode. In a block, `$` extends each row to its end.

## Select a text object

Combine `y` or a selection with an object: `yiw`, `y2aw`, `v2i(`.

| Objects | Select |
| --- | --- |
| `iw aw`, `iW aW` | Inside/around word or whitespace-separated word |
| `i" a"`, `i' a'`, ``i` a` `` | Quotes |
| `i( a(` / `ib ab`, `i[ a[`, `i{ a{` / `iB aB`, `i< a<` | Brackets |
| `it at`, `ip ap` | Tag, paragraph |
| `io ao` | Command output, command including prompt |

## Split code-style words

Press **Space**, then `w`, `b`, `e`, or `ge` to cross camelCase, acronyms,
digits, hyphens, and underscores. Numeric literals stay together.
Use `i<Space>w` / `a<Space>w` for objects; `3<Space>w` repeats. Uppercase motions use whitespace-separated words.

## Refresh or leave

- **r:** show newly received output.
- **q**, **i**, **Ctrl+C:** leave.
- **Esc:** cancel a pending key or selection; press again to leave.

## Jump to visible text

1. Press `s` and type a literal query; IME input works here.
2. Type its label, or press Enter for the current/next match.
3. Tab / Shift+Tab chooses another match; Esc cancels.

Smart case applies. No matches closes search. A visual jump extends selection.
`ys` copies up to a jump; `yr` jumps before copying the following motion.

## Surround and copy

These commands copy transformed text without editing the terminal:

| Example | Copied result |
| --- | --- |
| `ySiw]` | Word in square brackets |
| `cs]{` | Square brackets replaced by spaced braces |
| `ds"` | Surrounding quotes removed |
| `ySS)` | Current line wrapped from first non-blank |
| Visual `S` / `gS` | Selection wrapped with/without linewise indentation |

Opening `(`, `{`, `[` adds inner spaces; closing delimiters do not.
Use `t`/`<` for tags, `f`/`F` for functions, `l` for LaTeX environments.
Finish a replaced tag with Enter to keep attributes or `>` to drop them.
Esc cancels and keeps the selection.

## Search syntax

| Syntax | Meaning |
| --- | --- |
| `\(x\)`, `foo\|bar`, `\d\+`, `a\{2,4}` | Vim groups, alternatives, quantifiers |
| `(x)`, `foo|bar` | Literal text |
| `\c` / `\C` | Ignore / respect case |
| `\v` / `\m` / `\M` / `\V` | Magic level |

Default matching is case-sensitive and stays within logical lines.
Advanced atoms `\%`, `\@`, `\_`, `\z` are unsupported. Invalid patterns match nothing.

## Copy behavior

- Trailing spaces are removed; selected empty rows remain.
- Linewise copies omit Vim's final register newline.
- `G`/`M` ignore unused rows below output; whitespace-only rows delimit paragraphs.
- `%` uses built-in bracket matching, without Matchit.

## Customize keys and words

Modal bindings can replace single keys with named actions such as `cancel`,
`accept`, `copy`, `refresh`, `left`, and `next`.

Set [iskeyword](../customize/terminal-settings.md#copy-mode) to change word motions,
`iw aw`, and `* #`. It does not change mouse selection or whitespace-separated words.
Space-prefixed motions always keep their own rules: with `-` in `iskeyword`,
`w` skips `foo-bar` while `<Space>w` stops at `bar`.
