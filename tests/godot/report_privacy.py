"""Remove machine-specific paths from published test evidence."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def public_text(text: str) -> str:
    # Replace the more specific path first, including JSON-escaped Windows paths.
    for path, replacement in [(ROOT, '${REPO}'), (Path.home(), '${HOME}')]:
        value = str(path)
        text = text.replace(value.replace('\\', '\\\\'), replacement)
        text = text.replace(value, replacement)
    return text
