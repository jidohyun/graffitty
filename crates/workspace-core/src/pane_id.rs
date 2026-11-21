//! Pane identities are `%N`, independent of the pane's content type.

pub fn parse(key: &str) -> Option<u64> {
    let number = key.strip_prefix('%')?;
    let id = number.parse::<u64>().ok()?;
    (id.to_string() == number).then_some(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identities_are_canonical_and_zero_is_valid() {
        assert_eq!(parse("%0"), Some(0));
        assert_eq!(parse("%42"), Some(42));
        for bad in ["0", "%", "%01", "%+1", "%-1", "%1/out", "terminal:1", "chromium:1"] {
            assert_eq!(parse(bad), None, "{bad}");
        }
    }

}
