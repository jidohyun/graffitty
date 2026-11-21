# Terminal scrollbar interactions

Run in Flat 2D, including with touch controls enabled. Create enough shell
output to fill several pages of history, then start halfway through it.

1. Drag the thumb upward and downward. The terminal history must follow it.
2. Click empty track above the thumb, then below it. Each click pages in the
   requested direction.
3. Press and hold empty track above and below the thumb. After a short initial
   delay, paging repeats until the thumb reaches the pointer.
4. Move outside the scrollbar and release. Scrolling must stop and stay stopped.
5. The world must retain its pan and zoom. No scrollbar press may reach terminal
   text-selection input. Any script or engine error fails the test.

The replay uses actual viewport mouse events and native terminal history. Its
hold durations use real elapsed time, even when other replay pacing is disabled.
