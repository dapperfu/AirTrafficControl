//! Closed pattern phrases for the standalone cockpit.
//!
//! The wording matches the aircraft package: requests put the facility and
//! call sign first, and readbacks put the call sign last.

pub const DIGITS: [&str; 10] = [
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "niner",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Speech {
    Atis,
    Pattern,
    Taxi,
    HoldShort,
    Ready,
    LineUp,
    Takeoff,
    Landing,
    GoAround,
    Sequence,
    Runway,
    Frequency,
    Position,
    Option,
    TouchAndGo,
    StopAndGo,
    Unable,
    Information,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Request,
    Report,
    Readback,
    Clearance,
    Advisory,
}

pub struct Utterance<'a> {
    pub role: Role,
    pub kind: Speech,
    pub facility: &'a str,
    pub call_sign: &'a str,
    pub position: Option<&'a str>,
    pub runway_id: Option<&'a str>,
    pub sequence: Option<i32>,
    pub atis_letter: Option<char>,
    pub frequency_mhz: Option<f64>,
    pub next_facility: Option<&'a str>,
    pub hold_short: bool,
    pub pattern_side: Option<&'a str>,
}

pub fn spoken_call_sign(n_number: &str) -> String {
    let mut chars = n_number.chars();
    if chars.next() != Some('N') {
        return n_number.to_string();
    }
    let mut words = vec!["November".to_string()];
    for ch in chars {
        if let Some(digit) = ch.to_digit(10) {
            words.push(DIGITS[digit as usize].to_string());
        } else if ch.is_ascii_alphabetic() {
            words.push(phonetic(ch).to_string());
        } else {
            return n_number.to_string();
        }
    }
    words.join(" ")
}

pub fn speak_runway(runway_id: &str) -> String {
    let mut chars = runway_id.chars();
    let Some(tens) = chars.next().and_then(|ch| ch.to_digit(10)) else {
        return runway_id.to_string();
    };
    let Some(ones) = chars.next().and_then(|ch| ch.to_digit(10)) else {
        return runway_id.to_string();
    };
    let mut text = format!("{} {}", DIGITS[tens as usize], DIGITS[ones as usize]);
    if let Some(suffix) = chars.next() {
        let side = match suffix {
            'L' => "left",
            'R' => "right",
            'C' => "center",
            _ => return runway_id.to_string(),
        };
        if chars.next().is_some() {
            return runway_id.to_string();
        }
        text = format!("{text} {side}");
    }
    text
}

pub fn speak_frequency(mhz: f64) -> String {
    let mut text = format!("{mhz:.3}");
    while text.contains('.') && (text.ends_with('0') || text.ends_with('.')) {
        text.pop();
    }
    let (whole, fraction) = match text.split_once('.') {
        Some((whole, fraction)) => (whole.to_string(), Some(fraction.to_string())),
        None => (text, None),
    };
    let mut words = digit_words(&whole);
    if let Some(fraction) = fraction {
        words.push("point".to_string());
        words.extend(digit_words(&fraction));
    }
    words.join(" ")
}

pub fn speak_altitude(feet: f64) -> String {
    let rounded = (feet / 100.0).round() as i32 * 100;
    if rounded <= 0 {
        return "zero".into();
    }
    let thousands = rounded / 1000;
    let hundreds = (rounded % 1000) / 100;
    let mut parts = Vec::new();
    if thousands > 0 {
        parts.push(format!("{} thousand", small(thousands)));
    }
    if hundreds > 0 {
        parts.push(format!("{} hundred", DIGITS[hundreds as usize]));
    }
    parts.join(" ")
}

pub fn speak_distance(north_ft: f64, east_ft: f64) -> String {
    const NM_FT: f64 = 6076.12;
    let feet = north_ft.hypot(east_ft);
    if feet < 100.0 {
        return "at the field".into();
    }
    let rounded = (feet / NM_FT).round() as i32;
    if rounded <= 0 {
        return "less than one mile".into();
    }
    if rounded == 1 {
        return "one mile".into();
    }
    format!("{} miles", digit_words(&rounded.to_string()).join(" "))
}

pub fn compass(north_ft: f64, east_ft: f64) -> &'static str {
    const NAMES: [&str; 8] = [
        "north",
        "northeast",
        "east",
        "southeast",
        "south",
        "southwest",
        "west",
        "northwest",
    ];
    let degrees = east_ft.atan2(north_ft).to_degrees().rem_euclid(360.0);
    NAMES[((degrees + 22.5) / 45.0) as usize % 8]
}

pub fn describe_position(
    phase: &str,
    north_ft: f64,
    east_ft: f64,
    altitude_ft: f64,
    runway_id: &str,
    pattern: &str,
) -> String {
    let runway = speak_runway(runway_id);
    match phase {
        "ramp" => "at the ramp".into(),
        "taxi" => format!("taxiing to runway {runway}"),
        "hold_short" => format!("holding short runway {runway}"),
        "line_up" => format!("line up and wait runway {runway}"),
        "takeoff_roll" | "rollout" => format!("on runway {runway}"),
        "stopped" => format!("stopped on runway {runway}"),
        _ => {
            let altitude = speak_altitude(altitude_ft);
            if let Some(leg) = pattern_leg(phase, pattern, &runway, &altitude) {
                return leg;
            }
            let place = speak_distance(north_ft, east_ft);
            if place == "at the field" {
                format!("at the field at {altitude}")
            } else {
                format!("{place} {} at {altitude}", compass(north_ft, east_ft))
            }
        }
    }
}

pub fn render(tx: &Utterance<'_>) -> String {
    if tx.role == Role::Readback && tx.kind == Speech::Unable {
        return normalize(&format!(
            "Unable {}, {}",
            tx.position.unwrap_or(""),
            tx.call_sign
        ));
    }
    if tx.role == Role::Readback {
        return normalize(&format!("{}, {}", operative(tx), tx.call_sign));
    }
    if tx.kind == Speech::Position {
        return normalize(&format!(
            "{}, {}, {}",
            tx.facility,
            tx.call_sign,
            tx.position.unwrap_or("")
        ));
    }
    if matches!(tx.role, Role::Request | Role::Report) {
        let message = request_message(tx);
        if let Some(position) = tx.position.filter(|position| !position.is_empty()) {
            return normalize(&format!(
                "{}, {}, {position}, {message}",
                tx.facility, tx.call_sign
            ));
        }
        return normalize(&format!("{}, {}, {message}", tx.facility, tx.call_sign));
    }
    if tx.role == Role::Advisory && tx.kind == Speech::Information {
        return normalize(&format!(
            "Information {}",
            phonetic(tx.atis_letter.unwrap_or('A'))
        ));
    }
    if tx.role == Role::Clearance {
        return normalize(&clearance_sentence(tx));
    }
    normalize("Unable to render")
}

pub fn unable_reason(kind: Speech, runway_id: Option<&str>, sequence: Option<i32>) -> String {
    let runway = runway_id.map(speak_runway).unwrap_or_default();
    match kind {
        Speech::Taxi => format!("taxi to runway {runway}"),
        Speech::HoldShort => format!("hold short runway {runway}"),
        Speech::LineUp => format!("line up and wait runway {runway}"),
        Speech::Takeoff => format!("cleared for takeoff runway {runway}"),
        Speech::Landing => format!("cleared to land runway {runway}"),
        Speech::Option => format!("cleared for the option runway {runway}"),
        Speech::TouchAndGo => format!("touch and go runway {runway}"),
        Speech::StopAndGo => format!("stop and go runway {runway}"),
        Speech::GoAround => "go around".into(),
        Speech::Frequency => "frequency change".into(),
        Speech::Sequence => format!("number {}", sequence_words(sequence.unwrap_or(0))),
        Speech::Runway => format!("runway {runway}"),
        _ => "that clearance".into(),
    }
}

pub fn phonetic(letter: char) -> &'static str {
    match letter.to_ascii_uppercase() {
        'A' => "alpha",
        'B' => "bravo",
        'C' => "charlie",
        'D' => "delta",
        'E' => "echo",
        'F' => "foxtrot",
        'G' => "golf",
        'H' => "hotel",
        'I' => "india",
        'J' => "juliett",
        'K' => "kilo",
        'L' => "lima",
        'M' => "mike",
        'N' => "november",
        'O' => "oscar",
        'P' => "papa",
        'Q' => "quebec",
        'R' => "romeo",
        'S' => "sierra",
        'T' => "tango",
        'U' => "uniform",
        'V' => "victor",
        'W' => "whiskey",
        'X' => "x-ray",
        'Y' => "yankee",
        'Z' => "zulu",
        _ => "alpha",
    }
}

fn request_message(tx: &Utterance<'_>) -> String {
    let runway = tx.runway_id.map(speak_runway).unwrap_or_default();
    match tx.kind {
        Speech::Atis => "request ATIS".into(),
        Speech::Taxi => format!("request taxi to runway {runway}"),
        Speech::Ready => format!("holding short runway {runway}, ready for takeoff"),
        Speech::HoldShort => format!("holding short runway {runway}"),
        Speech::GoAround => "going around".into(),
        Speech::Frequency => "request frequency change".into(),
        Speech::Option => format!("request the option runway {runway}"),
        Speech::TouchAndGo => format!("request touch and go runway {runway}"),
        Speech::StopAndGo => format!("request stop and go runway {runway}"),
        Speech::Landing => format!("request landing runway {runway}"),
        Speech::Pattern => {
            let lead = tx
                .atis_letter
                .map(|letter| format!("with information {}, ", phonetic(letter)))
                .unwrap_or_default();
            format!(
                "{lead}request {} traffic runway {runway}",
                tx.pattern_side.unwrap_or("left")
            )
        }
        Speech::Position => tx.position.unwrap_or("").into(),
        _ => "request".into(),
    }
}

fn operative(tx: &Utterance<'_>) -> String {
    let runway = tx.runway_id.map(speak_runway).unwrap_or_default();
    match tx.kind {
        Speech::Taxi if tx.hold_short => {
            format!("Taxi to runway {runway}, hold short runway {runway}")
        }
        Speech::Taxi => format!("Taxi to runway {runway}"),
        Speech::HoldShort => format!("Hold short runway {runway}"),
        Speech::LineUp => format!("Line up and wait runway {runway}"),
        Speech::Takeoff => format!("Cleared for takeoff runway {runway}"),
        Speech::Landing => format!("Cleared to land runway {runway}"),
        Speech::Option => format!("Cleared for the option runway {runway}"),
        Speech::TouchAndGo => format!("Cleared touch and go runway {runway}"),
        Speech::StopAndGo => format!("Cleared stop and go runway {runway}"),
        Speech::GoAround => "Going around".into(),
        Speech::Runway => format!("Runway {runway}"),
        Speech::Sequence => sequence_clause(tx.sequence.unwrap_or(0), tx.runway_id),
        Speech::Frequency => tx
            .frequency_mhz
            .map(speak_frequency)
            .unwrap_or_else(|| "frequency".into()),
        _ => "clearance".into(),
    }
}

fn clearance_sentence(tx: &Utterance<'_>) -> String {
    let runway = tx.runway_id.map(speak_runway).unwrap_or_default();
    match tx.kind {
        Speech::Taxi if tx.hold_short => {
            format!("Taxi to runway {runway}, hold short runway {runway}")
        }
        Speech::Taxi => format!("Taxi to runway {runway}"),
        Speech::HoldShort => format!("Hold short runway {runway}"),
        Speech::LineUp => format!("Runway {runway}, line up and wait"),
        Speech::Takeoff => format!("Runway {runway}, cleared for takeoff"),
        Speech::Landing => format!("Runway {runway}, cleared to land"),
        Speech::Option => format!("Cleared for the option runway {runway}"),
        Speech::TouchAndGo => format!("Cleared touch and go runway {runway}"),
        Speech::StopAndGo => format!("Cleared stop and go runway {runway}"),
        Speech::GoAround => "Go around".into(),
        Speech::Runway => format!("Runway {runway}"),
        Speech::Sequence => sequence_clause(tx.sequence.unwrap_or(0), tx.runway_id),
        Speech::Frequency => match (tx.next_facility, tx.frequency_mhz) {
            (Some(facility), Some(mhz)) => {
                format!("Contact {facility} on {}", speak_frequency(mhz))
            }
            _ => "Contact the next facility".into(),
        },
        _ => "Clearance".into(),
    }
}

fn sequence_clause(sequence: i32, runway_id: Option<&str>) -> String {
    let number = format!("Number {}", sequence_words(sequence));
    match runway_id {
        Some(runway) => format!("{number}, runway {}", speak_runway(runway)),
        None => number,
    }
}

fn sequence_words(sequence: i32) -> String {
    digit_words(&sequence.max(0).to_string()).join(" ")
}

fn digit_words(text: &str) -> Vec<String> {
    text.chars()
        .filter_map(|ch| {
            ch.to_digit(10)
                .map(|digit| DIGITS[digit as usize].to_string())
        })
        .collect()
}

fn small(value: i32) -> String {
    if (0..10).contains(&value) {
        return DIGITS[value as usize].to_string();
    }
    digit_words(&value.to_string()).join(" ")
}

fn pattern_leg(phase: &str, pattern: &str, runway: &str, altitude: &str) -> Option<String> {
    match phase {
        "climb" | "go_around" => Some(format!("upwind runway {runway} at {altitude}")),
        "crosswind" => Some(format!("{pattern} crosswind runway {runway} at {altitude}")),
        "downwind" => Some(format!("{pattern} downwind runway {runway} at {altitude}")),
        "base" => Some(format!("{pattern} base runway {runway} at {altitude}")),
        "final" => Some(format!("final runway {runway} at {altitude}")),
        _ => None,
    }
}

fn normalize(text: &str) -> String {
    let phrase = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if phrase.is_empty() {
        return ".".into();
    }
    if phrase.ends_with('.') {
        phrase
    } else {
        format!("{phrase}.")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CALL: &str = "November one two three alpha bravo";

    fn utterance<'a>(
        role: Role,
        kind: Speech,
        facility: &'a str,
        call_sign: &'a str,
    ) -> Utterance<'a> {
        Utterance {
            role,
            kind,
            facility,
            call_sign,
            position: None,
            runway_id: None,
            sequence: None,
            atis_letter: None,
            frequency_mhz: None,
            next_facility: None,
            hold_short: false,
            pattern_side: None,
        }
    }

    #[test]
    fn speaks_the_example_call_sign_runway_and_frequency() {
        assert_eq!(spoken_call_sign("N123AB"), CALL);
        assert_eq!(speak_runway("27"), "two seven");
        assert_eq!(speak_runway("09"), "zero niner");
        assert_eq!(speak_runway("27L"), "two seven left");
        assert_eq!(speak_frequency(124.5), "one two four point five");
        assert_eq!(speak_altitude(1000.0), "one thousand");
        assert_eq!(speak_altitude(1500.0), "one thousand five hundred");
    }

    #[test]
    fn request_and_readback_order_matches_the_aircraft_phrase_set() {
        let atis = utterance(Role::Request, Speech::Atis, "Example Tower", CALL);
        assert_eq!(
            render(&atis),
            "Example Tower, November one two three alpha bravo, request ATIS."
        );

        let mut pattern = utterance(Role::Request, Speech::Pattern, "Example Tower", CALL);
        pattern.position = Some("at the ramp");
        pattern.runway_id = Some("27");
        pattern.pattern_side = Some("left");
        pattern.atis_letter = Some('A');
        assert_eq!(
            render(&pattern),
            "Example Tower, November one two three alpha bravo, at the ramp, with information alpha, request left traffic runway two seven."
        );

        let mut takeoff = utterance(Role::Readback, Speech::Takeoff, "", CALL);
        takeoff.runway_id = Some("27");
        assert_eq!(
            render(&takeoff),
            "Cleared for takeoff runway two seven, November one two three alpha bravo."
        );

        let mut line_up = utterance(Role::Clearance, Speech::LineUp, "", "");
        line_up.runway_id = Some("27");
        assert_eq!(render(&line_up), "Runway two seven, line up and wait.");
    }
}
