# Passwords and login codes

Set login requirements on the computer running your sessions. Start with [Remote access](index.md) to enable sharing.

## Choose a password

In **Sessions (<img class="menu-icon" src="../images/menu/panels-top-left.svg" alt="" width="18" height="18">) → Remote Access Settings…**:

| Choice | Behavior |
| --- | --- |
| Temporary password | Generated whenever sharing starts; choose 6, 8, or 10 characters |
| Manual password only | A permanent password that survives app restarts |
| Regenerate | Replace the temporary password and disconnect clients |
| Require Telegram 2FA | Require a code after a correct password |

Changing authentication settings disconnects existing clients so they authenticate again.
Removing the permanent password returns to temporary-password mode.

## Add Telegram login codes

1. Create a bot with Telegram's **@BotFather**.
2. Send the bot `/start` and find your numeric chat ID using `getUpdates`.
3. Enable 2FA and enter the bot token and chat ID.
4. On login, enter the six-digit code within two minutes.

- See [Telegram's bot setup guide](https://core.telegram.org/bots/tutorial).
- A remembered password does not skip 2FA.
- A code works for one login only. If delivery fails, access is denied.
- Tokens are stored in the OS credential store. Leave the token blank to keep it.
- For command-backed credentials, use [secret sources](../developers/automation-and-extensions/secrets.md).
