# Implements: AC-OCD001
# Implements: AC-SUM001
# @relation(AC-OCD001, AC-SUM001, scope=file)
"""One scripted pattern. The tower peer is outside this module."""

from __future__ import annotations

from aircraft.aircraft import Aircraft, Phase


class PatternMission:
    """Issue the pattern calls in order and step the aircraft in deterministic time."""

    def __init__(self, aircraft: Aircraft) -> None:
        self.aircraft = aircraft
        self.done = False
        self.stage = "atis"

    def tick(self, dt: float) -> None:
        aircraft = self.aircraft
        if self.stage == "atis":
            aircraft.request_atis()
            self.stage = "await_atis"
        elif self.stage == "await_atis" and aircraft.atis_letter:
            aircraft.request_pattern_entry()
            self.stage = "taxi"
        elif self.stage == "taxi" and aircraft.phase is Phase.RAMP:
            aircraft.request_taxi()
            self.stage = "ready"
        elif self.stage == "ready" and aircraft.phase is Phase.HOLD_SHORT:
            aircraft.report_holding_short()
            aircraft.report_ready()
            self.stage = "airborne"
        elif self.stage == "airborne" and aircraft.phase is Phase.DOWNWIND:
            aircraft.report_position()
            self._request_downwind_clearance()
            self.stage = "frequency"
        elif self.stage == "frequency" and aircraft.phase is Phase.STOPPED:
            aircraft.request_frequency_change()
            self.stage = "await_freq"
        elif (
            self.stage == "await_freq"
            and aircraft.facility == aircraft.config.aircraft.next_facility
        ):
            self.done = True
            return
        aircraft.step(dt)

    def _request_downwind_clearance(self) -> None:
        choice = self.aircraft.config.option.choice
        if choice == "touch_and_go":
            self.aircraft.request_touch_and_go()
        elif choice == "stop_and_go":
            self.aircraft.request_stop_and_go()
        elif choice == "low_approach":
            self.aircraft.request_option()
        else:
            self.aircraft.request_landing()
