"""Exhaustive cases: every start position x command. python3 exh.py GROUP > cases.jsonl"""
import json, sys

BUFFERS = [
    ["foo bar.baz  qux", "", "  indented line", "x", "", "", "last line here"],
    ['if (a && (b || c)) { return [1, 2]; }', 'say "he said \\"hi\\" ok" now', '<p class="x">hi <b>there</b></p>', "it's 'q' `cmd arg`"],
    ["a.b,c;d", "...", "  --x--", "word", "f(x) [ y ] {z}"],
    ["abc", "", "", "def ghi", "  jkl mno", "end"],
    ['"a" x "b"', "  (  )", "x = foo(bar, baz(1))", "<a><b>t</b> u</a>", "[] {} <>"],
]
MOTIONS = ["w", "b", "e", "ge", "W", "B", "E", "gE", "0", "^", "$", "g_", "h", "l", "j", "k",
           "+", "-", "{", "}", "%", "gg", "G", "H", "M", "L"]
OBJECTS = ["iw", "aw", "iW", "aW", 'i"', 'a"', "i'", "a'", "i`", "a`", "i(", "a(", "ib", "i[", "a[",
           "i{", "a{", "i<lt>", "a<lt>", "it", "at", "ip", "ap"]

def finds(lines):
    chars = sorted({c for l in lines for c in l if c not in " "})
    return [k + ("<lt>" if c == "<" else c) for k in "fFtT" for c in chars]

group = sys.argv[1]
i = 0
for b, lines in enumerate(BUFFERS):
    starts = [(y, x) for y, l in enumerate(lines) for x in range(max(1, len(l)))]
    if group == "motion":
        cmds = [[c + m] for m in MOTIONS for c in ["", "2", "3"]]
        cmds += [[f] for f in finds(lines)] + [[f, r] for f in finds(lines)[::3] for r in [";", ",", "2;"]]
    elif group == "yank":
        cmds = [["y" + c + m] for m in MOTIONS for c in ["", "2"]] + [["y" + f] for f in finds(lines)[::2]]
        cmds += [["yy"], ["2yy"], ["Y"]]
    elif group == "object":
        cmds = [["y" + c + o] for o in OBJECTS for c in ["", "2"]]
    elif group == "visual":
        cmds = [["v", o, "y"] for o in OBJECTS] + [["v", o, o, "y"] for o in OBJECTS]
        cmds += [[v] + [m] + ["y"] for v in ["v", "V", "<C-v>"] for m in ["w", "e", "$", "j", "b", "k", "}", "2w"]]
        cmds += [["v", "j", "o", "w", "y"], ["<C-v>", "j", "$", "y"], ["v", "iw", "o", "y"]]
    elif group == "search":
        words = sorted({w for l in lines for w in l.replace('"', " ").replace("(", " ").split() if w.isalnum()})
        cmds = [[s] for s in ["*", "#", "2*", "2#"]] + [[s, n] for s in ["*", "#"] for n in ["n", "N"]]
        cmds += [["/" + w + "<CR>", n] for w in words for n in ["", "n", "N"]]
        cmds += [["?" + w + "<CR>", n] for w in words for n in ["", "n"]]
    for y, x in starts:
        for parts in cmds:
            print(json.dumps({"id": i, "buf": b, "lines": lines, "cursor": [y, x], "keys": "".join(parts), "cmds": parts}))
            i += 1
