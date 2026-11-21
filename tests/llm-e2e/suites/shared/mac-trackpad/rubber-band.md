# Terminal rubber band

Fill scrollback with numbered rows. With two fingers on a trackpad (or one
finger on a touchscreen), scroll to the top and keep pulling: the text must
follow the fingers at about a twentieth of their travel, leaving an empty band
of the terminal background above the first row, while the viewport stays on the
first row. Lift the fingers after resting: the text springs back smoothly and
settles exactly where it was. Repeat at the live bottom, where the band opens
below the prompt.

Flick into an edge so momentum carries the content there: it must overshoot
briefly and return, never stay displaced. Pull, then scroll back the other way
without lifting: the pull is given up first, and only then does the content
scroll.

A mouse wheel must never stretch the content, however fast it turns. Vim and
other alternate-screen or mouse-reporting applications must not stretch either.
A terminal with nothing to scroll yet still pulls, both up and down. The look
is the same on every platform.

The replay injects pan gestures carrying Chromium's scroll phases and checks
the pull distance against the one-twentieth mapping, the empty band in the
rendered frame, the unchanged viewport row, the release settling at zero, the
momentum bounce, giving the pull up before scrolling, and that unphased, wheel
and alternate-screen scrolling leave the content in place.
