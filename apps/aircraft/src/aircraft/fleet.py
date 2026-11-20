# Implements: AC-SRS023
# @relation(AC-SRS023, scope=file)
"""Step more than one aircraft and publish a truth track for each."""

from __future__ import annotations

import math

from aircraft.aircraft import Aircraft
from aircraft.continuity import local_to_geo, truth_track
from aircraft.enroute import Field


class Fleet:
    """Several aircraft on one clock. Each step publishes one track per aircraft."""

    def __init__(self, aircraft: list[Aircraft]) -> None:
        if len(aircraft) < 2:
            raise ValueError("a fleet has more than one aircraft")
        self.aircraft = list(aircraft)

    def step(self, dt: float) -> None:
        for aircraft in self.aircraft:
            aircraft.step(dt)

    def tracks(self, field: Field, time_s: float) -> list[dict[str, object]]:
        rows = []
        for aircraft in self.aircraft:
            state = aircraft.dynamics.state
            latitude, longitude = local_to_geo(field, state.north_ft, state.east_ft)
            heading = state.heading_deg
            speed = state.ground_speed_kt * 6076.12 / 3600.0
            rows.append(
                truth_track(
                    aircraft.call_sign.n_number,
                    time_s,
                    latitude,
                    longitude,
                    state.altitude_ft,
                    speed * math.cos(math.radians(heading)),
                    speed * math.sin(math.radians(heading)),
                    "small",
                    aircraft.phase.value,
                )
            )
        return rows
