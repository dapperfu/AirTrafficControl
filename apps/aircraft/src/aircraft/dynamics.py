# Implements: AC-SRS021
# Implements: AC-SDD003
# Implements: AC-OCD003
# @relation(AC-SRS021, AC-SDD003, AC-OCD003, scope=file)
"""Deterministic point-mass step. Callers advance time only through step."""

from __future__ import annotations

import math
from dataclasses import dataclass

KNOT_FT_S = 6076.12 / 3600.0


@dataclass
class Kinematics:
    north_ft: float
    east_ft: float
    altitude_ft: float
    heading_deg: float
    ground_speed_kt: float
    vertical_speed_fpm: float


class PointMass:
    """Integrate heading, speed, then vertical speed, then position and altitude."""

    def __init__(
        self,
        state: Kinematics,
        *,
        turn_rate_deg_s: float,
        accel_kt_s: float,
        vertical_speed_fpm: float,
    ) -> None:
        self.state = state
        self.turn_rate_deg_s = turn_rate_deg_s
        self.accel_kt_s = accel_kt_s
        self.max_vertical_speed_fpm = vertical_speed_fpm
        self.target_heading_deg = state.heading_deg
        self.target_speed_kt = state.ground_speed_kt
        self.target_altitude_ft = state.altitude_ft
        self.waypoint: tuple[float, float] | None = None

    def step(self, dt: float) -> None:
        if dt <= 0:
            raise ValueError("time step must be positive")
        self._turn(dt)
        self._accelerate(dt)
        self._climb(dt)
        self._translate(dt)

    def _turn(self, dt: float) -> None:
        desired = self._desired_heading()
        delta = (desired - self.state.heading_deg + 540.0) % 360.0 - 180.0
        limit = self.turn_rate_deg_s * dt
        if delta > limit:
            delta = limit
        elif delta < -limit:
            delta = -limit
        self.state.heading_deg = (self.state.heading_deg + delta) % 360.0

    def _desired_heading(self) -> float:
        if self.waypoint is None:
            return self.target_heading_deg
        north = self.waypoint[0] - self.state.north_ft
        east = self.waypoint[1] - self.state.east_ft
        if math.hypot(north, east) < 1.0:
            return self.target_heading_deg
        return math.degrees(math.atan2(east, north)) % 360.0

    def _accelerate(self, dt: float) -> None:
        delta = self.target_speed_kt - self.state.ground_speed_kt
        limit = self.accel_kt_s * dt
        if delta > limit:
            delta = limit
        elif delta < -limit:
            delta = -limit
        self.state.ground_speed_kt += delta
        if self.state.ground_speed_kt < 0:
            self.state.ground_speed_kt = 0

    def _climb(self, dt: float) -> None:
        error = self.target_altitude_ft - self.state.altitude_ft
        needed = error / dt * 60.0
        limit = self.max_vertical_speed_fpm
        if needed > limit:
            needed = limit
        elif needed < -limit:
            needed = -limit
        self.state.vertical_speed_fpm = needed
        self.state.altitude_ft += needed / 60.0 * dt

    def _translate(self, dt: float) -> None:
        heading = math.radians(self.state.heading_deg)
        feet = self.state.ground_speed_kt * KNOT_FT_S * dt
        self.state.north_ft += feet * math.cos(heading)
        self.state.east_ft += feet * math.sin(heading)
