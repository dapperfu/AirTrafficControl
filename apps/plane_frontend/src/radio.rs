//! Local airport frequencies and the transcript between the aircraft and the tower.
//!
//! The aircraft file names the tower, the departure facility, and the departure
//! frequency. ATIS, ground, and tower use fixed channels for this standalone radio.

use std::path::{Path, PathBuf};

use crate::config::AircraftFile;
use crate::phrase::{self, Role, Speech, Utterance};
use crate::sim::{Aircraft, Answer, Clearance, Gauges, Origin, Phase, Snapshot};

const ATIS_MHZ: f64 = 127.075;
const GROUND_MHZ: f64 = 121.900;
const TOWER_MHZ: f64 = 118.700;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Station {
    Atis,
    Ground,
    Tower,
    Departure,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpeakerKind {
    Pilot,
    Atis,
    Ground,
    Tower,
    Departure,
    Note,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Request {
    Atis,
    Pattern,
    Taxi,
    HoldShort,
    Ready,
    Landing,
    Option,
    TouchAndGo,
    StopAndGo,
    GoAround,
    Frequency,
    Position,
}

impl Request {
    fn speech(self) -> Speech {
        match self {
            Request::Atis => Speech::Atis,
            Request::Pattern => Speech::Pattern,
            Request::Taxi => Speech::Taxi,
            Request::HoldShort => Speech::HoldShort,
            Request::Ready => Speech::Ready,
            Request::Landing => Speech::Landing,
            Request::Option => Speech::Option,
            Request::TouchAndGo => Speech::TouchAndGo,
            Request::StopAndGo => Speech::StopAndGo,
            Request::GoAround => Speech::GoAround,
            Request::Frequency => Speech::Frequency,
            Request::Position => Speech::Position,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Service {
    pub mhz: f64,
    pub name: String,
    pub station: Station,
}

#[derive(Clone, Debug)]
pub struct LogLine {
    pub time_s: f64,
    pub mhz: f64,
    pub kind: SpeakerKind,
    pub speaker: String,
    pub text: String,
}

#[derive(Clone, Debug)]
pub struct View {
    pub gauges: Gauges,
    pub call_sign: String,
    pub airport: String,
    pub phase: String,
    pub detail: String,
    pub hint: String,
    pub clock_s: f64,
    pub active_mhz: f64,
    pub standby_mhz: f64,
    pub tuned_label: String,
    pub tuned_live: bool,
    pub services: Vec<Service>,
    pub lines: Vec<LogLine>,
    pub paused: bool,
    pub scale: f64,
}

pub struct Session {
    path: PathBuf,
    aircraft: Aircraft,
    services: Vec<Service>,
    lines: Vec<LogLine>,
    active_mhz: f64,
    standby_mhz: f64,
    clock: f64,
    pub paused: bool,
    pub scale: f64,
    turn_rate_deg_s: f64,
    takeoff_sent: bool,
    information: char,
}

impl Session {
    pub fn from_file(path: &Path) -> Result<Self, String> {
        let config = crate::config::load_path(path)?;
        Ok(Self::from_config(path.to_path_buf(), config))
    }

    fn from_config(path: PathBuf, config: AircraftFile) -> Self {
        let airport = config.airport.name.clone();
        let tower = config.aircraft.facility.clone();
        let departure = config.aircraft.next_facility.clone();
        let departure_mhz = must_channel(config.aircraft.next_frequency_mhz);
        let services = vec![
            Service {
                mhz: must_channel(ATIS_MHZ),
                name: format!("{airport} ATIS"),
                station: Station::Atis,
            },
            Service {
                mhz: must_channel(GROUND_MHZ),
                name: format!("{airport} Ground"),
                station: Station::Ground,
            },
            Service {
                mhz: must_channel(TOWER_MHZ),
                name: tower,
                station: Station::Tower,
            },
            Service {
                mhz: departure_mhz,
                name: departure,
                station: Station::Departure,
            },
        ];
        let active_mhz = services[0].mhz;
        let standby_mhz = services[1].mhz;
        Self {
            path,
            aircraft: Aircraft::new(config),
            services,
            lines: Vec::new(),
            active_mhz,
            standby_mhz,
            clock: 0.0,
            paused: false,
            scale: 1.0,
            turn_rate_deg_s: 0.0,
            takeoff_sent: false,
            information: 'A',
        }
    }

    pub fn reset(&mut self) -> Result<(), String> {
        let scale = self.scale;
        let paused = self.paused;
        let mut fresh = Self::from_file(&self.path)?;
        fresh.scale = scale;
        fresh.paused = paused;
        *self = fresh;
        Ok(())
    }

    pub fn advance(&mut self, real_dt: f64) {
        if self.paused {
            return;
        }
        let sim_dt = real_dt.clamp(0.0, 0.1) * self.scale;
        self.advance_sim(sim_dt);
    }

    pub fn advance_sim(&mut self, sim_dt: f64) {
        if sim_dt <= 0.0 {
            return;
        }
        let heading_before = self.aircraft.heading_deg();
        let mut left = sim_dt;
        while left > 1.0e-6 {
            let step = left.min(0.05);
            self.aircraft.step(step);
            self.clock += step;
            left -= step;
            self.maybe_takeoff();
        }
        let heading_after = self.aircraft.heading_deg();
        self.turn_rate_deg_s = shortest_turn(heading_before, heading_after) / sim_dt;
    }

    pub fn tune(&mut self, mhz: f64) {
        if let Some(mhz) = snap_channel(mhz) {
            self.active_mhz = mhz;
            self.maybe_takeoff();
        }
    }

    pub fn set_standby(&mut self, mhz: f64) {
        if let Some(mhz) = snap_channel(mhz) {
            self.standby_mhz = mhz;
        }
    }

    pub fn swap(&mut self) {
        std::mem::swap(&mut self.active_mhz, &mut self.standby_mhz);
        self.maybe_takeoff();
    }

    pub fn request(&mut self, request: Request) {
        let kind = request.speech();
        let facility = self.called_facility();
        match self.aircraft.originate(kind, &facility) {
            Origin::Unable(text) => self.say_pilot(text),
            Origin::Phrase(text) => {
                self.say_pilot(text);
                let service = self.responder(kind).cloned();
                let Some(service) = service else {
                    let note = self.suggestion(kind).unwrap_or_else(|| "No answer.".into());
                    self.say(SpeakerKind::Note, "NOTE".into(), note);
                    return;
                };
                if kind == Speech::Atis {
                    self.answer_atis(&service.name);
                    return;
                }
                let speaker = service.name.clone();
                let kind_speaker = speaker_kind(service.station);
                for clearance in clearances(kind, &self.aircraft) {
                    let phrase = clearance_phrase(&clearance);
                    let answer = self.aircraft.receive(&clearance);
                    self.say(kind_speaker, speaker.clone(), phrase);
                    self.record_answer(answer);
                }
            }
        }
    }

    pub fn phase(&self) -> Phase {
        self.aircraft.phase()
    }

    pub fn airborne(&self) -> bool {
        self.aircraft.airborne()
    }

    pub fn view(&self) -> View {
        let snap = self.aircraft.snapshot();
        View {
            gauges: snap.gauges(self.turn_rate_deg_s),
            call_sign: snap.call_sign.clone(),
            airport: snap.airport.clone(),
            phase: snap.phase.label().to_string(),
            detail: detail(&snap),
            hint: self.hint(),
            clock_s: self.clock,
            active_mhz: self.active_mhz,
            standby_mhz: self.standby_mhz,
            tuned_label: tuned_label(&self.services, self.active_mhz),
            tuned_live: self
                .services
                .iter()
                .any(|service| same_channel(service.mhz, self.active_mhz)),
            services: self.services.clone(),
            lines: self.lines.clone(),
            paused: self.paused,
            scale: self.scale,
        }
    }

    pub fn debug_state(&self) -> String {
        let snap = self.aircraft.snapshot();
        let tail: Vec<&str> = self
            .lines
            .iter()
            .rev()
            .take(12)
            .map(|line| line.text.as_str())
            .collect();
        let mut tail = tail;
        tail.reverse();
        format!(
            "{}  gs {:.0}  alt {:.0}  hdg {:.0}  {}  | {}",
            snap.phase.label(),
            snap.airspeed_kt,
            snap.altitude_ft,
            snap.heading_deg,
            snap.position,
            tail.join(" || ")
        )
    }

    fn answer_atis(&mut self, speaker: &str) {
        let mut advisory = Clearance::new(Speech::Information);
        advisory.atis_letter = Some(self.information);
        let phrase = phrase::render(&Utterance {
            role: Role::Advisory,
            kind: Speech::Information,
            facility: "",
            call_sign: "",
            position: None,
            runway_id: None,
            sequence: None,
            atis_letter: Some(self.information),
            frequency_mhz: None,
            next_facility: None,
            hold_short: false,
            pattern_side: None,
        });
        self.say(SpeakerKind::Atis, speaker.to_string(), phrase);
        let answer = self.aircraft.receive(&advisory);
        self.record_answer(answer);
    }

    fn maybe_takeoff(&mut self) {
        if self.takeoff_sent || self.aircraft.phase() != Phase::LineUp || !self.aircraft.lined_up()
        {
            return;
        }
        let Some(service) = self
            .services
            .iter()
            .find(|service| {
                same_channel(service.mhz, self.active_mhz) && service.station == Station::Tower
            })
            .cloned()
        else {
            return;
        };
        self.takeoff_sent = true;
        let mut clearance = Clearance::new(Speech::Takeoff);
        clearance.runway_id = Some(self.aircraft.runway_id().to_string());
        let phrase = clearance_phrase(&clearance);
        self.say(SpeakerKind::Tower, service.name, phrase);
        let answer = self.aircraft.receive(&clearance);
        self.record_answer(answer);
    }

    fn record_answer(&mut self, answer: Answer) {
        match answer {
            Answer::Readback(text) | Answer::Unable(text) => self.say_pilot(text),
            Answer::Quiet => {}
        }
    }

    fn say_pilot(&mut self, text: String) {
        let speaker = self.aircraft.call_sign().to_string();
        self.say(SpeakerKind::Pilot, speaker, text);
    }

    fn say(&mut self, kind: SpeakerKind, speaker: String, text: String) {
        self.lines.push(LogLine {
            time_s: self.clock,
            mhz: self.active_mhz,
            kind,
            speaker,
            text,
        });
        if self.lines.len() > 400 {
            let extra = self.lines.len() - 400;
            self.lines.drain(0..extra);
        }
    }

    fn called_facility(&self) -> String {
        self.services
            .iter()
            .find(|service| same_channel(service.mhz, self.active_mhz))
            .map(|service| service.name.clone())
            .unwrap_or_else(|| self.aircraft.facility().to_string())
    }

    fn responder(&self, kind: Speech) -> Option<&Service> {
        self.services.iter().find(|service| {
            same_channel(service.mhz, self.active_mhz) && homes(kind).contains(&service.station)
        })
    }

    fn suggestion(&self, kind: Speech) -> Option<String> {
        let service = self
            .services
            .iter()
            .find(|service| homes(kind).contains(&service.station))?;
        Some(format!(
            "No answer. {} answers {:.3}.",
            service.name, service.mhz
        ))
    }

    fn hint(&self) -> String {
        let atis = self.freq(Station::Atis);
        let ground = self.freq(Station::Ground);
        let tower = self.freq(Station::Tower);
        let departure = self
            .services
            .iter()
            .find(|service| service.station == Station::Departure);
        let departure_text = departure
            .map(|service| format!("{} {:.3}", service.name, service.mhz))
            .unwrap_or_else(|| "departure".into());
        match self.aircraft.phase() {
            Phase::Ramp => {
                format!("Request ATIS on {atis}, then taxi on ground {ground}.")
            }
            Phase::Taxi => "Taxiing to the hold-short line.".into(),
            Phase::HoldShort => {
                format!("Tune tower {tower} and call takeoff. That sends the ready call.")
            }
            Phase::LineUp => {
                format!("Line up and wait. The tower clears takeoff on {tower}.")
            }
            Phase::TakeoffRoll => "Takeoff roll.".into(),
            Phase::Climb | Phase::Crosswind | Phase::Downwind | Phase::Base | Phase::Final => {
                if self.aircraft.snapshot().landing_mode.is_none() {
                    format!("Airborne. Request the landing on tower {tower}.")
                } else {
                    "The arrival is set. The gauges follow the pattern.".into()
                }
            }
            Phase::GoAround => "Going around toward the upwind leg.".into(),
            Phase::Rollout => "Rolling out.".into(),
            Phase::Stopped => {
                format!("Stopped. Request the frequency change, then tune {departure_text}.")
            }
        }
    }

    fn freq(&self, station: Station) -> String {
        self.services
            .iter()
            .find(|service| service.station == station)
            .map(|service| format!("{:.3}", service.mhz))
            .unwrap_or_else(|| "--".into())
    }
}

pub fn snap_channel(mhz: f64) -> Option<f64> {
    if !mhz.is_finite() || !(118.0..=136.975).contains(&mhz) {
        return None;
    }
    let steps = ((mhz - 118.0) / 0.025).round();
    let snapped = 118.0 + steps * 0.025;
    let snapped = (snapped * 1000.0).round() / 1000.0;
    if (118.0..=136.975).contains(&snapped) {
        Some(snapped)
    } else {
        None
    }
}

pub fn parse_frequency_input(text: &str) -> Option<f64> {
    let text = text.trim().trim_end_matches('.').trim();
    let text = text
        .strip_suffix("mhz")
        .or_else(|| text.strip_suffix("MHz"))
        .unwrap_or(text)
        .trim();
    let mhz: f64 = text.parse().ok()?;
    snap_channel(mhz)
}

pub fn parse_request(text: &str) -> Option<Request> {
    let mut text = normalize_words(text);
    if let Some(rest) = text.strip_prefix("request ") {
        text = rest.to_string();
    }
    if starts_any(&text, &["atis"]) {
        return Some(Request::Atis);
    }
    if starts_any(&text, &["taxi"]) {
        return Some(Request::Taxi);
    }
    if starts_any(&text, &["hold short", "holding short"]) {
        return Some(Request::HoldShort);
    }
    if starts_any(
        &text,
        &[
            "takeoff",
            "take off",
            "ready",
            "ready for takeoff",
            "ready for take off",
            "cleared for takeoff",
        ],
    ) {
        return Some(Request::Ready);
    }
    if starts_any(&text, &["land", "landing", "cleared to land"]) {
        return Some(Request::Landing);
    }
    if starts_any(&text, &["touch and go", "touch-and-go"]) {
        return Some(Request::TouchAndGo);
    }
    if starts_any(&text, &["stop and go", "stop-and-go"]) {
        return Some(Request::StopAndGo);
    }
    if starts_any(&text, &["option", "the option"]) {
        return Some(Request::Option);
    }
    if starts_any(&text, &["go around", "going around"]) {
        return Some(Request::GoAround);
    }
    if starts_any(
        &text,
        &[
            "frequency",
            "frequency change",
            "departure",
            "contact departure",
        ],
    ) {
        return Some(Request::Frequency);
    }
    if starts_any(&text, &["position", "report position"]) {
        return Some(Request::Position);
    }
    if starts_any(&text, &["pattern", "enter pattern", "enter the pattern"]) {
        return Some(Request::Pattern);
    }
    None
}

pub fn format_clock(seconds: f64) -> String {
    if !seconds.is_finite() || seconds < 0.0 {
        return "00:00.0".into();
    }
    let minutes = (seconds / 60.0).floor() as u64;
    let remain = seconds - minutes as f64 * 60.0;
    let secs = remain.floor() as u64;
    let tenths = ((remain - secs as f64) * 10.0).floor() as u64;
    format!("{minutes:02}:{secs:02}.{tenths}")
}

pub fn same_channel(left: f64, right: f64) -> bool {
    (left - right).abs() < 0.0005
}

fn must_channel(mhz: f64) -> f64 {
    snap_channel(mhz).unwrap_or(mhz)
}

fn homes(kind: Speech) -> Vec<Station> {
    match kind {
        Speech::Atis => vec![Station::Atis],
        Speech::Taxi => vec![Station::Ground],
        Speech::HoldShort => vec![Station::Ground, Station::Tower],
        Speech::Position => vec![Station::Tower, Station::Departure],
        _ => vec![Station::Tower],
    }
}

fn speaker_kind(station: Station) -> SpeakerKind {
    match station {
        Station::Atis => SpeakerKind::Atis,
        Station::Ground => SpeakerKind::Ground,
        Station::Tower => SpeakerKind::Tower,
        Station::Departure => SpeakerKind::Departure,
    }
}

fn clearances(kind: Speech, aircraft: &Aircraft) -> Vec<Clearance> {
    let runway = aircraft.runway_id().to_string();
    match kind {
        Speech::Pattern => {
            let mut runway_clearance = Clearance::new(Speech::Runway);
            runway_clearance.runway_id = Some(runway.clone());
            let mut sequence = Clearance::new(Speech::Sequence);
            sequence.sequence = Some(1);
            sequence.runway_id = Some(runway);
            vec![runway_clearance, sequence]
        }
        Speech::Taxi => {
            let mut clearance = Clearance::new(Speech::Taxi);
            clearance.runway_id = Some(runway);
            clearance.hold_short = true;
            vec![clearance]
        }
        Speech::Ready => {
            let mut clearance = Clearance::new(Speech::LineUp);
            clearance.runway_id = Some(runway);
            vec![clearance]
        }
        Speech::Landing => vec![runway_clearance(Speech::Landing, runway)],
        Speech::Option => vec![runway_clearance(Speech::Option, runway)],
        Speech::TouchAndGo => vec![runway_clearance(Speech::TouchAndGo, runway)],
        Speech::StopAndGo => vec![runway_clearance(Speech::StopAndGo, runway)],
        Speech::Frequency => {
            let mut clearance = Clearance::new(Speech::Frequency);
            clearance.next_facility = Some(aircraft.next_facility().to_string());
            clearance.frequency_mhz = Some(aircraft.next_frequency_mhz());
            vec![clearance]
        }
        Speech::HoldShort | Speech::Position | Speech::GoAround | Speech::Atis => Vec::new(),
        _ => Vec::new(),
    }
}

fn runway_clearance(kind: Speech, runway: String) -> Clearance {
    let mut clearance = Clearance::new(kind);
    clearance.runway_id = Some(runway);
    clearance
}

fn clearance_phrase(clearance: &Clearance) -> String {
    let runway = clearance.runway_id.clone().unwrap_or_default();
    let next_facility = clearance.next_facility.clone();
    phrase::render(&Utterance {
        role: Role::Clearance,
        kind: clearance.kind,
        facility: "",
        call_sign: "",
        position: None,
        runway_id: if runway.is_empty() {
            None
        } else {
            Some(runway.as_str())
        },
        sequence: clearance.sequence,
        atis_letter: clearance.atis_letter,
        frequency_mhz: clearance.frequency_mhz,
        next_facility: next_facility.as_deref(),
        hold_short: clearance.hold_short,
        pattern_side: None,
    })
}

fn tuned_label(services: &[Service], mhz: f64) -> String {
    let names: Vec<&str> = services
        .iter()
        .filter(|service| same_channel(service.mhz, mhz))
        .map(|service| service.name.as_str())
        .collect();
    if names.is_empty() {
        "No station".into()
    } else {
        names.join(" / ")
    }
}

fn detail(snap: &Snapshot) -> String {
    let mut parts = vec![snap.position.clone()];
    if let Some(letter) = snap.atis_letter {
        parts.push(format!("ATIS {letter}"));
    }
    if let Some(sequence) = snap.sequence {
        parts.push(format!("number {sequence}"));
    }
    if let Some(mode) = &snap.landing_mode {
        parts.push(mode.replace('_', " "));
    }
    if snap.lined_up {
        parts.push("lined up".into());
    }
    parts.push(format!("facility {}", snap.facility));
    parts.join("   ")
}

fn shortest_turn(from: f64, to: f64) -> f64 {
    (to - from + 540.0).rem_euclid(360.0) - 180.0
}

fn normalize_words(text: &str) -> String {
    text.trim()
        .trim_end_matches('.')
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn starts_any(text: &str, prefixes: &[&str]) -> bool {
    prefixes
        .iter()
        .any(|prefix| text == *prefix || text.starts_with(&format!("{prefix} ")))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn example() -> Session {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config/n123ab.toml");
        Session::from_file(&path).expect("example session")
    }

    fn transcript(session: &Session) -> String {
        session
            .lines
            .iter()
            .map(|line| line.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    #[test]
    fn parses_requests_and_channels() {
        assert_eq!(parse_request("takeoff"), Some(Request::Ready));
        assert_eq!(parse_request("Land runway 27"), Some(Request::Landing));
        assert_eq!(parse_request("go around"), Some(Request::GoAround));
        assert!(parse_request("say the weather").is_none());
        assert!(same_channel(snap_channel(118.7).unwrap(), 118.700));
        assert!(same_channel(
            parse_frequency_input("124.5 mhz").unwrap(),
            124.5
        ));
        assert!(parse_frequency_input("100.0").is_none());
    }

    #[test]
    fn taxi_on_the_tower_frequency_is_unanswered() {
        let mut session = example();
        session.tune(118.7);
        session.request(Request::Taxi);
        assert_eq!(session.phase(), Phase::Ramp);
        let text = transcript(&session);
        assert!(text.contains("request taxi"));
        assert!(text.contains("No answer"));
        assert!(text.contains("121.900"));
    }

    #[test]
    fn full_pattern_transcript_ends_stopped() {
        let mut session = example();
        session.request(Request::Atis);
        session.tune(121.9);
        session.request(Request::Taxi);
        let mut guard = 0;
        while session.phase() != Phase::HoldShort && guard < 180 {
            session.advance_sim(1.0);
            guard += 1;
        }
        assert_eq!(
            session.phase(),
            Phase::HoldShort,
            "{}",
            session.debug_state()
        );
        session.tune(118.7);
        session.request(Request::Ready);
        guard = 0;
        while !session.airborne() && guard < 180 {
            session.advance_sim(1.0);
            guard += 1;
        }
        assert!(session.airborne(), "{}", session.debug_state());
        session.request(Request::Landing);
        guard = 0;
        while session.phase() != Phase::Stopped && guard < 600 {
            session.advance_sim(1.0);
            guard += 1;
        }
        assert_eq!(session.phase(), Phase::Stopped, "{}", session.debug_state());
        let text = transcript(&session);
        for phrase in [
            "request ATIS.",
            "Information alpha.",
            "request taxi to runway two seven.",
            "Taxi to runway two seven, hold short runway two seven.",
            "ready for takeoff.",
            "line up and wait.",
            "cleared for takeoff.",
            "request landing runway two seven.",
            "cleared to land.",
        ] {
            assert!(text.contains(phrase), "missing {phrase}\n{text}");
        }
    }
}
