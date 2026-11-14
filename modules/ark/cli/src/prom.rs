//! Prometheus' text format, as exporters serve it: just enough to read
//! samples out of node_exporter's and comin's /metrics.
use std::collections::BTreeMap;

#[derive(Debug, PartialEq)]
pub struct Sample {
    pub name: String,
    pub labels: BTreeMap<String, String>,
    pub value: f64,
}

pub fn parse(text: &str) -> Vec<Sample> {
    text.lines().filter_map(line).collect()
}

fn line(l: &str) -> Option<Sample> {
    let l = l.trim();
    if l.is_empty() || l.starts_with('#') {
        return None;
    }
    let name_end = l.find(['{', ' '])?;
    let name = l[..name_end].to_string();
    let mut labels = BTreeMap::new();
    let mut rest = &l[name_end..];
    if let Some(r) = rest.strip_prefix('{') {
        let mut chars = r.char_indices().peekable();
        let end = loop {
            // key
            let start = chars.peek()?.0;
            let mut key_end = start;
            while let Some(&(i, c)) = chars.peek() {
                if c == '=' || c == '}' {
                    key_end = i;
                    break;
                }
                chars.next();
            }
            let (_, c) = chars.next()?;
            if c == '}' {
                break key_end + 1;
            }
            let key = r[start..key_end].trim().trim_start_matches(',').trim().to_string();
            // "value", with \\ \" \n escapes
            if chars.next()?.1 != '"' {
                return None;
            }
            let mut value = String::new();
            loop {
                let (_, c) = chars.next()?;
                match c {
                    '\\' => match chars.next()?.1 {
                        'n' => value.push('\n'),
                        other => value.push(other),
                    },
                    '"' => break,
                    c => value.push(c),
                }
            }
            labels.insert(key, value);
            match chars.peek()?.1 {
                ',' => {
                    chars.next();
                    if chars.peek()?.1 == '}' {
                        break chars.next()?.0 + 1;
                    }
                }
                '}' => break chars.next()?.0 + 1,
                _ => return None,
            }
        };
        rest = &r[end..];
    }
    let value = rest.split_whitespace().next()?.parse().ok()?;
    Some(Sample { name, labels, value })
}

/// The samples named `name`.
pub fn named<'a>(samples: &'a [Sample], name: &'a str) -> impl Iterator<Item = &'a Sample> {
    samples.iter().filter(move |s| s.name == name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_samples() {
        let s = parse(
            "# HELP x y\n# TYPE x gauge\ncomin_last_eval_failed 0\n\
             comin_deployment_info{commit_id=\"abc\",status=\"done\"} 1\n\
             ark_system_info{path=\"/nix/store/x-nixos-system\"} 1\n\
             apple_device_up{device=\"max-iphone\",owner=\"max\",} 1\n\
             odd{label=\"a \\\"b\\\" \\\\ c\"} 2.5 1700000000000\n",
        );
        assert_eq!(s.len(), 5);
        assert_eq!(s[0], Sample { name: "comin_last_eval_failed".into(), labels: BTreeMap::new(), value: 0.0 });
        assert_eq!(s[1].labels["commit_id"], "abc");
        assert_eq!(s[1].labels["status"], "done");
        assert_eq!(s[2].labels["path"], "/nix/store/x-nixos-system");
        assert_eq!(s[3].labels["owner"], "max");
        assert_eq!(s[4].labels["label"], "a \"b\" \\ c");
        assert_eq!(s[4].value, 2.5);
    }

    #[test]
    fn skips_junk() {
        assert!(parse("not a metric\nbroken{a=\"b} 1\n").is_empty());
    }
}
