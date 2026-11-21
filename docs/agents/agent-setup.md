# Set up a coding agent

Supported agents: **Claude, Codex, Pi, and OpenCode**.

## Connect the agent to Graffitty

Preview integration changes:

```sh
gft integrate agent claude
```

Replace `claude` with `codex`, `pi` or `opencode` for another agent.
Apply the setup, then check it:

```sh
gft integrate agent claude --apply
gft integrate agent claude --status
```

After setup:

- Launch the agent in a Graffitty terminal.
- **Pi already running:** use `/reload`.
- **OpenCode:** restart its clients and server; version 2.0.32 or later is required.

## See which agents need you

- Open **View (<img class="menu-icon" src="../images/menu/eye.svg" alt="" width="18" height="18">) → Agents** to see agents across connected computers and sessions.
- Check **Needs you** and **Done** for work requiring attention.

See [Agents and sounds](agents.md) for grouping and notification preferences.

## Give an agent workspace controls

Ask it to run `gft skill graph` to read the built-in guide for opening panes,
running programs, and connecting agents. For browser tasks, use `gft skill chromium`.
See [CLI skill guides](../everyday-use/cli.md#give-an-agent-workspace-instructions).

## Let agents work together

[Connect agents](connect-agents.md) to share a conversation or deliver a message
when another agent finishes.

## Remove the integration

```sh
gft integrate agent claude --remove --apply
```
