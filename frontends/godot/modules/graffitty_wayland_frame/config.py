def can_build(env, platform):
    return platform == "linuxbsd" and env["wayland"]


def configure(env):
    pass
