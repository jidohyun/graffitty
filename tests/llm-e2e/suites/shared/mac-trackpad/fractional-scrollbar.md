Fill the terminal with scrollback. Scroll slowly using the trackpad and reverse direction: the scrollbar must follow the fractional content position, without whole-row jumps or a 100 ms polling delay. Move the scrollbar thumb: the terminal must preserve the fractional position supplied by the scrollbar. At the live bottom, the fractional remainder must be zero.

The replay uses the real scrollbar binding, checks trackpad updates within 40 ms, and sends fractional scrollbar values through its value_changed signal to verify the reverse path.
