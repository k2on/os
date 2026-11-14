//! Values out of a plist as Apple's XML writes it: the value element right
//! after a <key>. Enough for flat lookups in a device's answers.

/// The text of the element after `<key>{key}</key>`, if it is one of the
/// given kinds (string, real, integer, data, ...).
pub fn value(plist: &str, key: &str, kinds: &[&str]) -> Option<String> {
    let tag = format!("<key>{key}</key>");
    let rest = plist[plist.find(&tag)? + tag.len()..].trim_start();
    kinds.iter().find_map(|kind| {
        let rest = rest.strip_prefix(&format!("<{kind}>"))?;
        Some(rest[..rest.find(&format!("</{kind}>"))?].trim().to_string())
    })
}

pub fn number(plist: &str, key: &str) -> Option<f64> {
    value(plist, key, &["real", "integer"])?.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    const ANSWER: &str = "<plist><dict>\n\t<key>QueryResponses</key>\n\t<dict>\n\t\t<key>BatteryLevel</key>\n\t\t<real>0.85000002384185791</real>\n\t\t<key>DeviceCapacity</key>\n\t\t<real>128</real>\n\t\t<key>OSVersion</key>\n\t\t<string>26.1</string>\n\t</dict>\n\t<key>Status</key>\n\t<string>Acknowledged</string>\n</dict></plist>";

    #[test]
    fn reads() {
        assert_eq!(number(ANSWER, "BatteryLevel"), Some(0.85000002384185791));
        assert_eq!(number(ANSWER, "DeviceCapacity"), Some(128.0));
        assert_eq!(value(ANSWER, "OSVersion", &["string"]).as_deref(), Some("26.1"));
        assert_eq!(number(ANSWER, "OSVersion"), None);
        assert_eq!(value(ANSWER, "Missing", &["string"]), None);
    }
}
