"""Write a release's entry in the listing the installers read.

    python3 tools/release_listing.py --version v0.1.0 --output ../site/public/releases \
        dist/graffitty-macos-arm64.tar.gz dist/installers/graffitty-windows-x64.zip ...

The listing is served at https://graffitty.com/releases:

    latest.txt     the latest release tag
    <tag>.txt      one line per archive: <sha256>  <name>  <address>

`<name>` is what the installers ask for; `<address>` is where that file is: by
default the asset of that name in this version's GitHub release, or
`<--archives>/<name>` for another folder. The installers trust the checksums here, so an
archive may be stored anywhere and under any name: pass `NAME=ADDRESS` after
the archives to give one its own address.
`--latest` also makes this release the one a plain install gets.
"""
import argparse
import hashlib
from pathlib import Path
import re
import sys

# Releases are published on the product's GitHub repository.
GITHUB_RELEASES = "https://github.com/graffitty/graffitty/releases/download"
TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+(?:[.+-][0-9A-Za-z.+-]+)?")
ARCHIVE = re.compile(r"graffitty-(?:macos-arm64\.tar\.gz|linux-(?:x86_64|arm64)\.tar\.gz|windows-x64\.zip)")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--version", required=True, help="release tag, e.g. v0.1.0")
    parser.add_argument("--archives", help="https URL of the folder holding the archives "
                        "(default: this version's GitHub release)")
    parser.add_argument("--output", required=True, type=Path, help="the releases folder of the website checkout")
    parser.add_argument("--latest", action="store_true", help="make this the latest release")
    parser.add_argument("archive", nargs="+", help="an archive file, or NAME=ADDRESS for one stored elsewhere")
    args = parser.parse_args()
    if not TAG.fullmatch(args.version):
        sys.exit(f"invalid version {args.version!r} (expected e.g. v0.1.0)")
    if args.archives is None:
        args.archives = f"{GITHUB_RELEASES}/{args.version}"
    if not args.archives.startswith("https://"):
        sys.exit("--archives must be an https URL")
    files, addresses = [], {}
    for item in args.archive:
        name, separator, address = item.partition("=")
        if separator:
            if not address.startswith("https://") or any(character.isspace() for character in address):
                sys.exit(f"{name}: an address must be an https URL without spaces")
            addresses[name] = address
        else:
            files.append(Path(item))
    names = [path.name for path in files]
    for path in files:
        if not ARCHIVE.fullmatch(path.name):
            sys.exit(f"{path.name} is not a release archive name")
        if not path.is_file():
            sys.exit(f"missing archive: {path}")
    if len(set(names)) != len(names):
        sys.exit("an archive is named twice")
    unknown = sorted(set(addresses) - set(names))
    if unknown:
        sys.exit(f"an address was given for {unknown[0]}, which is not among the archives")
    args.output.mkdir(parents=True, exist_ok=True)
    folder = args.archives.rstrip("/")
    lines = "".join(
        f"{sha256(path)}  {path.name}  {addresses.get(path.name, folder + '/' + path.name)}\n"
        for path in sorted(files, key=lambda path: path.name))
    listing = args.output / (args.version + ".txt")
    listing.write_text(lines, encoding="ascii", newline="\n")
    if args.latest:
        (args.output / "latest.txt").write_text(args.version + "\n", encoding="ascii", newline="\n")
    print(lines, end="")
    print(f"Wrote {listing}" + (" and latest.txt" if args.latest else ""))


if __name__ == "__main__":
    main()
