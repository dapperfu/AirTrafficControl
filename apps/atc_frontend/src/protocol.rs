//! Line-delimited JSON spoken with a tower attach port.
//!
//! The tower sends `hello`, `snapshot`, `result`, and `error` objects.
//! This client sends `snapshot` and `submit`.

use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Deserialize)]
pub struct Hello {
    pub icao: String,
    pub computers: u32,
    pub max_aircraft: u32,
    pub wind: Option<String>,
    pub runways: Vec<RunwayInfo>,
    pub neighbors: Vec<NeighborInfo>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct RunwayInfo {
    pub id: String,
    pub designation: String,
    pub independent: bool,
    pub intersects: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct NeighborInfo {
    pub icao: String,
    pub latitude: f64,
    pub longitude: f64,
    pub selected: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Picture {
    pub aircraft: Vec<Aircraft>,
    pub queues: Vec<Queue>,
    pub links: Vec<LinkState>,
    pub issued: Vec<LogEntry>,
    pub audit: Vec<LogEntry>,
    #[serde(default)]
    pub exceptions: Vec<ExceptionItem>,
    #[serde(default)]
    pub weather: Option<WeatherView>,
    #[serde(default)]
    pub vehicles: Vec<VehicleView>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ExceptionItem {
    #[serde(default)]
    pub reason: String,
    #[serde(default)]
    pub aircraft: Option<String>,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub affected: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct WeatherView {
    #[serde(default)]
    pub routine: bool,
    #[serde(default)]
    pub ceiling_ft: f64,
    #[serde(default)]
    pub visibility_sm: f64,
    #[serde(default)]
    pub atis: String,
    #[serde(default)]
    pub wind: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct VehicleView {
    pub id: String,
    #[serde(default)]
    pub runway: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Aircraft {
    pub id: String,
    pub phase: String,
    pub runway: Option<String>,
    pub intent: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Queue {
    pub runway: String,
    pub aircraft: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LinkState {
    pub icao: String,
    pub up: bool,
    pub stale: bool,
}

#[derive(Debug, Clone, Deserialize)]
pub struct LogEntry {
    pub decision: String,
    pub uid: String,
    pub aircraft: Option<String>,
    pub runway: Option<String>,
    pub command: CommandView,
    #[serde(default)]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandView {
    pub kind: String,
    pub text: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Outcome {
    pub accepted: bool,
    pub summary: String,
    #[serde(default)]
    pub reason: Option<String>,
    #[serde(default)]
    pub snapshot: Option<Picture>,
}

#[derive(Debug, Clone)]
pub enum Incoming {
    Hello(Hello),
    Snapshot(Picture),
    Result(Outcome),
    Problem(String),
}

pub fn parse_line(line: &str) -> Result<Incoming, String> {
    let value: Value =
        serde_json::from_str(line.trim()).map_err(|_| "unreadable tower message".to_string())?;
    let kind = value
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| "unreadable tower message".to_string())?;
    match kind {
        "hello" => serde_json::from_value(value)
            .map(Incoming::Hello)
            .map_err(|err| err.to_string()),
        "snapshot" => serde_json::from_value(value)
            .map(Incoming::Snapshot)
            .map_err(|err| err.to_string()),
        "result" => serde_json::from_value(value)
            .map(Incoming::Result)
            .map_err(|err| err.to_string()),
        "error" => Ok(Incoming::Problem(reason_text(&value))),
        _ => Err("unreadable tower message".to_string()),
    }
}

fn reason_text(value: &Value) -> String {
    value
        .get("reason")
        .and_then(Value::as_str)
        .unwrap_or("error")
        .to_string()
}

pub fn snapshot() -> String {
    serde_json::json!({"op": "snapshot"}).to_string()
}

pub fn assign(aircraft: &str, runway: &str, intent: &str) -> String {
    submit(serde_json::json!({
        "kind": "assign",
        "aircraft": aircraft,
        "runway": runway,
        "intent": intent,
    }))
}

pub fn hold_short(aircraft: &str) -> String {
    aircraft_command("hold_short", aircraft)
}

pub fn line_up(aircraft: &str) -> String {
    aircraft_command("line_up", aircraft)
}

pub fn takeoff(aircraft: &str) -> String {
    aircraft_command("takeoff", aircraft)
}

pub fn land(aircraft: &str) -> String {
    aircraft_command("land", aircraft)
}

pub fn go_around(aircraft: &str) -> String {
    aircraft_command("go_around", aircraft)
}

pub fn vacate(aircraft: &str) -> String {
    aircraft_command("vacate", aircraft)
}

pub fn handoff(aircraft: &str, neighbor: &str, accept: bool) -> String {
    submit(serde_json::json!({
        "kind": "handoff",
        "aircraft": aircraft,
        "neighbor": neighbor,
        "accept": accept,
    }))
}

pub fn link(neighbor: &str, up: bool) -> String {
    submit(serde_json::json!({
        "kind": "link",
        "neighbor": neighbor,
        "up": up,
    }))
}

fn aircraft_command(kind: &str, aircraft: &str) -> String {
    submit(serde_json::json!({
        "kind": kind,
        "aircraft": aircraft,
    }))
}

fn submit(command: Value) -> String {
    serde_json::json!({"op": "submit", "command": command}).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assign_uses_the_tower_field_names() {
        let value: Value = serde_json::from_str(&assign("N123AB", "27", "departure")).unwrap();
        assert_eq!(value["op"], "submit");
        assert_eq!(value["command"]["kind"], "assign");
        assert_eq!(value["command"]["aircraft"], "N123AB");
        assert_eq!(value["command"]["runway"], "27");
        assert_eq!(value["command"]["intent"], "departure");
    }

    #[test]
    fn link_encodes_a_boolean() {
        let value: Value = serde_json::from_str(&link("KNEAR", false)).unwrap();
        assert_eq!(value["command"]["up"], false);
    }

    #[test]
    fn hello_and_refusal_parse() {
        let hello = parse_line(
            r#"{"type":"hello","icao":"KEXAMPLE","computers":1,"max_aircraft":8,"wind":"270 at 10","runways":[{"id":"27","designation":"both","independent":true,"intersects":[]},{"id":"09","designation":"arrival","independent":true,"intersects":["27"]}],"neighbors":[{"icao":"KNEAR","latitude":40.1,"longitude":-75.0,"selected":true},{"icao":"KFAR","latitude":42,"longitude":-75,"selected":false}]}"#,
        )
        .unwrap();
        let Incoming::Hello(hello) = hello else {
            panic!("hello");
        };
        assert_eq!(hello.icao, "KEXAMPLE");
        assert!(!hello.neighbors[1].selected);
        assert_eq!(hello.runways[1].intersects, vec!["27".to_string()]);

        let result = parse_line(
            r#"{"type":"result","accepted":false,"summary":"line up N2","reason":"separation","snapshot":{"aircraft":[],"queues":[],"links":[],"issued":[],"audit":[]}}"#,
        )
        .unwrap();
        let Incoming::Result(outcome) = result else {
            panic!("result");
        };
        assert!(!outcome.accepted);
        assert_eq!(outcome.reason.as_deref(), Some("separation"));
        assert!(outcome.snapshot.is_some());
    }

    #[test]
    fn null_runway_is_absent() {
        let incoming = parse_line(
            r#"{"type":"snapshot","aircraft":[{"id":"N1","phase":"gone","runway":null,"intent":null}],"queues":[],"links":[{"icao":"KNEAR","up":false,"stale":true}],"issued":[],"audit":[{"decision":"issued","uid":"SRS006","aircraft":null,"runway":null,"command":{"kind":"handoff","text":"handoff N1 KNEAR accept"}}]}"#,
        )
        .unwrap();
        let Incoming::Snapshot(picture) = incoming else {
            panic!("snapshot");
        };
        assert_eq!(picture.aircraft[0].phase, "gone");
        assert!(picture.aircraft[0].runway.is_none());
        assert!(picture.audit[0].aircraft.is_none());
        assert!(picture.links[0].stale);
        assert!(picture.exceptions.is_empty());
    }

    #[test]
    fn exception_station_parses_on_the_snapshot() {
        let incoming = parse_line(
            r#"{"type":"snapshot","aircraft":[],"queues":[],"links":[],"issued":[],"audit":[],"exceptions":[{"reason":"emergency","aircraft":"N1","summary":"N1 emergency","affected":["N2"]}],"weather":{"routine":false,"ceiling_ft":200,"visibility_sm":1,"atis":"B","wind":"270 at 10"},"vehicles":[{"id":"V1","runway":"27"}]}"#,
        )
        .unwrap();
        let Incoming::Snapshot(picture) = incoming else {
            panic!("snapshot");
        };
        assert_eq!(picture.exceptions[0].reason, "emergency");
        assert_eq!(picture.exceptions[0].affected, vec!["N2".to_string()]);
        assert!(!picture.weather.unwrap().routine);
        assert_eq!(picture.vehicles[0].id, "V1");
    }
}
