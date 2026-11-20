//! Point-mass pattern for one configured aircraft.
//!
//! Motion changes only inside `step`. Requests and clearances update the plan.

use crate::config::AircraftFile;
use crate::phrase::{self, Role, Speech, Utterance};

const KNOT_FT_S: f64 = 6076.12 / 3600.0;
const CAPTURE_FT: f64 = 250.0;
const LINEUP_FT: f64 = 100.0;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Ramp,
    Taxi,
    HoldShort,
    LineUp,
    TakeoffRoll,
    Climb,
    Crosswind,
    Downwind,
    Base,
    Final,
    Rollout,
    Stopped,
    GoAround,
}

impl Phase {
    pub fn key(self) -> &'static str {
        match self {
            Phase::Ramp => "ramp",
            Phase::Taxi => "taxi",
            Phase::HoldShort => "hold_short",
            Phase::LineUp => "line_up",
            Phase::TakeoffRoll => "takeoff_roll",
            Phase::Climb => "climb",
            Phase::Crosswind => "crosswind",
            Phase::Downwind => "downwind",
            Phase::Base => "base",
            Phase::Final => "final",
            Phase::Rollout => "rollout",
            Phase::Stopped => "stopped",
            Phase::GoAround => "go_around",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Phase::Ramp => "RAMP",
            Phase::Taxi => "TAXI",
            Phase::HoldShort => "HOLD SHORT",
            Phase::LineUp => "LINE UP",
            Phase::TakeoffRoll => "TAKEOFF ROLL",
            Phase::Climb => "UPWIND",
            Phase::Crosswind => "CROSSWIND",
            Phase::Downwind => "DOWNWIND",
            Phase::Base => "BASE",
            Phase::Final => "FINAL",
            Phase::Rollout => "ROLLOUT",
            Phase::Stopped => "STOPPED",
            Phase::GoAround => "GO AROUND",
        }
    }

    fn airborne(self) -> bool {
        matches!(
            self,
            Phase::Climb
                | Phase::Crosswind
                | Phase::Downwind
                | Phase::Base
                | Phase::Final
                | Phase::GoAround
        )
    }
}

#[derive(Clone, Debug)]
pub struct Gauges {
    pub airspeed_kt: f64,
    pub taxi_kt: f64,
    pub rotation_kt: f64,
    pub pattern_kt: f64,
    pub altitude_ft: f64,
    pub heading_deg: f64,
    pub runway_heading_deg: f64,
    pub vertical_fpm: f64,
    pub vertical_limit_fpm: f64,
    pub pitch_deg: f64,
    pub bank_deg: f64,
    pub turn_rate_deg_s: f64,
}

#[derive(Clone, Debug)]
pub struct Snapshot {
    pub call_sign: String,
    pub airport: String,
    pub facility: String,
    pub phase: Phase,
    pub position: String,
    pub atis_letter: Option<char>,
    pub sequence: Option<i32>,
    pub landing_mode: Option<String>,
    pub lined_up: bool,
    pub airspeed_kt: f64,
    pub altitude_ft: f64,
    pub heading_deg: f64,
    pub vertical_fpm: f64,
    pub runway_id: String,
    pub runway_heading_deg: f64,
    pub taxi_kt: f64,
    pub rotation_kt: f64,
    pub pattern_kt: f64,
    pub vertical_limit_fpm: f64,
}

impl Snapshot {
    pub fn gauges(&self, turn_rate_deg_s: f64) -> Gauges {
        Gauges {
            airspeed_kt: self.airspeed_kt,
            taxi_kt: self.taxi_kt,
            rotation_kt: self.rotation_kt,
            pattern_kt: self.pattern_kt,
            altitude_ft: self.altitude_ft,
            heading_deg: self.heading_deg,
            runway_heading_deg: self.runway_heading_deg,
            vertical_fpm: self.vertical_fpm,
            vertical_limit_fpm: self.vertical_limit_fpm,
            pitch_deg: pitch_from_vertical(self.vertical_fpm, self.airspeed_kt),
            bank_deg: bank_from_turn(turn_rate_deg_s, self.airspeed_kt),
            turn_rate_deg_s,
        }
    }
}

#[derive(Clone, Debug)]
pub struct Clearance {
    pub kind: Speech,
    pub runway_id: Option<String>,
    pub sequence: Option<i32>,
    pub hold_short: bool,
    pub next_facility: Option<String>,
    pub frequency_mhz: Option<f64>,
    pub atis_letter: Option<char>,
}

impl Clearance {
    pub fn new(kind: Speech) -> Self {
        Self {
            kind,
            runway_id: None,
            sequence: None,
            hold_short: false,
            next_facility: None,
            frequency_mhz: None,
            atis_letter: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Origin {
    Phrase(String),
    Unable(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Answer {
    Readback(String),
    Unable(String),
    Quiet,
}

#[derive(Clone, Debug)]
struct Kinematics {
    north_ft: f64,
    east_ft: f64,
    altitude_ft: f64,
    heading_deg: f64,
    ground_speed_kt: f64,
    vertical_speed_fpm: f64,
}

#[derive(Clone, Debug)]
struct PointMass {
    state: Kinematics,
    turn_rate_deg_s: f64,
    accel_kt_s: f64,
    max_vertical_speed_fpm: f64,
    target_heading_deg: f64,
    target_speed_kt: f64,
    target_altitude_ft: f64,
    waypoint: Option<(f64, f64)>,
}

impl PointMass {
    fn step(&mut self, dt: f64) {
        if dt <= 0.0 {
            return;
        }
        self.turn(dt);
        self.accelerate(dt);
        self.climb(dt);
        self.translate(dt);
    }

    fn turn(&mut self, dt: f64) {
        let mut delta = shortest_delta(self.state.heading_deg, self.desired_heading());
        let limit = self.turn_rate_deg_s * dt;
        delta = delta.clamp(-limit, limit);
        self.state.heading_deg = wrap360(self.state.heading_deg + delta);
    }

    fn desired_heading(&self) -> f64 {
        let Some((north, east)) = self.waypoint else {
            return self.target_heading_deg;
        };
        let north_delta = north - self.state.north_ft;
        let east_delta = east - self.state.east_ft;
        if north_delta.hypot(east_delta) < 1.0 {
            return self.target_heading_deg;
        }
        east_delta.atan2(north_delta).to_degrees().rem_euclid(360.0)
    }

    fn accelerate(&mut self, dt: f64) {
        let mut delta = self.target_speed_kt - self.state.ground_speed_kt;
        let limit = self.accel_kt_s * dt;
        delta = delta.clamp(-limit, limit);
        self.state.ground_speed_kt = (self.state.ground_speed_kt + delta).max(0.0);
    }

    fn climb(&mut self, dt: f64) {
        let error = self.target_altitude_ft - self.state.altitude_ft;
        let needed =
            (error / dt * 60.0).clamp(-self.max_vertical_speed_fpm, self.max_vertical_speed_fpm);
        self.state.vertical_speed_fpm = needed;
        self.state.altitude_ft += needed / 60.0 * dt;
    }

    fn translate(&mut self, dt: f64) {
        let heading = self.state.heading_deg.to_radians();
        let feet = self.state.ground_speed_kt * KNOT_FT_S * dt;
        self.state.north_ft += feet * heading.cos();
        self.state.east_ft += feet * heading.sin();
    }
}

pub struct Aircraft {
    config: AircraftFile,
    spoken: String,
    phase: Phase,
    atis_letter: Option<char>,
    sequence: Option<i32>,
    landing_mode: Option<String>,
    lined_up: bool,
    facility: String,
    dynamics: PointMass,
}

impl Aircraft {
    pub fn new(config: AircraftFile) -> Self {
        let spoken = phrase::spoken_call_sign(&config.aircraft.n_number);
        let facility = config.aircraft.facility.clone();
        let elevation = config.airport.elevation_ft;
        let heading = config.runway.heading_deg as f64;
        let dynamics = PointMass {
            state: Kinematics {
                north_ft: config.ramp.north_ft,
                east_ft: config.ramp.east_ft,
                altitude_ft: elevation,
                heading_deg: heading,
                ground_speed_kt: 0.0,
                vertical_speed_fpm: 0.0,
            },
            turn_rate_deg_s: config.performance.turn_rate_deg_s,
            accel_kt_s: config.performance.accel_kt_s,
            max_vertical_speed_fpm: config.performance.vertical_speed_fpm,
            target_heading_deg: heading,
            target_speed_kt: 0.0,
            target_altitude_ft: elevation,
            waypoint: None,
        };
        Self {
            config,
            spoken,
            phase: Phase::Ramp,
            atis_letter: None,
            sequence: None,
            landing_mode: None,
            lined_up: false,
            facility,
            dynamics,
        }
    }

    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn lined_up(&self) -> bool {
        self.lined_up
    }

    pub fn call_sign(&self) -> &str {
        &self.config.aircraft.n_number
    }

    pub fn facility(&self) -> &str {
        &self.facility
    }

    pub fn runway_id(&self) -> &str {
        &self.config.runway.id
    }

    pub fn next_facility(&self) -> &str {
        &self.config.aircraft.next_facility
    }

    pub fn next_frequency_mhz(&self) -> f64 {
        self.config.aircraft.next_frequency_mhz
    }

    pub fn airborne(&self) -> bool {
        self.phase.airborne()
    }

    pub fn snapshot(&self) -> Snapshot {
        let state = &self.dynamics.state;
        Snapshot {
            call_sign: self.config.aircraft.n_number.clone(),
            airport: self.config.airport.name.clone(),
            facility: self.facility.clone(),
            phase: self.phase,
            position: self.position_text(),
            atis_letter: self.atis_letter,
            sequence: self.sequence,
            landing_mode: self.landing_mode.clone(),
            lined_up: self.lined_up,
            airspeed_kt: state.ground_speed_kt,
            altitude_ft: state.altitude_ft,
            heading_deg: state.heading_deg,
            vertical_fpm: state.vertical_speed_fpm,
            runway_id: self.config.runway.id.clone(),
            runway_heading_deg: self.config.runway.heading_deg as f64,
            taxi_kt: self.config.performance.taxi_speed_kt,
            rotation_kt: self.config.performance.rotation_speed_kt,
            pattern_kt: self.config.performance.pattern_speed_kt,
            vertical_limit_fpm: self.config.performance.vertical_speed_fpm,
        }
    }

    pub fn originate(&mut self, kind: Speech, facility: &str) -> Origin {
        if kind == Speech::GoAround {
            if !self.airborne() {
                let mut clearance = Clearance::new(Speech::GoAround);
                clearance.runway_id = Some(self.config.runway.id.clone());
                return Origin::Unable(self.unable_phrase(&clearance));
            }
            self.begin_go_around();
        }
        Origin::Phrase(self.request_phrase(kind, facility))
    }

    pub fn receive(&mut self, clearance: &Clearance) -> Answer {
        if clearance.kind == Speech::Information {
            if let Some(letter) = clearance.atis_letter {
                self.atis_letter = Some(letter);
            }
            return Answer::Quiet;
        }
        if let Some(runway) = clearance.runway_id.as_deref() {
            if runway != self.config.runway.id {
                return Answer::Quiet;
            }
        }
        if self.outside_performance(clearance) || !self.phase_allows(clearance) {
            return Answer::Unable(self.unable_phrase(clearance));
        }
        self.accept(clearance);
        Answer::Readback(self.readback_phrase(clearance))
    }

    pub fn step(&mut self, dt: f64) {
        if dt <= 0.0 {
            return;
        }
        self.apply_targets();
        self.dynamics.step(dt);
        self.capture();
    }

    pub fn heading_deg(&self) -> f64 {
        self.dynamics.state.heading_deg
    }

    fn position_text(&self) -> String {
        let state = &self.dynamics.state;
        phrase::describe_position(
            self.phase.key(),
            state.north_ft,
            state.east_ft,
            state.altitude_ft,
            &self.config.runway.id,
            &self.config.runway.pattern,
        )
    }

    fn request_phrase(&self, kind: Speech, facility: &str) -> String {
        let position_text = self.position_text();
        let runway = self.config.runway.id.clone();
        let pattern = self.config.runway.pattern.clone();
        let position = match kind {
            Speech::Pattern | Speech::Landing | Speech::Position => Some(position_text.as_str()),
            _ => None,
        };
        let runway_id = match kind {
            Speech::Atis | Speech::GoAround | Speech::Frequency | Speech::Position => None,
            _ => Some(runway.as_str()),
        };
        phrase::render(&Utterance {
            role: if matches!(kind, Speech::HoldShort | Speech::Position) {
                Role::Report
            } else {
                Role::Request
            },
            kind,
            facility,
            call_sign: &self.spoken,
            position,
            runway_id,
            sequence: None,
            atis_letter: if kind == Speech::Pattern {
                self.atis_letter
            } else {
                None
            },
            frequency_mhz: None,
            next_facility: None,
            hold_short: false,
            pattern_side: if kind == Speech::Pattern {
                Some(pattern.as_str())
            } else {
                None
            },
        })
    }

    fn readback_phrase(&self, clearance: &Clearance) -> String {
        let runway = clearance
            .runway_id
            .clone()
            .unwrap_or_else(|| self.config.runway.id.clone());
        let next_facility = clearance.next_facility.clone();
        let frequency = clearance
            .frequency_mhz
            .unwrap_or(self.config.aircraft.next_frequency_mhz);
        phrase::render(&Utterance {
            role: Role::Readback,
            kind: clearance.kind,
            facility: "",
            call_sign: &self.spoken,
            position: None,
            runway_id: match clearance.kind {
                Speech::GoAround | Speech::Frequency => None,
                _ => Some(runway.as_str()),
            },
            sequence: clearance.sequence,
            atis_letter: None,
            frequency_mhz: if clearance.kind == Speech::Frequency {
                Some(frequency)
            } else {
                None
            },
            next_facility: next_facility.as_deref(),
            hold_short: clearance.hold_short || clearance.kind == Speech::HoldShort,
            pattern_side: None,
        })
    }

    fn unable_phrase(&self, clearance: &Clearance) -> String {
        let runway = clearance
            .runway_id
            .as_deref()
            .unwrap_or(self.config.runway.id.as_str());
        let reason = phrase::unable_reason(clearance.kind, Some(runway), clearance.sequence);
        phrase::render(&Utterance {
            role: Role::Readback,
            kind: Speech::Unable,
            facility: "",
            call_sign: &self.spoken,
            position: Some(&reason),
            runway_id: None,
            sequence: None,
            atis_letter: None,
            frequency_mhz: None,
            next_facility: None,
            hold_short: false,
            pattern_side: None,
        })
    }

    fn accept(&mut self, clearance: &Clearance) {
        match clearance.kind {
            Speech::Taxi => {
                self.phase = Phase::Taxi;
                self.lined_up = false;
            }
            Speech::HoldShort => {
                self.lined_up = false;
                let hold = self.point(-self.config.runway.hold_short_ft, 0.0);
                self.phase = if self.close_to(hold) {
                    Phase::HoldShort
                } else {
                    Phase::Taxi
                };
            }
            Speech::LineUp => {
                self.phase = Phase::LineUp;
                self.lined_up = false;
            }
            Speech::Takeoff => {
                self.phase = Phase::TakeoffRoll;
                self.lined_up = false;
                self.landing_mode = None;
            }
            Speech::Landing => {
                self.landing_mode = Some("full_stop".into());
            }
            Speech::Runway => {}
            Speech::GoAround => self.begin_go_around(),
            Speech::Sequence => self.sequence = clearance.sequence,
            Speech::Frequency => {
                self.facility = clearance
                    .next_facility
                    .clone()
                    .unwrap_or_else(|| self.config.aircraft.next_facility.clone());
            }
            Speech::Option | Speech::TouchAndGo | Speech::StopAndGo => {
                self.landing_mode = Some(self.mode_for(clearance.kind));
            }
            _ => {}
        }
    }

    fn begin_go_around(&mut self) {
        self.phase = Phase::GoAround;
        self.landing_mode = None;
        self.dynamics.waypoint = None;
        self.dynamics.target_heading_deg = self.config.runway.heading_deg as f64;
        self.dynamics.target_altitude_ft = self.pattern_msl();
        self.dynamics.target_speed_kt = self.config.performance.pattern_speed_kt;
    }

    fn mode_for(&self, kind: Speech) -> String {
        match kind {
            Speech::TouchAndGo => "touch_and_go".into(),
            Speech::StopAndGo => "stop_and_go".into(),
            _ => self.config.option.choice.clone(),
        }
    }

    fn outside_performance(&self, clearance: &Clearance) -> bool {
        let length = self.config.runway.length_ft;
        if clearance.kind == Speech::Takeoff && length < self.config.performance.takeoff_distance_ft
        {
            return true;
        }
        matches!(
            clearance.kind,
            Speech::Landing | Speech::Option | Speech::TouchAndGo | Speech::StopAndGo
        ) && length < self.config.performance.landing_distance_ft
    }

    fn phase_allows(&self, clearance: &Clearance) -> bool {
        match clearance.kind {
            Speech::Sequence | Speech::Runway | Speech::Frequency | Speech::Information => true,
            Speech::Taxi => matches!(self.phase, Phase::Ramp | Phase::Taxi),
            Speech::HoldShort => {
                matches!(self.phase, Phase::Taxi | Phase::HoldShort | Phase::LineUp)
            }
            Speech::LineUp => self.phase == Phase::HoldShort,
            Speech::Takeoff => self.phase == Phase::LineUp && self.lined_up,
            Speech::Landing
            | Speech::Option
            | Speech::TouchAndGo
            | Speech::StopAndGo
            | Speech::GoAround => self.airborne(),
            _ => false,
        }
    }

    fn apply_targets(&mut self) {
        let heading = self.config.runway.heading_deg as f64;
        let elevation = self.config.airport.elevation_ft;
        let performance = &self.config.performance;
        self.dynamics.target_heading_deg = heading;
        self.dynamics.target_altitude_ft = elevation;
        self.dynamics.waypoint = None;
        match self.phase {
            Phase::Ramp | Phase::HoldShort | Phase::Stopped => {
                self.dynamics.target_speed_kt = 0.0;
            }
            Phase::Taxi => {
                self.dynamics.target_speed_kt = performance.taxi_speed_kt;
                let hold = self.point(-self.config.runway.hold_short_ft, 0.0);
                self.dynamics.waypoint = Some(hold);
            }
            Phase::LineUp => {
                self.dynamics.target_speed_kt = if self.lined_up {
                    0.0
                } else {
                    performance.taxi_speed_kt
                };
                self.dynamics.waypoint = if self.lined_up {
                    None
                } else {
                    Some(self.point(LINEUP_FT, 0.0))
                };
            }
            Phase::TakeoffRoll => {
                self.dynamics.target_speed_kt = performance.pattern_speed_kt;
            }
            Phase::Climb | Phase::GoAround => {
                self.dynamics.target_speed_kt = performance.pattern_speed_kt;
                self.dynamics.target_altitude_ft = self.pattern_msl();
            }
            Phase::Crosswind => {
                self.dynamics.target_speed_kt = performance.pattern_speed_kt;
                self.dynamics.target_altitude_ft = self.pattern_msl();
                let corner = self.point(
                    self.config.runway.upwind_ft,
                    self.config.runway.pattern_offset_ft,
                );
                self.dynamics.waypoint = Some(corner);
            }
            Phase::Downwind => {
                self.dynamics.target_speed_kt = performance.pattern_speed_kt;
                self.dynamics.target_altitude_ft = self.pattern_msl();
                let offset = self.config.runway.pattern_offset_ft;
                let along = if self.landing_mode.is_some() {
                    -offset
                } else {
                    self.along() - 2000.0
                };
                self.dynamics.waypoint = Some(self.point(along, offset));
            }
            Phase::Base => {
                self.dynamics.target_speed_kt = performance.pattern_speed_kt;
                self.dynamics.target_altitude_ft = self.pattern_msl();
                let intercept = self.point(-self.config.runway.pattern_offset_ft, 0.0);
                self.dynamics.waypoint = Some(intercept);
            }
            Phase::Final => {
                self.dynamics.target_speed_kt = performance.pattern_speed_kt;
                self.dynamics.target_altitude_ft = self.final_altitude();
                let aim = self.point(self.config.runway.length_ft, 0.0);
                self.dynamics.waypoint = Some(aim);
            }
            Phase::Rollout => {
                self.dynamics.target_speed_kt = 0.0;
            }
        }
    }

    fn capture(&mut self) {
        let hold = self.point(-self.config.runway.hold_short_ft, 0.0);
        if self.phase == Phase::Taxi && self.close_to(hold) {
            self.snap(hold, Some(0.0));
            self.phase = Phase::HoldShort;
            return;
        }
        let lineup = self.point(LINEUP_FT, 0.0);
        if self.phase == Phase::LineUp && !self.lined_up && self.close_to(lineup) {
            self.snap(lineup, Some(0.0));
            self.dynamics.state.heading_deg = self.config.runway.heading_deg as f64;
            self.lined_up = true;
            return;
        }
        if self.phase == Phase::TakeoffRoll
            && self.dynamics.state.ground_speed_kt >= self.config.performance.rotation_speed_kt
        {
            self.phase = Phase::Climb;
            return;
        }
        if matches!(self.phase, Phase::Climb | Phase::GoAround)
            && self.at_pattern_altitude()
            && self.along() >= self.config.runway.upwind_ft
        {
            self.phase = Phase::Crosswind;
            return;
        }
        let crosswind = self.point(
            self.config.runway.upwind_ft,
            self.config.runway.pattern_offset_ft,
        );
        if self.phase == Phase::Crosswind && self.close_to(crosswind) {
            self.snap(crosswind, None);
            self.phase = Phase::Downwind;
            return;
        }
        let downwind_end = self.point(
            -self.config.runway.pattern_offset_ft,
            self.config.runway.pattern_offset_ft,
        );
        if self.phase == Phase::Downwind
            && self.landing_mode.is_some()
            && self.close_to(downwind_end)
        {
            self.snap(downwind_end, None);
            self.phase = Phase::Base;
            return;
        }
        if self.phase == Phase::Downwind
            && self.landing_mode.is_some()
            && self.along() <= -self.config.runway.pattern_offset_ft
        {
            self.phase = Phase::Base;
            return;
        }
        let intercept = self.point(-self.config.runway.pattern_offset_ft, 0.0);
        if self.phase == Phase::Base && self.close_to(intercept) {
            self.snap(intercept, None);
            self.phase = Phase::Final;
            return;
        }
        if self.phase == Phase::Final && self.along() >= 0.0 {
            if self.landing_mode.as_deref() == Some("low_approach") {
                self.phase = Phase::GoAround;
                return;
            }
            if self.landing_mode.is_some()
                && self.dynamics.state.altitude_ft <= self.config.airport.elevation_ft + 40.0
            {
                if self.landing_mode.as_deref() == Some("touch_and_go") {
                    self.phase = Phase::TakeoffRoll;
                } else {
                    self.phase = Phase::Rollout;
                }
                return;
            }
        }
        if self.phase == Phase::Rollout && self.dynamics.state.ground_speed_kt <= 0.5 {
            self.dynamics.state.ground_speed_kt = 0.0;
            if self.landing_mode.as_deref() == Some("stop_and_go") {
                self.phase = Phase::TakeoffRoll;
                self.landing_mode = None;
            } else {
                self.phase = Phase::Stopped;
            }
        }
    }

    fn final_altitude(&self) -> f64 {
        let elevation = self.config.airport.elevation_ft;
        if self.landing_mode.as_deref() == Some("low_approach") {
            return elevation + self.config.performance.low_approach_ft;
        }
        let offset = self.config.runway.pattern_offset_ft;
        let along = self.along();
        if along <= -offset {
            return self.pattern_msl();
        }
        if along >= 0.0 {
            return elevation;
        }
        let fraction = (along + offset) / offset;
        self.pattern_msl() + (elevation - self.pattern_msl()) * fraction
    }

    fn pattern_msl(&self) -> f64 {
        self.config.airport.elevation_ft + self.config.performance.pattern_altitude_ft
    }

    fn at_pattern_altitude(&self) -> bool {
        (self.dynamics.state.altitude_ft - self.pattern_msl()).abs() <= 30.0
    }

    fn along(&self) -> f64 {
        let (north, east) = unit(self.config.runway.heading_deg as f64);
        self.dynamics.state.north_ft * north + self.dynamics.state.east_ft * east
    }

    fn point(&self, along: f64, side: f64) -> (f64, f64) {
        let (north, east) = unit(self.config.runway.heading_deg as f64);
        let (side_north, side_east) = self.side_unit();
        (
            north * along + side_north * side,
            east * along + side_east * side,
        )
    }

    fn side_unit(&self) -> (f64, f64) {
        let turn = if self.config.runway.pattern == "left" {
            -90.0
        } else {
            90.0
        };
        unit(self.config.runway.heading_deg as f64 + turn)
    }

    fn close_to(&self, point: (f64, f64)) -> bool {
        let north = self.dynamics.state.north_ft - point.0;
        let east = self.dynamics.state.east_ft - point.1;
        north.hypot(east) <= CAPTURE_FT
    }

    fn snap(&mut self, point: (f64, f64), speed: Option<f64>) {
        self.dynamics.state.north_ft = point.0;
        self.dynamics.state.east_ft = point.1;
        self.dynamics.waypoint = None;
        if let Some(speed) = speed {
            self.dynamics.state.ground_speed_kt = speed;
        }
    }
}

fn unit(heading_deg: f64) -> (f64, f64) {
    let heading = heading_deg.to_radians();
    (heading.cos(), heading.sin())
}

fn wrap360(degrees: f64) -> f64 {
    degrees.rem_euclid(360.0)
}

fn shortest_delta(from: f64, to: f64) -> f64 {
    (to - from + 540.0).rem_euclid(360.0) - 180.0
}

fn pitch_from_vertical(vertical_fpm: f64, speed_kt: f64) -> f64 {
    if speed_kt < 1.0 {
        return 0.0;
    }
    let speed_fps = speed_kt * KNOT_FT_S;
    let vertical_fps = vertical_fpm / 60.0;
    (vertical_fps / speed_fps)
        .atan()
        .to_degrees()
        .clamp(-30.0, 30.0)
}

fn bank_from_turn(turn_rate_deg_s: f64, speed_kt: f64) -> f64 {
    if speed_kt < 1.0 || turn_rate_deg_s.abs() < 0.05 {
        return 0.0;
    }
    let speed_fps = speed_kt * KNOT_FT_S;
    let omega = turn_rate_deg_s.to_radians();
    (speed_fps * omega / 32.174)
        .atan()
        .to_degrees()
        .clamp(-60.0, 60.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::load_path;
    use std::path::Path;

    fn example() -> Aircraft {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../config/n123ab.toml");
        Aircraft::new(load_path(&path).expect("example aircraft"))
    }

    #[test]
    fn taxi_clearance_reaches_hold_short_and_reads_back() {
        let mut aircraft = example();
        let Origin::Phrase(request) = aircraft.originate(Speech::Taxi, "Example Ground") else {
            panic!("taxi request should be spoken");
        };
        assert_eq!(
            request,
            "Example Ground, November one two three alpha bravo, request taxi to runway two seven."
        );
        let mut clearance = Clearance::new(Speech::Taxi);
        clearance.runway_id = Some("27".into());
        clearance.hold_short = true;
        match aircraft.receive(&clearance) {
            Answer::Readback(text) => assert_eq!(
                text,
                "Taxi to runway two seven, hold short runway two seven, November one two three alpha bravo."
            ),
            other => panic!("expected readback, got {other:?}"),
        }
        assert_eq!(aircraft.phase(), Phase::Taxi);
        for _ in 0..4000 {
            aircraft.step(0.05);
            if aircraft.phase() == Phase::HoldShort {
                break;
            }
        }
        assert_eq!(aircraft.phase(), Phase::HoldShort);
        assert!(aircraft.snapshot().airspeed_kt < 0.5);
    }
}
