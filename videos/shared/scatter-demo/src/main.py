from dataclasses import dataclass
from pathlib import Path


@dataclass
class Project:
    name: str
    root: Path
    version: str = "1.0.0"

    def source_files(self) -> list[Path]:
        return sorted(self.root.glob("src/*.py"))


def main() -> None:
    project = Project("terminal-demo", Path.cwd())
    print(f"Welcome to {project.name}")
    for number, path in enumerate(project.source_files(), 1):
        print(f"{number:02d}  {path.name}")


if __name__ == "__main__":
    main()
