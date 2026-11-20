"""Climb, cruise, and descent between the departure pattern and the arrival pattern.

The C step owns the great-circle path. Taxi and the local pattern stay in
the Python point-mass model.
"""

from __future__ import annotations

import ctypes
from dataclasses import dataclass
from pathlib import Path

TERMINAL_NM = 30.0

PERFORMANCE = {
    "jet": {
        "cruise_alt_ft": 35000.0,
        "climb_fpm": 2000.0,
        "descent_fpm": 1500.0,
        "climb_tas_kt": 250.0,
        "cruise_tas_kt": 450.0,
        "descent_tas_kt": 280.0,
    },
    "turboprop": {
        "cruise_alt_ft": 25000.0,
        "climb_fpm": 1500.0,
        "descent_fpm": 1200.0,
        "climb_tas_kt": 180.0,
        "cruise_tas_kt": 280.0,
        "descent_tas_kt": 200.0,
    },
    "piston": {
        "cruise_alt_ft": 8500.0,
        "climb_fpm": 700.0,
        "descent_fpm": 500.0,
        "climb_tas_kt": 90.0,
        "cruise_tas_kt": 120.0,
        "descent_tas_kt": 100.0,
    },
}


class PhysState(ctypes.Structure):
    _fields_ = [
        ("lat_deg", ctypes.c_double),
        ("lon_deg", ctypes.c_double),
        ("alt_ft", ctypes.c_double),
        ("heading_deg", ctypes.c_double),
        ("tas_kt", ctypes.c_double),
        ("vertical_fpm", ctypes.c_double),
        ("distance_nm", ctypes.c_double),
        ("distance_remaining_nm", ctypes.c_double),
        ("phase", ctypes.c_int),
        ("pad", ctypes.c_int),
    ]


class PhysRoute(ctypes.Structure):
    _fields_ = [
        ("origin_lat", ctypes.c_double),
        ("origin_lon", ctypes.c_double),
        ("origin_alt_ft", ctypes.c_double),
        ("dest_lat", ctypes.c_double),
        ("dest_lon", ctypes.c_double),
        ("dest_alt_ft", ctypes.c_double),
        ("cruise_alt_ft", ctypes.c_double),
        ("climb_fpm", ctypes.c_double),
        ("descent_fpm", ctypes.c_double),
        ("climb_tas_kt", ctypes.c_double),
        ("cruise_tas_kt", ctypes.c_double),
        ("descent_tas_kt", ctypes.c_double),
    ]


def library_path() -> Path:
    return Path(__file__).resolve().parents[4] / "apps" / "physics" / "libphysics.so"


def load_library(path: Path | None = None) -> ctypes.CDLL:
    lib = ctypes.CDLL(str(path or library_path()))
    lib.phys_state_size.restype = ctypes.c_int
    lib.phys_step.argtypes = [
        ctypes.POINTER(PhysState),
        ctypes.POINTER(PhysRoute),
        ctypes.c_double,
    ]
    if lib.phys_state_size() != ctypes.sizeof(PhysState):
        raise RuntimeError("physics state layout does not match the C compiler")
    return lib


@dataclass
class Field:
    latitude: float
    longitude: float
    elevation_ft: float


class EnrouteLeg:
    """One city pair. step is the only motion call between the two patterns."""

    def __init__(self, origin: Field, destination: Field, category: str = "jet") -> None:
        performance = PERFORMANCE[category]
        self._lib = load_library()
        self.steps = 0
        self.state = PhysState(
            lat_deg=origin.latitude,
            lon_deg=origin.longitude,
            alt_ft=origin.elevation_ft,
            distance_remaining_nm=1.0e9,
            phase=0,
        )
        self.route = PhysRoute(
            origin_lat=origin.latitude,
            origin_lon=origin.longitude,
            origin_alt_ft=origin.elevation_ft,
            dest_lat=destination.latitude,
            dest_lon=destination.longitude,
            dest_alt_ft=destination.elevation_ft,
            cruise_alt_ft=performance["cruise_alt_ft"],
            climb_fpm=performance["climb_fpm"],
            descent_fpm=performance["descent_fpm"],
            climb_tas_kt=performance["climb_tas_kt"],
            cruise_tas_kt=performance["cruise_tas_kt"],
            descent_tas_kt=performance["descent_tas_kt"],
        )

    def step(self, dt_s: float) -> PhysState:
        self._lib.phys_step(ctypes.byref(self.state), ctypes.byref(self.route), dt_s)
        self.steps += 1
        return self.state

    def fly_to_terminal(self, dt_s: float, limit: int = 20000) -> PhysState:
        while (
            self.state.phase != 3
            and self.state.distance_remaining_nm >= TERMINAL_NM
            and self.steps < limit
        ):
            self.step(dt_s)
        if self.state.distance_remaining_nm >= TERMINAL_NM:
            raise RuntimeError("enroute leg did not reach the arrival terminal area")
        return self.state
