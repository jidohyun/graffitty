# Pane working directories

Start with `gft-gui --cwd /path/to/project`. On Windows use native PowerShell
with Graffitty's OSC 7 integration; Unix also supports plain shells without it.
Launch from a different working directory; explicit `--cwd` must win. Run `pwd`
in the first shell to verify the requested initial directory.
Create ALPHA and BETA in one tab. Change ALPHA into a temporary directory whose
name contains spaces. Change BETA into a different directory and leave BETA focused.
Click ALPHA's Split right button. The new pane must start in ALPHA's current directory,
not BETA's or the original configured directory. Verify using `pwd` in the new shell.

Remove ALPHA's now-empty directory while its shell still has that directory open.
On Windows, which locks open current directories, move both shells out first and
disable ALPHA's cwd reporting before moving it, leaving the previous OSC 7 report
stale. Delete the reported directory and verify that deletion succeeds.
Split ALPHA again. The new shell must start in the original startup directory.
Changing directories and splitting must never overwrite that remembered fallback.
Confirm the original shells and their PIDs survive. Clean up the temporary directory.
