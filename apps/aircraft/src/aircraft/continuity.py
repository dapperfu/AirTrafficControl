# Implements: AC-SRS023
# @relation(AC-SRS023, scope=file)
"""Hand a pattern position to the enroute step without a position jump."""

from __future__ import annotations

import math

from aircraft.dynamics import Kinematics
from aircraft.enroute import PERFORMANCE, EnrouteLeg, Field

FT_PER_NM = 6076.12


def local_to_geo(field: Field, north_ft: float, east_ft: float) -> tuple[float, float]:
    """Convert a local north/east offset into the same latitude and longitude."""
    latitude = field.latitude + (north_ft / FT_PER_NM) / 60.0
    cosine = math.cos(math.radians(field.latitude))
    if abs(cosine) < 1.0e-6:
        cosine = 1.0e-6
    longitude = field.longitude + (east_ft / (FT_PER_NM * cosine)) / 60.0
    return latitude, longitude


def continue_leg(
    field: Field,
    kinematics: Kinematics,
    destination: Field,
    category: str = "piston",
) -> EnrouteLeg:
    """Start enroute at the pattern position, altitude, and heading."""
    if category not in PERFORMANCE:
        raise ValueError(category)
    latitude, longitude = local_to_geo(field, kinematics.north_ft, kinematics.east_ft)
    origin = Field(latitude, longitude, kinematics.altitude_ft)
    leg = EnrouteLeg(origin, destination, category)
    leg.state.heading_deg = kinematics.heading_deg
    leg.state.tas_kt = kinematics.ground_speed_kt
    leg.state.alt_ft = kinematics.altitude_ft
    return leg


def truth_track(
    ident: str,
    time_s: float,
    latitude: float,
    longitude: float,
    altitude_ft: float,
    north_fps: float,
    east_fps: float,
    wake: str,
    phase: str,
) -> dict[str, object]:
    """One published truth track. Publication is not a clearance."""
    return {
        "id": ident,
        "time_s": time_s,
        "lat": latitude,
        "lon": longitude,
        "alt_ft": altitude_ft,
        "vn_fps": north_fps,
        "ve_fps": east_fps,
        "wake": wake,
        "phase": phase,
    }
