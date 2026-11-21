# Parallel artwork

The Parallel node uses an ASCII rendering of a three-to-one metal manifold.
The checklist gives the actual branch count.
For usage, see [Wait for parallel work](../../agents/parallel.md).

The CLI embeds `apps/cli/assets/parallel/luminance.bin`, a 224×126 grayscale map.
`apps/cli/src/parallel_display.rs` fits it to terminal cells and animates a
moving highlight without changing progress.
