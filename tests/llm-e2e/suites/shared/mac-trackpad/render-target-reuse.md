# Mac navigation rendering

In both Flat and Flat 2D, show coloured terminal cells and pinch while moving
both fingers until the pane is partly off-screen. Cells must remain at their
projected positions without squeezing as cropping changes. The moving zoom
anchor must remain stable. Lift both fingers: text should regain its settled
resolution without moving or resizing the terminal grid.

The replay counts workspace and terminal viewport size changes during 30 continuous pinch
updates after the first sample establishes the bounded navigation crop. Both
counts must be zero. It samples visible rendered cell pixels outside docked
panels (at least five samples per world), checks the
anchor and PTY dimensions, then verifies the target updates after input settles.
