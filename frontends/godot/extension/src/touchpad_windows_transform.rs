// Direct Manipulation transforms are uniform scale followed by translation.
// All three points (content pivot and viewport translations) use native pixels.
pub(super) fn pinch_travel(
    previous: (f32, f32, f32),
    current: (f32, f32, f32),
    pivot: (f32, f32),
) -> (f32, f32) {
    let scale_change = current.0 - previous.0;
    (
        scale_change.mul_add(pivot.0, current.1 - previous.1),
        scale_change.mul_add(pivot.1, current.2 - previous.2),
    )
}

#[cfg(test)]
mod tests {
    use super::pinch_travel;

    #[test]
    fn off_center_pinch_then_slide_and_reverse() {
        let pivot = (300.0, 100.0);
        let start = (1.0, 0.0, 0.0);
        let zoom = (1.5, -150.0, -50.0);
        let slide = (1.5, -130.0, -60.0);
        let reverse = (1.0, 25.0, -18.0);
        assert_eq!(pinch_travel(start, zoom, pivot), (0.0, 0.0));
        assert_eq!(pinch_travel(zoom, slide, pivot), (20.0, -10.0));
        assert_eq!(pinch_travel(slide, reverse, pivot), (5.0, -8.0));
    }
}
