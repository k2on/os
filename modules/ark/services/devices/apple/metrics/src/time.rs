//! RFC 3339-ish timestamps to Unix seconds, as Apple, Go and openssl write
//! them: `2026-11-13T09:09:20.315396-06:00`, `2027-11-13T13:43:06-0600`,
//! `2027-11-12 13:27:00Z`.

pub fn parse(s: &str) -> Option<i64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() < 19 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b' ') || b[13] != b':' || b[16] != b':' {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let (y, mo, d, h, mi, se) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    let mut rest = &s[19..];
    if let Some(r) = rest.strip_prefix('.') {
        rest = r.trim_start_matches(|c: char| c.is_ascii_digit());
    }
    let offset = match rest {
        "" | "Z" | "z" => 0,
        _ => {
            let sign = match rest.as_bytes()[0] {
                b'+' => 1,
                b'-' => -1,
                _ => return None,
            };
            let digits: String = rest[1..].chars().filter(|c| *c != ':').collect();
            if digits.len() != 4 {
                return None;
            }
            sign * (digits[..2].parse::<i64>().ok()? * 3600 + digits[2..].parse::<i64>().ok()? * 60)
        }
    };
    Some(days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + se - offset)
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn formats() {
        assert_eq!(parse("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse("2026-11-13T09:09:20.315396-06:00"), Some(1794582560));
        assert_eq!(parse("2026-11-13T15:09:20Z"), Some(1794582560));
        assert_eq!(parse("2027-11-13T13:43:06-0600"), parse("2027-11-13T19:43:06Z"));
        assert_eq!(parse("2027-11-12 13:27:00Z"), parse("2027-11-12T13:27:00+00:00"));
        assert_eq!(parse("2000-02-29T00:00:00Z"), Some(951782400));
    }

    #[test]
    fn junk() {
        assert_eq!(parse("Nov 12 13:27:00 2027 GMT"), None);
        assert_eq!(parse("2027-11-12T13:27:00+6"), None);
    }
}
