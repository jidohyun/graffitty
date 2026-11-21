# Credential sources

Keep API tokens in your environment or secret manager. Graffitty settings store
a credential name, so you can reuse it without copying tokens into config files.

## Add a named credential

Start here if you want to select an account explicitly.

1. Open `~/.config/graffitty/secrets.toml` on the machine running the node or server.
2. Define an environment variable or secret-manager command:

   ```toml
   [secrets.decisions_work]
   env_var = "OPENROUTER_WORK_API_KEY"

   [secrets.telegram_work]
   command = ["pass", "show", "services/telegram/bot-token"]
   ```

3. Select the name when launching a node:

   ```sh
   gft node systemone --credential decisions_work --question 'Ready to ship?'
   gft node telegram-send --credential telegram_work --chat-id 123
   ```

Restart the affected node or server after changing credential definitions.
For remote nodes, create the file on the remote machine.

## Choose where a token comes from

| Selection | Lookup |
| --- | --- |
| `--credential NAME` or config `credential` | Only that named source; errors never switch accounts |
| No explicit name | The service's environment variable, then an optional default binding |
| Neither is available | Interactive chat nodes may prompt; headless nodes and SystemOne fail |

### Set a default binding

Skip this when every launch passes `--credential`.

```toml
[defaults]
OPENROUTER_API_KEY = "decisions_work"
TELEGRAM_BOT_TOKEN = "telegram_work"
```

The service's environment variable still wins over these defaults.
Chat and channel IDs are ordinary settings, separate from token lookup.

## Use a secret-manager command

For example, with fnox:

```toml
[secrets.telegram_work]
command = ["fnox", "--non-interactive", "-P", "telegram-work", "get", "TELEGRAM_BOT_TOKEN"]
env = { FNOX_PROMPT_AUTH = "false" }
timeout_seconds = 5
cache_seconds = 300
```

- Authenticate the helper separately. It must work without prompting.
- Print only the token on stdout. Extra notes or fields must be removed by a helper.
- Arguments are literal: shell syntax and `~` are not expanded.
- Commands run beside `secrets.toml` unless an absolute `cwd` is set.
- Use an absolute executable path if the GUI's `PATH` cannot find the helper.

Each source has exactly one `env_var` or `command`. `env` holds non-secret
helper settings. Never put token values in this file or command arguments.

### Cache and timeout

Successful command results are cached for five minutes by default. Set
`cache_seconds = 0` for a fresh lookup each time. Failures are not cached.
The timeout defaults to five seconds.

## Use a credential with dictation

Select a source in `server.toml`:

```toml
[dictation]
enabled = true
provider = "gemini"

[dictation.providers.gemini]
credential = "dictation_gemini"
```

Define `dictation_gemini` in `secrets.toml` using either source type above.
The server resolves it; clients do not receive the key.

Without a name, built-in providers use `GRAFFITTY_GEMINI_API_KEY` or
`GRAFFITTY_OPENAI_API_KEY`, then their default binding. Custom providers require
an explicit credential, model, and base URL. See [dictation](../../everyday-use/dictation.md).

## Use a credential for Telegram login codes

Choose a **Credential name** in Remote Access Settings (default `graffitty-2fa`).
A token saved in the device's credential store takes precedence; otherwise,
Graffitty looks up that name in `secrets.toml`.

```sh
gft server --telegram-credential telegram_work --telegram-chat-id 123
```

This saves authentication settings and exits without sending a message.
See [remote access](../../remote-access/index.md).

## File location and permissions

| Setting | Location |
| --- | --- |
| Default | `$XDG_CONFIG_HOME/graffitty/secrets.toml`, or `~/.config/graffitty/secrets.toml` |
| Windows home | `USERPROFILE` replaces `HOME` |
| Explicit override | Absolute path in `GRAFFITTY_SECRETS_CONFIG` |

Protect the file like an executable: configured commands run with the consumer's
permissions. Graffitty does not discover credential files in project directories.
Node settings and checkpoints save references rather than token values.
