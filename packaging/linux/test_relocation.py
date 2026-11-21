#!/usr/bin/env python3
"""Native integration test: relocation and atomic release switch with delayed dlopen."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

from shared_libraries import bundle


def main():
    with tempfile.TemporaryDirectory(prefix="graffitty-relocation-") as temporary:
        root = Path(temporary)
        build = root / "build"
        build.mkdir()
        (build / "late.c").write_text('int version(void) { return VERSION; }\n')
        (build / "app.c").write_text('''#include <dlfcn.h>
#include <stdio.h>
#include <unistd.h>
int main(int argc, char **argv) {
  if (argc > 1) { puts("ready"); fflush(stdout); sleep(3); }
  void *lib = dlopen("liblate.so", RTLD_NOW);
  if (!lib) { fprintf(stderr, "%s\\n", dlerror()); return 1; }
  int (*version)(void) = dlsym(lib, "version");
  if (!version) return 2;
  printf("%d\\n", version()); return 0;
}
''')
        for version in (1, 2):
            stage = root / f"stage-{version}"
            stage.mkdir()
            subprocess.run(["cc", "-shared", "-fPIC", f"-DVERSION={version}",
                            str(build / "late.c"), "-o", str(build / "liblate.so")], check=True)
            # Force a DT_NEEDED so the bundler discovers the otherwise late-loaded library.
            subprocess.run(["cc", str(build / "app.c"), "-o", str(stage / "gft-gui"),
                            "-Wl,--no-as-needed", "-L" + str(build), "-llate",
                            "-Wl,-rpath," + str(build), "-ldl"], check=True)
            bundle(stage)
            destination = root / "installation with spaces/releases" / str(version)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(stage, destination)
        shutil.rmtree(build)
        install = root / "installation with spaces"
        (install / "current").symlink_to("releases/1")
        launcher = install / "launch"
        launcher.write_text('#!/bin/sh\nset -eu\nrelease=$(readlink -f "$(dirname "$0")/current")\nexec "$release/gft-gui" "$@"\n')
        launcher.chmod(0o755)
        env = dict(os.environ)
        env.pop("LD_LIBRARY_PATH", None)
        old = subprocess.Popen([str(launcher), "wait"], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, env=env, cwd="/")
        assert old.stdout.readline().strip() == "ready"
        (install / "next").symlink_to("releases/2")
        os.replace(install / "next", install / "current")
        assert subprocess.check_output([str(launcher)], text=True, env=env, cwd="/").strip() == "2"
        stdout, stderr = old.communicate(timeout=10)
        assert old.returncode == 0 and stdout.strip() == "1", (stdout, stderr)
        print("PASS: private libraries survive relocation, spaces, removed build inputs and atomic release switch")
        print("PASS: running release keeps v1; new launch uses v2 without LD_LIBRARY_PATH")


if __name__ == "__main__":
    main()
