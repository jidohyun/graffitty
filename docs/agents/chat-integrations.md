# Send messages to chat

Choose your service below. A chat node sends messages from the graph;
it does not listen for replies.

## Telegram

1. Create a bot with **@BotFather**. Start a chat with it or add it to a group.
2. Copy the token from BotFather. Send the bot `/start`, then use
   [Telegram getUpdates](https://core.telegram.org/bots/api#getupdates) to find the numeric chat ID.
3. Run `gft node telegram-send` inside Graffitty. Enter the token and chat ID.

## Slack

1. Install a bot with `chat:write` and invite it to your channel.
2. Copy the bot token from **OAuth & Permissions** in your Slack app.
   Copy the channel ID from its details. Add `files:write` for attachments.
3. Run `gft node slack-send` inside Graffitty. Enter the token and channel ID.

## Discord

1. Create a bot in the [Discord Developer Portal](https://discord.com/developers/applications),
   then invite it with **View Channel** and **Send Messages** permissions.
2. Turn on Developer Mode to copy the channel ID. Have the bot token ready.
3. Run `gft node discord-send` inside Graffitty. Enter the token and channel ID.

Add **Attach Files** for uploads or **Embed Links** for embeds.

## Connect the node

1. Connect the agent's **Turn completed** output to **Send to …**.
2. Keep the node running. Each completed turn sends the agent's last message.

Use **Send** instead if the agent should choose when to post.
Manual Prompt, Filter, and Parallel outputs also work.

## Preview or retry

| Key | Action |
| --- | --- |
| **F5** | Pause and preview the next message without sending |
| **Ctrl+Enter** | Apply settings, resume, or retry a failed message |
| **Tab / Shift+Tab** | Move between fields |
| **Ctrl+C** | Stop |

Editing pauses new deliveries. A send already in progress may finish.
**Delivered** means the service accepted the message.

For a failure, check the log and correct the cause before retrying.
Keep the same destination and template after a partial send. Restarting can
send duplicates.

## Save or customize

See [saved and unattended chat nodes](chat-node-settings.md) for reusable settings
and credentials. See [message formatting](chat-message-format.md) to change text
or attach a file.
