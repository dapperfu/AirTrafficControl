//! Load one aircraft TOML file. An invalid file does not produce an aircraft.

use std::fs;
use std::path::Path;

use toml::Value;

const TOP: &[&str] = &[
    "aircraft",
    "performance",
    "airport",
    "runway",
    "ramp",
    "option",
];
const AIRCRAFT_KEYS: &[&str] = &[
    "n_number",
    "facility",
    "next_facility",
    "next_frequency_mhz",
];
const PERFORMANCE_KEYS: &[&str] = &[
    "taxi_speed_kt",
    "rotation_speed_kt",
    "pattern_speed_kt",
    "pattern_altitude_ft",
    "takeoff_distance_ft",
    "landing_distance_ft",
    "turn_rate_deg_s",
    "accel_kt_s",
    "vertical_speed_fpm",
    "low_approach_ft",
];
const AIRPORT_KEYS: &[&str] = &["name", "elevation_ft"];
const RUNWAY_KEYS: &[&str] = &[
    "id",
    "heading_deg",
    "length_ft",
    "pattern",
    "hold_short_ft",
    "pattern_offset_ft",
    "upwind_ft",
];
const RAMP_KEYS: &[&str] = &["north_ft", "east_ft"];
const OPTION_KEYS: &[&str] = &["choice"];
const CHOICES: &[&str] = &["full_stop", "touch_and_go", "stop_and_go", "low_approach"];

#[derive(Clone, Debug)]
pub struct AircraftFile {
    pub aircraft: Identity,
    pub performance: Performance,
    pub airport: Airport,
    pub runway: Runway,
    pub ramp: Ramp,
    pub option: Choice,
}

#[derive(Clone, Debug)]
pub struct Identity {
    pub n_number: String,
    pub facility: String,
    pub next_facility: String,
    pub next_frequency_mhz: f64,
}

#[derive(Clone, Debug)]
pub struct Performance {
    pub taxi_speed_kt: f64,
    pub rotation_speed_kt: f64,
    pub pattern_speed_kt: f64,
    pub pattern_altitude_ft: f64,
    pub takeoff_distance_ft: f64,
    pub landing_distance_ft: f64,
    pub turn_rate_deg_s: f64,
    pub accel_kt_s: f64,
    pub vertical_speed_fpm: f64,
    pub low_approach_ft: f64,
}

#[derive(Clone, Debug)]
pub struct Airport {
    pub name: String,
    pub elevation_ft: f64,
}

#[derive(Clone, Debug)]
pub struct Runway {
    pub id: String,
    pub heading_deg: i64,
    pub length_ft: f64,
    pub pattern: String,
    pub hold_short_ft: f64,
    pub pattern_offset_ft: f64,
    pub upwind_ft: f64,
}

#[derive(Clone, Debug)]
pub struct Ramp {
    pub north_ft: f64,
    pub east_ft: f64,
}

#[derive(Clone, Debug)]
pub struct Choice {
    pub choice: String,
}

pub fn load_path(path: &Path) -> Result<AircraftFile, String> {
    let text = fs::read_to_string(path)
        .map_err(|error| format!("could not read {}: {error}", path.display()))?;
    load_str(&text)
}

pub fn load_str(text: &str) -> Result<AircraftFile, String> {
    let root: Value = text
        .parse()
        .map_err(|error| format!("aircraft TOML could not be parsed: {error}"))?;
    let table = root
        .as_table()
        .ok_or_else(|| "aircraft TOML must contain exactly the six required tables".to_string())?;
    if !exact_keys(table, TOP) {
        return Err("aircraft TOML must contain exactly the six required tables".into());
    }
    let aircraft = required_table(table, "aircraft", AIRCRAFT_KEYS)?;
    let performance = required_table(table, "performance", PERFORMANCE_KEYS)?;
    let airport = required_table(table, "airport", AIRPORT_KEYS)?;
    let runway = required_table(table, "runway", RUNWAY_KEYS)?;
    let ramp = required_table(table, "ramp", RAMP_KEYS)?;
    let option = required_table(table, "option", OPTION_KEYS)?;

    let identity = identity(aircraft)?;
    let performance = performance_table(performance)?;
    let airport = Airport {
        name: text_value(airport, "name")?,
        elevation_ft: number(airport, "elevation_ft")?,
    };
    let runway = runway_table(runway)?;
    let ramp = Ramp {
        north_ft: number(ramp, "north_ft")?,
        east_ft: number(ramp, "east_ft")?,
    };
    let choice = text_value(option, "choice")?;
    if !CHOICES.contains(&choice.as_str()) {
        return Err("option.choice is outside the closed set".into());
    }
    if runway.upwind_ft <= runway.length_ft {
        return Err("upwind_ft must pass the departure end".into());
    }
    if performance.low_approach_ft >= performance.pattern_altitude_ft {
        return Err("low_approach_ft must be below pattern altitude".into());
    }
    Ok(AircraftFile {
        aircraft: identity,
        performance,
        airport,
        runway,
        ramp,
        option: Choice { choice },
    })
}

fn identity(table: &toml::map::Map<String, Value>) -> Result<Identity, String> {
    let n_number = text_value(table, "n_number")?;
    if !valid_n_number(&n_number) {
        return Err(format!("invalid N-number: {n_number}"));
    }
    let facility = text_value(table, "facility")?;
    let next_facility = text_value(table, "next_facility")?;
    if facility.contains(',') || next_facility.contains(',') {
        return Err("facility names must not contain a comma".into());
    }
    let frequency = number(table, "next_frequency_mhz")?;
    if !(118.0..=136.975).contains(&frequency) {
        return Err("next_frequency_mhz is outside 118.000 to 136.975".into());
    }
    Ok(Identity {
        n_number,
        facility,
        next_facility,
        next_frequency_mhz: frequency,
    })
}

fn performance_table(table: &toml::map::Map<String, Value>) -> Result<Performance, String> {
    let performance = Performance {
        taxi_speed_kt: positive(table, "taxi_speed_kt")?,
        rotation_speed_kt: positive(table, "rotation_speed_kt")?,
        pattern_speed_kt: positive(table, "pattern_speed_kt")?,
        pattern_altitude_ft: positive(table, "pattern_altitude_ft")?,
        takeoff_distance_ft: positive(table, "takeoff_distance_ft")?,
        landing_distance_ft: positive(table, "landing_distance_ft")?,
        turn_rate_deg_s: positive(table, "turn_rate_deg_s")?,
        accel_kt_s: positive(table, "accel_kt_s")?,
        vertical_speed_fpm: positive(table, "vertical_speed_fpm")?,
        low_approach_ft: positive(table, "low_approach_ft")?,
    };
    if !(performance.taxi_speed_kt < performance.rotation_speed_kt
        && performance.rotation_speed_kt < performance.pattern_speed_kt)
    {
        return Err("speeds must increase from taxi to rotation to pattern".into());
    }
    Ok(performance)
}

fn runway_table(table: &toml::map::Map<String, Value>) -> Result<Runway, String> {
    let id = text_value(table, "id")?;
    if !valid_runway_id(&id) {
        return Err("runway id must be 01 through 36 with an optional L, C, or R".into());
    }
    let heading_deg = match table.get("heading_deg") {
        Some(Value::Integer(value)) if (0..360).contains(value) => *value,
        _ => return Err("heading_deg must be an integer from 0 through 359".into()),
    };
    let pattern = text_value(table, "pattern")?;
    if pattern != "left" && pattern != "right" {
        return Err("pattern must be left or right".into());
    }
    Ok(Runway {
        id,
        heading_deg,
        length_ft: positive(table, "length_ft")?,
        pattern,
        hold_short_ft: positive(table, "hold_short_ft")?,
        pattern_offset_ft: positive(table, "pattern_offset_ft")?,
        upwind_ft: positive(table, "upwind_ft")?,
    })
}

fn required_table<'a>(
    root: &'a toml::map::Map<String, Value>,
    name: &str,
    keys: &[&str],
) -> Result<&'a toml::map::Map<String, Value>, String> {
    let value = root
        .get(name)
        .ok_or_else(|| format!("{name} table is missing"))?;
    let table = value
        .as_table()
        .ok_or_else(|| format!("{name} must be a table"))?;
    if !exact_keys(table, keys) {
        return Err(format!("{name} must contain exactly its required keys"));
    }
    Ok(table)
}

fn exact_keys(table: &toml::map::Map<String, Value>, keys: &[&str]) -> bool {
    table.len() == keys.len() && keys.iter().all(|key| table.contains_key(*key))
}

fn text_value(table: &toml::map::Map<String, Value>, key: &str) -> Result<String, String> {
    match table.get(key) {
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(value.trim().to_string()),
        _ => Err(format!("{key} must be a non-empty string")),
    }
}

fn number(table: &toml::map::Map<String, Value>, key: &str) -> Result<f64, String> {
    match table.get(key) {
        Some(Value::Integer(value)) => Ok(*value as f64),
        Some(Value::Float(value)) if value.is_finite() => Ok(*value),
        _ => Err(format!("{key} must be a number")),
    }
}

fn positive(table: &toml::map::Map<String, Value>, key: &str) -> Result<f64, String> {
    let value = number(table, key)?;
    if value <= 0.0 {
        return Err(format!("{key} must be greater than zero"));
    }
    Ok(value)
}

fn valid_runway_id(id: &str) -> bool {
    let bytes = id.as_bytes();
    if bytes.len() != 2 && bytes.len() != 3 {
        return false;
    }
    if !bytes[0].is_ascii_digit() || !bytes[1].is_ascii_digit() {
        return false;
    }
    let number = (bytes[0] - b'0') * 10 + (bytes[1] - b'0');
    if !(1..=36).contains(&number) {
        return false;
    }
    bytes.len() == 2 || matches!(bytes[2], b'L' | b'C' | b'R')
}

fn valid_n_number(n_number: &str) -> bool {
    let bytes = n_number.as_bytes();
    if bytes.len() < 2 || bytes.len() > 6 || bytes[0] != b'N' {
        return false;
    }
    let rest = &bytes[1..];
    if rest[0] == b'0' || !rest[0].is_ascii_digit() {
        return false;
    }
    if !rest
        .iter()
        .all(|byte| byte.is_ascii_digit() || is_reg_letter(*byte))
    {
        return false;
    }
    let Some(letter_start) = rest.iter().position(|byte| byte.is_ascii_alphabetic()) else {
        return (1..=5).contains(&rest.len());
    };
    if !rest[..letter_start]
        .iter()
        .all(|byte| byte.is_ascii_digit())
        || !rest[letter_start..].iter().all(|byte| is_reg_letter(*byte))
    {
        return false;
    }
    let digits = letter_start;
    let letters = rest.len() - letter_start;
    match letters {
        1 => (1..=4).contains(&digits),
        2 => (1..=3).contains(&digits),
        _ => false,
    }
}

fn is_reg_letter(byte: u8) -> bool {
    matches!(byte, b'A'..=b'H' | b'J'..=b'N' | b'P'..=b'Z')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn example_text() -> String {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config/n123ab.toml");
        fs::read_to_string(path).expect("example aircraft file")
    }

    #[test]
    fn loads_the_example_aircraft() {
        let file = load_str(&example_text()).expect("example");
        assert_eq!(file.aircraft.n_number, "N123AB");
        assert_eq!(file.runway.id, "27");
        assert_eq!(file.option.choice, "full_stop");
        assert!((file.aircraft.next_frequency_mhz - 124.5).abs() < 0.001);
    }

    #[test]
    fn rejects_an_extra_table_and_a_bad_registration() {
        let text = example_text();
        assert!(load_str(&format!("{text}\n[extra]\nname = \"no\"\n")).is_err());
        assert!(load_str(&text.replace("N123AB", "N0123")).is_err());
    }
}
