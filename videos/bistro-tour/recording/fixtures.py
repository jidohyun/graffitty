"""Build the bistro-orders repository and the prepared agent conversations.

The repository is real: its server, traffic replay, tests and release script
run in the recorded panes. Agent conversations are scripted playbacks whose
shell tool steps execute in that repository.
"""
import json
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
PROJECT = HERE / "project"

BUILD_PROMPT = ("Add evening reservations: POST /reservations seats a party at a free table "
                "for its time slot. Add tests and update the changelog.")
REVIEW_PROMPT = "Review the uncommitted reservations change before we ship 1.2.0."
SPECIALS_PROMPT = "Write tonight's three specials for the menu board, one line each with a price."

# The 1.1.0 server, before reservations. Removing exactly these lines from the
# working-tree server reproduces the committed file.
RESERVATION_LINES = [
    "from reservations import Book\n",
    "BOOK = Book()\n",
    '        elif path == "/reservations":\n            self.reply(200, BOOK.tonight())\n',
    '            elif self.path == "/reservations":\n'
    '                self.reply(201, BOOK.reserve(body.get("name"), body.get("party"), body.get("slot")))\n',
]
RESERVATION_ROW = "| `GET /reservations`, `POST /reservations` | Bookings; `{\"name\": \"Lee\", \"party\": 2, \"slot\": \"19:30\"}` |\n"


def git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def build_repository(repo: Path):
    shutil.copytree(PROJECT, repo, ignore=shutil.ignore_patterns("__pycache__"))
    (repo / "release.sh").chmod(0o755)
    (repo / ".gitignore").write_text("__pycache__/\nlogs/\ndist/\n")
    server = (repo / "server.py").read_text()
    readme = (repo / "README.md").read_text()
    changelog = (repo / "CHANGELOG.md").read_text()
    reservations = {name: (repo / name).read_bytes() for name in ["reservations.py", "tests/test_reservations.py"]}
    base = server
    for line in RESERVATION_LINES:
        assert line in base, line
        base = base.replace(line, "")
    (repo / "server.py").write_text(base)
    (repo / "README.md").write_text(readme.replace(RESERVATION_ROW, ""))
    (repo / "CHANGELOG.md").write_text(changelog[:changelog.index("## 1.2.0")] + changelog[changelog.index("## 1.1.0"):])
    for name in reservations:
        (repo / name).unlink()
    git(repo, "init", "-q", "-b", "main")
    for key, value in [("user.name", "Camille Laurent"), ("user.email", "camille@bistro.example"),
                       ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")]:
        git(repo, "config", key, value)
    history = [
        (["menu.json", "orders.py", "tests", "README.md", ".gitignore"], "Add order rules and tonight's menu", None),
        (["server.py", "static"], "Serve the orders API and the menu page", "v1.0.0"),
        (["CHANGELOG.md"], "Write kitchen tickets for the printer", None),
        (["rush.py", "board.py"], "Replay a dinner rush; add the kitchen board", None),
        (["release.sh", "docs"], "Add the release script and allergen sheet", "v1.1.0"),
    ]
    for paths, message, tag in history:
        git(repo, "add", *paths)
        git(repo, "commit", "-qm", message)
        if tag:
            git(repo, "tag", tag)
    git(repo, "checkout", "-qb", "reservations")
    # The working tree holds the reservations change the Claude session made.
    (repo / "server.py").write_text(server)
    (repo / "README.md").write_text(readme)
    (repo / "CHANGELOG.md").write_text(changelog)
    for name, data in reservations.items():
        (repo / name).write_bytes(data)
    subprocess.run([sys.executable, "-m", "unittest", "-q"], cwd=repo, check=True, capture_output=True)
    for cache in repo.rglob("__pycache__"):
        shutil.rmtree(cache)


def shell(command, name="Bash", ms=900, lines=3):
    return {"type": "tool", "name": name, "input": command, "command": ["/bin/sh", "-ec", command],
            "ms": ms, "preview_lines": lines}


def file_tool(name, path, summary, source, ms=450):
    # Line counts come from the actual repository, never from a typed number.
    command = f"printf '{summary}\\n' \"$({source} | wc -l | tr -d ' ')\""
    return {"type": "tool", "name": name, "input": path, "command": ["/bin/sh", "-ec", command],
            "ms": ms, "preview_lines": 1}


def agents(out: Path):
    common = {"directory": "~/bistro-orders", "real_tool_calling": True, "char_ms": 6, "tip": "",
              "status": {"branch": "reservations"}}
    route = ('        elif path == "/orders":\n            self.reply(200, OPEN[-12:])\n')
    build = {**common, "model": "Claude Opus", "title": "Reservations", "completion": {"elapsed_ms": 94000}, "turns": [{
        "prompt": BUILD_PROMPT,
        "steps": [
            {"type": "think", "ms": 700, "text": "Reading the order service"},
            # Show the base server: the working tree already holds this change.
            file_tool("Read", "orders.py", "Read %s lines", "cat orders.py"),
            file_tool("Read", "server.py", "Read %s lines", "git show HEAD:server.py"),
            {"type": "message", "text": "orders.py already owns the tables and OrderError, so bookings can reuse both. "
                                        "I'll keep them in their own module and add two routes."},
            file_tool("Write", "reservations.py", "Wrote %s lines to reservations.py", "cat reservations.py"),
            {"type": "edit", "path": "server.py", "line": 35, "before": route,
             "after": route + '        elif path == "/reservations":\n            self.reply(200, BOOK.tonight())\n'},
            file_tool("Write", "tests/test_reservations.py", "Wrote %s lines to tests/test_reservations.py",
                      "cat tests/test_reservations.py"),
            shell("python3 -m unittest 2>&1 | tail -n 3", ms=1200),
        ],
        "response": "Reservations are in.\n\n"
                    "- `reservations.py` seats each party at the first free table for its slot (18:00 to 21:30, up to 8 guests).\n"
                    "- `POST /reservations` books, `GET /reservations` lists tonight's bookings.\n"
                    "- 6 new tests cover the party limit, unknown slots and a full slot; all 12 tests pass.\n"
                    "- CHANGELOG has a 1.2.0 entry."}]}
    review = {**common, "model": "GPT-6-Astra medium", "title": "Review", "turns": [{
        "prompt": REVIEW_PROMPT,
        "steps": [
            shell("git status --short", "exec_command", lines=5),
            shell("git diff --stat", "exec_command", lines=4),
            shell("python3 -m unittest 2>&1 | tail -n 3", "exec_command", ms=1200),
        ],
        "response": "No blocking issues. Two notes before 1.2.0:\n\n"
                    "1. `Book` keeps bookings in memory, so a server restart clears tonight's list. "
                    "Fine for same-evening service; persist it before taking bookings days ahead.\n"
                    "2. `reserve()` takes the first free table whatever the party size, so a party of 6 can land on a two-top. "
                    "Worth adding table capacities in 1.3.\n\n"
                    "The tests cover party limits, unknown slots and a full slot, and all 12 pass. Ready to ship."}]}
    specials = {**common, "model": "Claude Opus", "title": "Specials", "turns": [{
        "prompt": SPECIALS_PROMPT,
        "steps": [{"type": "think", "ms": 900, "text": "Choosing dishes from tonight's market"}],
        "response": "Tonight's specials:\n\n"
                    "1. Gratin dauphinois with roast chicken, €21\n"
                    "2. Confit de canard, cherry jus, €26\n"
                    "3. Clafoutis aux cerises, €9"}]}
    allergens = {**common, "model": "GPT-6-Astra medium", "title": "Allergens", "turns": [{
        "contains": "Tonight's specials",
        "steps": [shell("grep -E 'Gratin|Confit|Clafoutis' docs/allergens.md", "exec_command", lines=3)],
        "response": "Allergen labels for the board:\n\n"
                    "- Gratin dauphinois: milk\n"
                    "- Confit de canard: none listed\n"
                    "- Clafoutis aux cerises: gluten, egg, milk\n\n"
                    "All three are in docs/allergens.md, so the board can print them as written."}]}
    folder = out / "agents"
    folder.mkdir(parents=True, exist_ok=True)
    for name, config in {"build": build, "review": review, "specials": specials, "allergens": allergens}.items():
        (folder / (name + ".json")).write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    build_repository(Path(sys.argv[1]))
    agents(Path(sys.argv[2]))
