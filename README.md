# Graffitty Terminal Emulator

<p align="center">
  <img width="1920" height="768" alt="graffitty-wide-1mb" src="https://github.com/user-attachments/assets/14a92c6d-c0de-4b4c-9fe7-ab058b714779" />
</p>

<p align="center">
  <a href="https://graffitty.com">graffitty.com</a> · <a href="#install">install</a> · <a href="https://docs.graffitty.com">docs</a>
</p>


Wide terminal workspace with graph-based agent orchestration.

[main-demo-github.webm](https://github.com/user-attachments/assets/13afc461-ac6b-46b1-a795-aa307b60efa7)

- **Tiling window manager, and wide workspace**: the main view is tiled, but zoom out to use floating windows to stash or organize them however you like
- **Truly cross-platform**: Supports Windows, Linux, macOS, Android, and iOS. Use all machines you have to run agents and view them on mobile.
- **Remote workspace**: Any PC or mobile client can attach to remote computers
- **Chromium**: Let agents use Chromium, and see them in an **actual** Chromium window
- **Graph-based agent orchestration**: connect agents based on events, not their own memory. The graph protocol allows you to send signals to any terminal
- **Custom 3D background**: Use [bistro-world](https://github.com/graffitty/bistro-world) or make any 3D world like that on your own
- **Resource monitor**: every terminal shows CPU, RAM usage

## Install

### Linux & macOS

```sh
curl -fsSL https://graffitty.com/install.sh | sh
```

Installs to `~/.local/share/graffitty` on Linux and `/Applications/Graffitty.app` on macOS.

### Windows

```powershell
powershell -c "irm https://graffitty.com/install.ps1 | iex"
```

Installs to `%LOCALAPPDATA%\Programs\Graffitty`.

### Update

```sh
gft self update
```

### Android

Download the APK from [Releases](https://github.com/graffitty/graffitty/releases).

### iOS

Currently source build only. The working app already exists, but we're preparing a signed build. Coming soon!

## Start using Graffitty

Open Graffitty from your application launcher, then follow the
[first steps](https://docs.graffitty.com/getting-started/) and
[keyboard shortcuts](https://docs.graffitty.com/shortcuts/).

## Agent integration

To use agent status and graph orchestration, install the integration for each
agent you use. Install and sign in to the agent's own CLI first; Graffitty's
integration connects that CLI to your workspace.

For example, preview and apply Claude integration:

```sh
# claude, codex, opencode, pi
gft integrate agent claude  # preview only
gft integrate agent claude --apply
gft integrate agent claude --status
```

See [agent integration](https://docs.graffitty.com/agent-setup/) for provider details,
custom config locations and removal, and [the agent graph](https://docs.graffitty.com/connect-agents/)
to connect agents and route their messages.

### Configure your workspace

- **Appearance and shortcuts:** [Client configuration](https://docs.graffitty.com/configuration/)
  covers themes, effects, key bindings and menus.
- **Shell, fonts and navigation:** [Server configuration](https://docs.graffitty.com/server-configuration/)
  covers settings shared by the clients connected to a session server.
- **Neovim and tmux:** [Navigation setup](https://docs.graffitty.com/integrations/nvim-tmux-navigator/)
  connects editor splits, tmux panes and Graffitty panes.
- **Slack, Discord and Telegram:** [Chat integration setup](https://docs.graffitty.com/nodes/chat-integrations/)
  explains credentials, destinations and graph send nodes.
- **Sessions and remote access:** Start with [sessions](https://docs.graffitty.com/sessions/) and
  [remote control](https://docs.graffitty.com/integrations/remote-control/).
