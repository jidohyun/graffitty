# Tab animation handoffs preserve the terminal

## Prepare config and tabs

1. Launch from the repository root:

   ```sh
   mise run dev -- --world=color --bg=#101822 --shell=/bin/sh --tabs=2 \
     --config=tests/llm-e2e/suites/godot/flat-world/tab-animation-handoff.conf
   ```

2. In each tab, run `printf 'HANDOFF ALIGNMENT 0123456789\nSECOND LINE 0123456789\n'`.
3. Return to the first tab and wait for the animation to finish.

## Switch tabs

1. Start a screen recording.
2. Click the second tab and let the animation finish.
3. Switch back to the first tab and let the animation finish.

## Verify animation handoffs

1. Review each switch frame by frame.
2. Confirm the text does not disappear or blur for a frame when the animation starts.
3. Confirm the text does not shift by a pixel when it becomes animation pieces.
4. Confirm the text does not shift by a pixel when the animation finishes.
5. Scatter frontends: confirm the leaving window's frame (title bar, buttons,
   border) and its background colour recede and fade first while its text flies
   off, and that the arriving frame and background colour approach from a
   distance and fade in last as the text completes its landing.
6. Godot (Push/Pull): confirm both tabs cross as whole panes, with no separate
   letters or dust. Midway, the leaving frame and text have left their places
   and the arriving ones have not reached theirs.
7. In both, the initial capture must match the live window without a one-frame
   pop, and the fully assembled pieces must be drawn before the live terminal
   replaces them, with no jump or blur at that handoff.
