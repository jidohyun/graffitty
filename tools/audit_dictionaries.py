"""Inventory map declarations and dynamic JSON usage across first-party source.

This is a review aid, not a semantic checker: map types can represent legitimate
lookup tables or fixed-shape records. Counts are matching source lines.
"""

import argparse
from collections import Counter
from dataclasses import asdict, dataclass
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PATTERNS: dict[str, dict[str, str]] = {
    ".gd": {
        "untyped_dictionary": r"\bDictionary\b(?!\s*\[)",
        "typed_dictionary": r"\bDictionary\s*\[",
        "inferred_dictionary": r"\bvar\s+\w+\s*:?=\s*\{",
    },
    ".rs": {
        "typed_map": r"\b(?:HashMap|BTreeMap)\s*<",
        "dynamic_json": r"\b(?:serde_json::Value|Value)\b",
    },
    ".py": {"dictionary": r"\b(?:dict|Dict|TypedDict)\b"},
    ".ts": {"map_or_record": r"\b(?:Map|Record)\s*<"},
    ".java": {"typed_map": r"\b(?:Map|HashMap)\s*<"},
    ".cpp": {"typed_map": r"\b(?:unordered_map|map)\s*<"},
    ".h": {"typed_map": r"\b(?:unordered_map|map)\s*<"},
}


@dataclass(frozen=True)
class Match:
    line: int
    category: str


@dataclass(frozen=True)
class FileReport:
    path: str
    language: str
    matches: list[Match]


@dataclass(frozen=True)
class AuditReport:
    totals: dict[str, int]
    files: list[FileReport]
    counting: str = (
        "matching source lines; syntactic inventory, requires semantic review"
    )


def inventory() -> AuditReport:
    names = (
        subprocess.check_output(
            ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
            cwd=ROOT,
        )
        .decode()
        .split("\0")
    )
    # World scripts are DVC-managed source, not Git-listed files.
    names += [str(path.relative_to(ROOT)) for path in (ROOT / "worlds").rglob("*.gd")]
    files: list[FileReport] = []
    totals: Counter[str] = Counter()
    for name in sorted(set(names)):
        path = ROOT / name
        if path.suffix not in PATTERNS or not path.is_file():
            continue
        if any(
            part in {"vendor", "third_party", "node_modules", "target", ".godot"}
            for part in path.parts
        ):
            continue
        matches: list[Match] = []
        for line, text in enumerate(path.read_text(errors="replace").splitlines(), 1):
            for category, pattern in PATTERNS[path.suffix].items():
                if re.search(pattern, text):
                    matches.append(Match(line, category))
                    totals[category] += 1
        if matches:
            files.append(FileReport(name, path.suffix[1:], matches))
    return AuditReport(dict(totals), files)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Write the complete JSON inventory")
    args = parser.parse_args()
    report = inventory()
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(asdict(report), indent=2) + "\n")
    print(json.dumps(report.totals, indent=2))
    print("Highest GDScript dictionary counts:")
    scripts = [file for file in report.files if file.language == "gd"]
    for file in sorted(scripts, key=lambda file: len(file.matches), reverse=True)[:15]:
        print(f"{len(file.matches):4} {file.path}")


if __name__ == "__main__":
    main()
