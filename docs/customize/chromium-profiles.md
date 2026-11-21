# Chromium profiles

Choose where browser logins and site data live. All paths below belong to the
**server computer**.

| Need | Choose |
| --- | --- |
| Fresh browser, no saved logins | Temporary profile; default |
| Reuse your logins | Persistent profile |
| Several agents starting with the same logins | Independent copies of a template |

## Keep your logins

```sh
gft chromium new --profile "$HOME/.local/state/graffitty/chromium/profiles/work" --url https://example.com
```

Sign in once, then reuse that profile. Choose the root containing `Default/`,
not `Default/` itself. Only one running browser can use it.
Explicit profiles survive closing and failed launches.

## Profile templates

1. Create a persistent Graffitty profile and sign in.
2. Close that browser before copying its databases.
3. Launch each agent's browser with:

```sh
gft chromium new --profile-from "$HOME/.local/state/graffitty/chromium/profiles/work" --url https://example.com
```

Each launch gets a temporary copy. Sign-outs and refreshed tokens affect only
that copy. Reopen the original with `--profile` to update the template.
Other browsers' encrypted cookies may not work in Graffitty.

## Set a server default

In `server.toml`, choose **one**:

```toml
[chromium]
profile = "/absolute/path/to/profile"
# Or profile_template = "/absolute/path/to/template"
```

Save a checkpoint, then use `gft server restart` to apply it.
Explicit `--profile` or `--profile-from` wins; `--profile ""` requests temporary storage.

## Temporary storage

```toml
[chromium]
sessions_directory = '%(temp)/graffitty/chromium/sessions'
delete_session_on_close = true
```

Use `%(temp)` for OS temporary storage, `%(state)` for server state, or an absolute path.
Set deletion to `false` to retain generated sessions. Retention does not reopen
them automatically; select the retained `cef-profile` folder with `--profile`.
A crash can leave temporary files behind.

## Open a file

```sh
gft chromium open ~/Downloads/result.pdf
```

This reuses the associated browser or creates one. Add `-t %3` or
`-t main:1.2` to choose a pane, or `--new` to create a browser; these choices
cannot be combined. Profile flags affect creation only, so use `--new` to ensure
one applies rather than combining it with `-t`.

## Remote stream quality

Adjust each saved server connection:

| Setting | Effect |
| --- | --- |
| Auto resolution | Follows displayed size, up to 1440p |
| Explicit resolution, including 2160p | Upper bound; does not change page layout |
| Bitrate | Shared by visible browser panes; audio/transport need extra bandwidth |
| Auto bitrate | Up to 20 Mbps, reduced for smaller panes |
