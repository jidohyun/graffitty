Use the production remote manager with touch controls and an isolated server.

1. Split a terminal and use each half of the floating minus/plus pill. Only the focused terminal's font changes; app labels retain their size.
2. Check Ctrl+=, Ctrl++, and Ctrl+0. Repeat using the accessory Ctrl button and Unicode-only IME events.
3. Read raw PTY input and check that accessory Ctrl+U and external Ctrl+U both send 0x15; the intervening plain U sends 0x75.
4. Focus Chrome and use both halves of the pill and Ctrl shortcuts. Native page zoom must change, even with a page key handler that prevents default actions. Ctrl+0 restores its original zoom, without changing terminal fonts.

The floating-button smoke test also checks moving the pill without resizing text, saved positioning, and both tap targets. On a physical phone, additionally type the shortcuts using the installed IME to cover its native Android event stream.
