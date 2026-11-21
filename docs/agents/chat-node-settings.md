# Save and run a chat node

## Save settings for next time

Create a config file, then open the node with it. For example, with Slack:

```sh
printf '{}\n' > slack.json
gft node slack-send --config slack.json
```

Press **Ctrl+S** after editing. Run the same command to load your settings later.
Saving does not resume sending; press **Ctrl+Enter** to apply.

For unattended use, provide the token through the service's environment variable
or a [named credential source](../developers/automation-and-extensions/secrets.md):

| Service | Token variable |
| --- | --- |
| Telegram | `TELEGRAM_BOT_TOKEN` |
| Slack | `SLACK_BOT_TOKEN` |
| Discord | `DISCORD_BOT_TOKEN` |

Add `--headless` to run without a form or prompts; configure credentials and the
destination first. Add `--edit` to start paused or `--once` to exit after one message.

Tokens entered in the form are hidden and are not saved in node settings.
Add `--edit` to start paused or `--once` to exit after one message.
