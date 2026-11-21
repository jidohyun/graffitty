from pathlib import Path
root = Path("src")
for path in root.glob("*.py"):
    print(path.name)
