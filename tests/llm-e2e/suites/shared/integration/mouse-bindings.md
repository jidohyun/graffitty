For Godot on Windows, run `python tests/platform/windows/windows_input_acceptance.py --suite mouse
--evidence <new-directory>`. The four focused cases cover configured native
buttons, exact application-reporting bytes, projected controls and the Bistro
presentation. Inspect both `mouse-controls/mouse-binding-search.png` and
`mouse-bistro/mouse-binding-search.png`. Edit → Input Settings removes bindings
and rejects invalid table references before changing any live settings. An
explicit modifier-wheel binding over a terminal takes precedence over camera
zoom. Removing the binding restores ordinary routing; no compatibility alias
or second binding schema is introduced. These injected events do not establish
physical device delivery.

Require actual Back/Forward mouse-button events to invoke literal text and a one-shot key table. Verify partial wheel movements accumulate once, explicit modifier-wheel bindings preserve the camera, horizontal wheels can scroll terminal history, and null unbinds. Search must open locally without leaking bytes. The raw application must receive exact SGR 128/129 side-button press/release and 66/67 horizontal wheel packets when mouse reporting is enabled. Configured bypass must invoke a local command instead. Invalid table references must preserve the configuration and live shell.

Inspect the search captures: search controls must remain readable over the actual terminal, the terminal header must remain reachable, and the 3D world scene must still render. Retain raw byte observations, executable hash and an honest visual-review.json. A backend-only pass is insufficient for the native side-button checks.
