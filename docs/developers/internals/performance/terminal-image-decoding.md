# Possible avoidance of double image decoding

## Current behavior

The session server currently decodes PNG images into libghostty's image store,
and each rendering client decodes them again. Original PNG bytes are retained
for delivery and reconnects, so checkpoint delivery does not re-encode them.
Decoding happens on receipt, not on every rendered frame.

## Proposed optimization

If image-heavy workloads justify it, we could fork libghostty to support an
encoded-image storage mode. The server would retain PNG bytes, dimensions, IDs,
and placement metadata; clients would decode for rendering. PNG dimensions can
be read from the header without decoding pixels. Any supported operation that
needs pixels would still require decoding on demand.

## Constraints

This would require changes to libghostty's image handling and exposed C/Rust
API: the current PNG decoder callback must return decoded RGBA pixels. It is a
possible future optimization, not an implemented feature or a current priority
for ordinary terminal use.
