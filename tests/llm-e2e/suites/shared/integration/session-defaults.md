# New terminal launch defaults

Use the private fixture. Set zsh's `ZDOTDIR` to a fresh empty directory
so login-shell testing does not run the user's personal startup scripts. Do not
change HOME or use the user's live terminal sessions.

## Configure future sessions

1. Verify the initial shell uses the GUI launch directory. Change it to a
   different private directory and retain its PID, cwd and a uniquely named
   environment variable.
2. Configure `/bin/zsh`, login enabled, a private directory containing spaces,
   and a literal environment value containing Unicode and `$(not_a_command)`.
3. Open Terminal → Session defaults using the actual Godot controls. Inspect
   `session-defaults-dialog.png`: shell, login, directory and environment fields
   are readable; the fields belong to new local sessions and are not presented
   as remote host settings.

## Prove real launch behavior

1. Create a tab. A subprocess of its actual PTY must report the source shell's
   current directory, literal configured environment value and parent PID;
   zsh must report login enabled. The configured initial directory must not
   override an existing source pane's live cwd.
2. Change to non-login mode and another literal value, then create a split.
   The new shell must use those settings without command expansion and inherit
   its source directory. Change that shell's cwd and create another split;
   inheritance must still work while the configured initial directory stays set.
3. Return to the initial shell. Its cwd, environment and process remain the same.
   Metadata-only defaults do not establish this behavior.
4. Delete a source directory and create both a split and a tab from that pane.
   Both actual PTYs must start in the remembered original GUI launch directory.
   Delete that launch directory too and repeat; both must fall back to the
   owner's home directory. Descendants must preserve the original fallback.

## Reject invalid defaults without mutation

1. Try a missing executable, missing directory and a protected capability
   environment override. Each produces a concrete error.
2. Working defaults and all existing PTY identities/counts stay unchanged.
3. Preserve failing traces and report unsupported paths explicitly; no clipboard,
   desktop input or personal startup configuration is needed for this fixture.
