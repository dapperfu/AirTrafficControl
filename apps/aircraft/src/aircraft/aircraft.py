# Implements: AC-SRS005
# Implements: AC-SRS006
# Implements: AC-SRS007
# Implements: AC-SRS008
# Implements: AC-SRS009
# Implements: AC-SRS010
# Implements: AC-SRS011
# Implements: AC-SRS012
# Implements: AC-SRS013
# Implements: AC-SRS014
# Implements: AC-SRS015
# Implements: AC-SRS016
# Implements: AC-SRS017
# Implements: AC-SRS018
# Implements: AC-SRS019
# Implements: AC-SRS020
# Implements: AC-SRS022
# Implements: AC-SDD001
# Implements: AC-SDD002
# Implements: AC-SSDD001
# Implements: AC-SSS001
# Implements: AC-SSS004
# Implements: AC-SSS005
# Implements: AC-SSS006
# Implements: AC-SSS007
# Implements: AC-OCD005
# @relation(AC-SRS005, AC-SRS006, AC-SRS007, AC-SRS008, AC-SRS009, AC-SRS010, AC-SRS011, AC-SRS012, AC-SRS013, AC-SRS014, AC-SRS015, AC-SRS016, AC-SRS017, AC-SRS018, AC-SRS019, AC-SRS020, AC-SRS022, AC-SDD001, AC-SDD002, AC-SSDD001, AC-SSS001, AC-SSS004, AC-SSS005, AC-SSS006, AC-SSS007, AC-OCD005, scope=file)
"""Pilot state machine. Motion changes only inside step."""

from __future__ import annotations

import math
from enum import Enum

from aircraft.config import AircraftConfig
from aircraft.dynamics import Kinematics, PointMass
from aircraft.link import InMemoryLink, LinkEvent
from aircraft.phrasebook import describe_position, render, unable_reason
from aircraft.callsign import CallSign
from aircraft.transmission import Kind, Role, Transmission

_AIRBORNE = {
    "climb",
    "crosswind",
    "downwind",
    "base",
    "final",
    "go_around",
}
_LANDING_KINDS = {Kind.LANDING, Kind.OPTION, Kind.TOUCH_AND_GO, Kind.STOP_AND_GO}
_CAPTURE_FT = 250.0
_LINEUP_FT = 100.0


class Phase(Enum):
    RAMP = "ramp"
    TAXI = "taxi"
    HOLD_SHORT = "hold_short"
    LINE_UP = "line_up"
    TAKEOFF_ROLL = "takeoff_roll"
    CLIMB = "climb"
    CROSSWIND = "crosswind"
    DOWNWIND = "downwind"
    BASE = "base"
    FINAL = "final"
    ROLLOUT = "rollout"
    STOPPED = "stopped"
    GO_AROUND = "go_around"


class Aircraft:
    """One configured civil aircraft, its phrase log, and its point-mass state."""

    def __init__(self, config: AircraftConfig, link: InMemoryLink | None = None) -> None:
        self.config = config
        self.link = link if link is not None else InMemoryLink()
        self.call_sign = CallSign(config.aircraft.n_number)
        self.facility = config.aircraft.facility
        self.phase = Phase.RAMP
        self.atis_letter: str | None = None
        self.sequence: int | None = None
        self.assigned_runway: str | None = None
        self.landing_mode: str | None = None
        self.lined_up = False
        self.decisions: list[tuple[str, str]] = []
        self.phrases: list[str] = []
        self._down_noted = False
        self._repeat_guard = False
        elevation = config.airport.elevation_ft
        self.dynamics = PointMass(
            Kinematics(
                north_ft=config.ramp.north_ft,
                east_ft=config.ramp.east_ft,
                altitude_ft=elevation,
                heading_deg=float(config.runway.heading_deg),
                ground_speed_kt=0.0,
                vertical_speed_fpm=0.0,
            ),
            turn_rate_deg_s=config.performance.turn_rate_deg_s,
            accel_kt_s=config.performance.accel_kt_s,
            vertical_speed_fpm=config.performance.vertical_speed_fpm,
        )

    def request_atis(self) -> Transmission | None:
        return self._originate(
            Transmission(role=Role.REQUEST, kind=Kind.ATIS),
            "AC-SRS005",
            "Requested ATIS",
        )

    def request_pattern_entry(self) -> Transmission | None:
        tx = Transmission(
            role=Role.REQUEST,
            kind=Kind.PATTERN,
            position=self.position_text(),
            runway_id=self.config.runway.id,
            pattern_side=self.config.runway.pattern,
            atis_letter=self.atis_letter,
        )
        return self._originate(tx, "AC-SRS010", "Requested pattern entry")

    def request_taxi(self) -> Transmission | None:
        tx = Transmission(role=Role.REQUEST, kind=Kind.TAXI, runway_id=self.config.runway.id)
        return self._originate(tx, "AC-SRS006", "Requested taxi")

    def report_holding_short(self) -> Transmission | None:
        tx = Transmission(
            role=Role.REPORT, kind=Kind.HOLD_SHORT, runway_id=self.config.runway.id
        )
        return self._originate(tx, "AC-SRS007", "Reported holding short")

    def report_ready(self) -> Transmission | None:
        tx = Transmission(role=Role.REQUEST, kind=Kind.READY, runway_id=self.config.runway.id)
        return self._originate(tx, "AC-SRS009", "Reported ready for takeoff")

    def request_landing(self) -> Transmission | None:
        tx = Transmission(
            role=Role.REQUEST,
            kind=Kind.LANDING,
            position=self.position_text(),
            runway_id=self.config.runway.id,
        )
        return self._originate(tx, "AC-SRS010", "Requested landing")

    def request_option(self) -> Transmission | None:
        tx = Transmission(role=Role.REQUEST, kind=Kind.OPTION, runway_id=self.config.runway.id)
        return self._originate(tx, "AC-SRS015", "Requested the option")

    def request_touch_and_go(self) -> Transmission | None:
        tx = Transmission(
            role=Role.REQUEST, kind=Kind.TOUCH_AND_GO, runway_id=self.config.runway.id
        )
        return self._originate(tx, "AC-SRS015", "Requested touch and go")

    def request_stop_and_go(self) -> Transmission | None:
        tx = Transmission(
            role=Role.REQUEST, kind=Kind.STOP_AND_GO, runway_id=self.config.runway.id
        )
        return self._originate(tx, "AC-SRS015", "Requested stop and go")

    def request_go_around(self) -> Transmission | None:
        if not self.link.up:
            self._note_down()
            return None
        if self.phase.value not in _AIRBORNE:
            return self._unable(
                Transmission(role=Role.CLEARANCE, kind=Kind.GO_AROUND, runway_id=self.config.runway.id)
            )
        self._begin_go_around()
        tx = Transmission(role=Role.REQUEST, kind=Kind.GO_AROUND)
        return self._originate(tx, "AC-SRS011", "Pilot going around")

    def request_frequency_change(self) -> Transmission | None:
        return self._originate(
            Transmission(role=Role.REQUEST, kind=Kind.FREQUENCY),
            "AC-SRS013",
            "Requested frequency change",
        )

    def report_position(self) -> Transmission | None:
        tx = Transmission(
            role=Role.REPORT, kind=Kind.POSITION, position=self.position_text()
        )
        return self._originate(tx, "AC-SRS014", "Reported position")

    def declare_emergency(self, kind: str, nature: str, intention: str) -> Transmission | None:
        if not self.link.up:
            self._note_down()
            return None
        emergency = Kind.MAYDAY if kind == "mayday" else Kind.PAN_PAN
        tx = Transmission(
            role=Role.EMERGENCY,
            kind=emergency,
            nature=nature,
            intention=intention,
            position=self.position_text(),
        )
        sent = self._send(self._stamp(tx))
        if sent is not None:
            self._log("AC-SRS020", f"Declared {kind}")
        return sent

    def receive(self, item: LinkEvent | Transmission) -> Transmission | None:
        if isinstance(item, LinkEvent):
            if item.kind == "down":
                self.link.up = False
                self._note_down()
                return None
            if item.kind == "up":
                self.link.up = True
                self._down_noted = False
                return None
            if item.kind == "garbled":
                if not self.link.up:
                    self._note_down()
                    return None
                if not item.addressed:
                    return None
                self._log("AC-SRS018", "Say again")
                return self._send(
                    self._stamp(Transmission(role=Role.QUERY, kind=Kind.SAY_AGAIN))
                )
            if item.transmission is None:
                return None
            item = item.transmission
        if not self.link.up:
            self._note_down()
            return None
        return self._handle(item)

    def step(self, dt: float) -> None:
        """Advance the point mass, then capture a waypoint. This is the only motion entry."""
        before = self.phase
        self._apply_targets()
        self.dynamics.step(dt)
        self._capture()
        if self.phase is not before and self.phase is not Phase.RAMP:
            self._log("AC-SRS021", f"Entered {self.phase.value}")

    def position_text(self) -> str:
        state = self.dynamics.state
        return describe_position(
            phase=self.phase.value,
            north_ft=state.north_ft,
            east_ft=state.east_ft,
            altitude_ft=state.altitude_ft,
            runway_id=self.config.runway.id,
            pattern=self.config.runway.pattern,
        )

    def _handle(self, tx: Transmission) -> Transmission | None:
        if tx.n_number and tx.n_number != self.call_sign.n_number:
            return None
        if tx.kind is Kind.INFORMATION:
            self.atis_letter = tx.atis_letter
            self._log("AC-SRS005", f"Information {tx.atis_letter}")
            return None
        if tx.runway_id and tx.runway_id != self.config.runway.id:
            return None
        if self._outside_performance(tx) or not self._phase_allows(tx):
            return self._unable(tx)
        self._accept(tx)
        if tx.kind is Kind.GO_AROUND:
            readback = Transmission(role=Role.READBACK, kind=Kind.GO_AROUND)
        elif tx.kind is Kind.FREQUENCY:
            readback = Transmission(
                role=Role.READBACK,
                kind=Kind.FREQUENCY,
                frequency_mhz=tx.frequency_mhz or self.config.aircraft.next_frequency_mhz,
            )
        else:
            readback = Transmission(
                role=Role.READBACK,
                kind=tx.kind,
                runway_id=tx.runway_id or self.config.runway.id,
                sequence=tx.sequence,
                hold_short=tx.hold_short or tx.kind is Kind.HOLD_SHORT,
            )
        return self._send(self._stamp(readback))

    def _accept(self, tx: Transmission) -> None:
        if tx.kind is Kind.TAXI:
            self.phase = Phase.TAXI
            self.lined_up = False
            self._log("AC-SRS006", "Accepted taxi")
            if tx.hold_short:
                self._log("AC-SRS007", "Accepted hold short with taxi")
        elif tx.kind is Kind.HOLD_SHORT:
            self.lined_up = False
            hold = self._point(-self.config.runway.hold_short_ft, 0.0)
            self.phase = Phase.HOLD_SHORT if self._close(hold) else Phase.TAXI
            self._log("AC-SRS007", "Accepted hold short")
        elif tx.kind is Kind.LINE_UP:
            self.phase = Phase.LINE_UP
            self.lined_up = False
            self._log("AC-SRS008", "Accepted line up and wait")
        elif tx.kind is Kind.TAKEOFF:
            self.phase = Phase.TAKEOFF_ROLL
            self.lined_up = False
            self.landing_mode = None
            self._log("AC-SRS009", "Accepted takeoff")
        elif tx.kind is Kind.LANDING:
            self.landing_mode = "full_stop"
            self._log("AC-SRS010", "Accepted landing")
        elif tx.kind is Kind.RUNWAY:
            self.assigned_runway = tx.runway_id
            self._log("AC-SRS010", "Accepted runway assignment")
        elif tx.kind is Kind.GO_AROUND:
            self._begin_go_around()
            self._log("AC-SRS011", "Accepted go around")
        elif tx.kind is Kind.SEQUENCE:
            self.sequence = tx.sequence
            self._log("AC-SRS012", f"Accepted sequence {tx.sequence}")
        elif tx.kind is Kind.FREQUENCY:
            self.facility = tx.next_facility or self.config.aircraft.next_facility
            self._log("AC-SRS013", f"Accepted frequency {self.facility}")
        elif tx.kind in {Kind.OPTION, Kind.TOUCH_AND_GO, Kind.STOP_AND_GO}:
            self.landing_mode = self._mode_for(tx.kind)
            self._log("AC-SRS015", f"Accepted {self.landing_mode}")

    def _begin_go_around(self) -> None:
        self.phase = Phase.GO_AROUND
        self.landing_mode = None
        self.dynamics.waypoint = None
        self.dynamics.target_heading_deg = float(self.config.runway.heading_deg)
        self.dynamics.target_altitude_ft = self._pattern_msl()
        self.dynamics.target_speed_kt = self.config.performance.pattern_speed_kt

    def _mode_for(self, kind: Kind) -> str:
        if kind is Kind.TOUCH_AND_GO:
            return "touch_and_go"
        if kind is Kind.STOP_AND_GO:
            return "stop_and_go"
        return self.config.option.choice

    def _outside_performance(self, tx: Transmission) -> bool:
        length = self.config.runway.length_ft
        if tx.kind is Kind.TAKEOFF and length < self.config.performance.takeoff_distance_ft:
            return True
        if tx.kind in _LANDING_KINDS and length < self.config.performance.landing_distance_ft:
            return True
        return False

    def _phase_allows(self, tx: Transmission) -> bool:
        phase = self.phase
        if tx.kind in {Kind.SEQUENCE, Kind.RUNWAY, Kind.FREQUENCY, Kind.INFORMATION}:
            return True
        if tx.kind is Kind.TAXI:
            return phase in {Phase.RAMP, Phase.TAXI}
        if tx.kind is Kind.HOLD_SHORT:
            return phase in {Phase.TAXI, Phase.HOLD_SHORT, Phase.LINE_UP}
        if tx.kind is Kind.LINE_UP:
            return phase is Phase.HOLD_SHORT
        if tx.kind is Kind.TAKEOFF:
            return phase is Phase.LINE_UP and self.lined_up
        if tx.kind in _LANDING_KINDS or tx.kind is Kind.GO_AROUND:
            return phase.value in _AIRBORNE
        return False

    def _unable(self, tx: Transmission) -> Transmission | None:
        reason = unable_reason(tx)
        self._log("AC-SRS016", f"Unable {reason}")
        reply = Transmission(role=Role.READBACK, kind=Kind.UNABLE, position=reason)
        return self._send(self._stamp(reply))

    def _originate(self, tx: Transmission, uid: str, summary: str) -> Transmission | None:
        if not self.link.up:
            self._note_down()
            return None
        sent = self._send(self._stamp(tx))
        if sent is not None:
            self._log(uid, summary)
        return sent

    def _stamp(self, tx: Transmission) -> Transmission:
        tx.facility = tx.facility or self.facility
        tx.call_sign = self.call_sign.spoken
        tx.n_number = self.call_sign.n_number
        tx.phrase = render(tx)
        return tx

    def _send(self, tx: Transmission) -> Transmission | None:
        if not self.link.up:
            self._note_down()
            return None
        result = self.link.send(tx)
        if result == "blocked" and not self._repeat_guard:
            self._repeat_guard = True
            self._log("AC-SRS019", "Repeated a blocked transmission")
            try:
                return self._send(tx)
            finally:
                self._repeat_guard = False
        if result != "sent":
            if result == "down":
                self._note_down()
            return None
        self.phrases.append(tx.phrase)
        return tx

    def _note_down(self) -> None:
        if not self._down_noted:
            self._down_noted = True
            self._log("AC-SRS017", "Link down")

    def _log(self, uid: str, summary: str) -> None:
        self.decisions.append((uid, summary))

    def _apply_targets(self) -> None:
        perf = self.config.performance
        elev = self.config.airport.elevation_ft
        heading = float(self.config.runway.heading_deg)
        dyn = self.dynamics
        dyn.target_heading_deg = heading
        dyn.target_altitude_ft = elev
        dyn.waypoint = None
        if self.phase in {Phase.RAMP, Phase.HOLD_SHORT, Phase.STOPPED}:
            dyn.target_speed_kt = 0.0
        elif self.phase is Phase.TAXI:
            dyn.target_speed_kt = perf.taxi_speed_kt
            dyn.waypoint = self._point(-self.config.runway.hold_short_ft, 0.0)
        elif self.phase is Phase.LINE_UP:
            dyn.target_speed_kt = 0.0 if self.lined_up else perf.taxi_speed_kt
            dyn.waypoint = None if self.lined_up else self._point(_LINEUP_FT, 0.0)
        elif self.phase is Phase.TAKEOFF_ROLL:
            dyn.target_speed_kt = perf.pattern_speed_kt
        elif self.phase in {Phase.CLIMB, Phase.GO_AROUND}:
            dyn.target_speed_kt = perf.pattern_speed_kt
            dyn.target_altitude_ft = self._pattern_msl()
        elif self.phase is Phase.CROSSWIND:
            dyn.target_speed_kt = perf.pattern_speed_kt
            dyn.target_altitude_ft = self._pattern_msl()
            dyn.waypoint = self._point(self.config.runway.upwind_ft, self.config.runway.pattern_offset_ft)
        elif self.phase is Phase.DOWNWIND:
            dyn.target_speed_kt = perf.pattern_speed_kt
            dyn.target_altitude_ft = self._pattern_msl()
            if self.landing_mode:
                dyn.waypoint = self._point(
                    -self.config.runway.pattern_offset_ft, self.config.runway.pattern_offset_ft
                )
            else:
                dyn.waypoint = self._point(self._along() - 2000.0, self.config.runway.pattern_offset_ft)
        elif self.phase is Phase.BASE:
            dyn.target_speed_kt = perf.pattern_speed_kt
            dyn.target_altitude_ft = self._pattern_msl()
            dyn.waypoint = self._point(-self.config.runway.pattern_offset_ft, 0.0)
        elif self.phase is Phase.FINAL:
            dyn.target_speed_kt = perf.pattern_speed_kt
            dyn.target_altitude_ft = self._final_altitude()
            dyn.waypoint = self._point(self.config.runway.length_ft, 0.0)
        elif self.phase is Phase.ROLLOUT:
            dyn.target_speed_kt = 0.0

    def _capture(self) -> None:
        if self.phase is Phase.TAXI and self._close(self._point(-self.config.runway.hold_short_ft, 0.0)):
            self._snap(self._point(-self.config.runway.hold_short_ft, 0.0), speed=0.0)
            self.phase = Phase.HOLD_SHORT
            return
        if self.phase is Phase.LINE_UP and not self.lined_up and self._close(self._point(_LINEUP_FT, 0.0)):
            self._snap(self._point(_LINEUP_FT, 0.0), speed=0.0)
            self.dynamics.state.heading_deg = float(self.config.runway.heading_deg)
            self.lined_up = True
            return
        if self.phase is Phase.TAKEOFF_ROLL and self.dynamics.state.ground_speed_kt >= self.config.performance.rotation_speed_kt:
            self.phase = Phase.CLIMB
            return
        if self.phase in {Phase.CLIMB, Phase.GO_AROUND} and self._at_pattern_altitude() and self._along() >= self.config.runway.upwind_ft:
            self.phase = Phase.CROSSWIND
            return
        if self.phase is Phase.CROSSWIND and self._close(
            self._point(self.config.runway.upwind_ft, self.config.runway.pattern_offset_ft)
        ):
            self._snap(self._point(self.config.runway.upwind_ft, self.config.runway.pattern_offset_ft))
            self.phase = Phase.DOWNWIND
            return
        downwind_end = self._point(
            -self.config.runway.pattern_offset_ft, self.config.runway.pattern_offset_ft
        )
        if self.phase is Phase.DOWNWIND and self.landing_mode and self._close(downwind_end):
            self._snap(downwind_end)
            self.phase = Phase.BASE
            return
        if (
            self.phase is Phase.DOWNWIND
            and self.landing_mode
            and self._along() <= -self.config.runway.pattern_offset_ft
        ):
            self.phase = Phase.BASE
            return
        intercept = self._point(-self.config.runway.pattern_offset_ft, 0.0)
        if self.phase is Phase.BASE and self._close(intercept):
            self._snap(intercept)
            self.phase = Phase.FINAL
            return
        if self.phase is Phase.FINAL and self._along() >= 0.0:
            if self.landing_mode == "low_approach":
                self.phase = Phase.GO_AROUND
                return
            if self.landing_mode and self.dynamics.state.altitude_ft <= self.config.airport.elevation_ft + 40.0:
                if self.landing_mode == "touch_and_go":
                    self.phase = Phase.TAKEOFF_ROLL
                else:
                    self.phase = Phase.ROLLOUT
                return
        if self.phase is Phase.ROLLOUT and self.dynamics.state.ground_speed_kt <= 0.5:
            self.dynamics.state.ground_speed_kt = 0.0
            if self.landing_mode == "stop_and_go":
                self.phase = Phase.TAKEOFF_ROLL
                self.landing_mode = None
            else:
                self.phase = Phase.STOPPED

    def _final_altitude(self) -> float:
        elev = self.config.airport.elevation_ft
        if self.landing_mode == "low_approach":
            return elev + self.config.performance.low_approach_ft
        offset = self.config.runway.pattern_offset_ft
        along = self._along()
        if along <= -offset:
            return self._pattern_msl()
        if along >= 0.0:
            return elev
        fraction = (along + offset) / offset
        return self._pattern_msl() + (elev - self._pattern_msl()) * fraction

    def _pattern_msl(self) -> float:
        return self.config.airport.elevation_ft + self.config.performance.pattern_altitude_ft

    def _at_pattern_altitude(self) -> bool:
        return abs(self.dynamics.state.altitude_ft - self._pattern_msl()) <= 30.0

    def _along(self) -> float:
        north, east = self._unit(float(self.config.runway.heading_deg))
        return self.dynamics.state.north_ft * north + self.dynamics.state.east_ft * east

    def _point(self, along: float, side: float) -> tuple[float, float]:
        north, east = self._unit(float(self.config.runway.heading_deg))
        side_north, side_east = self._side_unit()
        return (north * along + side_north * side, east * along + side_east * side)

    def _side_unit(self) -> tuple[float, float]:
        turn = -90.0 if self.config.runway.pattern == "left" else 90.0
        return self._unit(self.config.runway.heading_deg + turn)

    def _unit(self, heading_deg: float) -> tuple[float, float]:
        heading = math.radians(heading_deg)
        return (math.cos(heading), math.sin(heading))

    def _close(self, point: tuple[float, float]) -> bool:
        return math.hypot(
            self.dynamics.state.north_ft - point[0],
            self.dynamics.state.east_ft - point[1],
        ) <= _CAPTURE_FT

    def _snap(self, point: tuple[float, float], speed: float | None = None) -> None:
        self.dynamics.state.north_ft = point[0]
        self.dynamics.state.east_ft = point[1]
        self.dynamics.waypoint = None
        if speed is not None:
            self.dynamics.state.ground_speed_kt = speed
