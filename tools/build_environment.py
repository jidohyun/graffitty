"""Keep equivalent native library search paths from invalidating Cargo's cache."""
import os


def native_build_environment():
    env = os.environ.copy()
    if "PKG_CONFIG_PATH" in env:
        env["PKG_CONFIG_PATH"] = os.pathsep.join(dict.fromkeys(env["PKG_CONFIG_PATH"].split(os.pathsep)))
    return env
