# Implements: AC-SRS001
# Implements: AC-IRS003
# Implements: AC-DBDD001
# @relation(AC-SRS001, AC-IRS003, AC-DBDD001, scope=file)
"""Load one aircraft TOML file. An invalid file does not produce an aircraft."""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path

from aircraft.callsign import CallSign, CallSignError

_TOP = {"aircraft", "performance", "airport", "runway", "ramp", "option"}
_AIRCRAFT = {"n_number", "facility", "next_facility", "next_frequency_mhz"}
_PERFORMANCE = {
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
}
_AIRPORT = {"name", "elevation_ft"}
_RUNWAY = {
    "id",
    "heading_deg",
    "length_ft",
    "pattern",
    "hold_short_ft",
    "pattern_offset_ft",
    "upwind_ft",
}
_RAMP = {"north_ft", "east_ft"}
_OPTION = {"choice"}
_CHOICES = {"full_stop", "touch_and_go", "stop_and_go", "low_approach"}
_RUNWAY_ID = __import__("re").compile(r"^(0[1-9]|[12][0-9]|3[0-6])[LCR]?$")


class ConfigError(ValueError):
    """The TOML file is missing, unreadable, or outside the aircraft schema."""


@dataclass(frozen=True)
class AircraftIdentity:
    n_number: str
    facility: str
    next_facility: str
    next_frequency_mhz: float


@dataclass(frozen=True)
class Performance:
    taxi_speed_kt: float
    rotation_speed_kt: float
    pattern_speed_kt: float
    pattern_altitude_ft: float
    takeoff_distance_ft: float
    landing_distance_ft: float
    turn_rate_deg_s: float
    accel_kt_s: float
    vertical_speed_fpm: float
    low_approach_ft: float


@dataclass(frozen=True)
class Airport:
    name: str
    elevation_ft: float


@dataclass(frozen=True)
class Runway:
    id: str
    heading_deg: int
    length_ft: float
    pattern: str
    hold_short_ft: float
    pattern_offset_ft: float
    upwind_ft: float


@dataclass(frozen=True)
class Ramp:
    north_ft: float
    east_ft: float


@dataclass(frozen=True)
class Option:
    choice: str


@dataclass(frozen=True)
class AircraftConfig:
    aircraft: AircraftIdentity
    performance: Performance
    airport: Airport
    runway: Runway
    ramp: Ramp
    option: Option


def load_config(path: str | Path) -> AircraftConfig:
    """Read ``path``. Raise ConfigError instead of returning a flying aircraft."""
    file_path = Path(path)
    try:
        data = tomllib.loads(file_path.read_text(encoding="utf-8"))
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise ConfigError(str(exc)) from exc
    if not isinstance(data, dict) or set(data) != _TOP:
        raise ConfigError("aircraft TOML must contain exactly the six required tables")
    aircraft = _table(data, "aircraft", _AIRCRAFT)
    performance = _table(data, "performance", _PERFORMANCE)
    airport = _table(data, "airport", _AIRPORT)
    runway = _table(data, "runway", _RUNWAY)
    ramp = _table(data, "ramp", _RAMP)
    option = _table(data, "option", _OPTION)
    identity = _identity(aircraft)
    perf = _performance(performance)
    port = Airport(name=_text(airport, "name"), elevation_ft=_number(airport, "elevation_ft"))
    strip = _runway(runway)
    pad = Ramp(north_ft=_number(ramp, "north_ft"), east_ft=_number(ramp, "east_ft"))
    choice = option["choice"]
    if choice not in _CHOICES:
        raise ConfigError("option.choice is outside the closed set")
    if strip.upwind_ft <= strip.length_ft:
        raise ConfigError("upwind_ft must pass the departure end")
    if perf.low_approach_ft >= perf.pattern_altitude_ft:
        raise ConfigError("low_approach_ft must be below pattern altitude")
    return AircraftConfig(
        aircraft=identity,
        performance=perf,
        airport=port,
        runway=strip,
        ramp=pad,
        option=Option(choice=str(choice)),
    )


def _identity(table: dict[str, object]) -> AircraftIdentity:
    n_number = table["n_number"]
    if not isinstance(n_number, str):
        raise ConfigError("n_number must be a string")
    try:
        CallSign(n_number)
    except CallSignError as exc:
        raise ConfigError(str(exc)) from exc
    facility = _text(table, "facility")
    nxt = _text(table, "next_facility")
    if "," in facility or "," in nxt:
        raise ConfigError("facility names must not contain a comma")
    frequency = _number(table, "next_frequency_mhz")
    if frequency < 118.0 or frequency > 136.975:
        raise ConfigError("next_frequency_mhz is outside 118.000 to 136.975")
    return AircraftIdentity(n_number, facility, nxt, frequency)


def _performance(table: dict[str, object]) -> Performance:
    perf = Performance(
        taxi_speed_kt=_positive(table, "taxi_speed_kt"),
        rotation_speed_kt=_positive(table, "rotation_speed_kt"),
        pattern_speed_kt=_positive(table, "pattern_speed_kt"),
        pattern_altitude_ft=_positive(table, "pattern_altitude_ft"),
        takeoff_distance_ft=_positive(table, "takeoff_distance_ft"),
        landing_distance_ft=_positive(table, "landing_distance_ft"),
        turn_rate_deg_s=_positive(table, "turn_rate_deg_s"),
        accel_kt_s=_positive(table, "accel_kt_s"),
        vertical_speed_fpm=_positive(table, "vertical_speed_fpm"),
        low_approach_ft=_positive(table, "low_approach_ft"),
    )
    if not perf.taxi_speed_kt < perf.rotation_speed_kt < perf.pattern_speed_kt:
        raise ConfigError("speeds must increase from taxi to rotation to pattern")
    return perf


def _runway(table: dict[str, object]) -> Runway:
    runway_id = table["id"]
    if not isinstance(runway_id, str) or _RUNWAY_ID.fullmatch(runway_id) is None:
        raise ConfigError("runway id must be 01 through 36 with an optional L, C, or R")
    heading = table["heading_deg"]
    if isinstance(heading, bool) or not isinstance(heading, int) or not 0 <= heading <= 359:
        raise ConfigError("heading_deg must be an integer from 0 through 359")
    pattern = table["pattern"]
    if pattern not in {"left", "right"}:
        raise ConfigError("pattern must be left or right")
    return Runway(
        id=runway_id,
        heading_deg=heading,
        length_ft=_positive(table, "length_ft"),
        pattern=str(pattern),
        hold_short_ft=_positive(table, "hold_short_ft"),
        pattern_offset_ft=_positive(table, "pattern_offset_ft"),
        upwind_ft=_positive(table, "upwind_ft"),
    )


def _table(data: dict[str, object], name: str, keys: set[str]) -> dict[str, object]:
    table = data[name]
    if not isinstance(table, dict) or set(table) != keys:
        raise ConfigError(f"{name} must contain exactly its required keys")
    return table


def _text(table: dict[str, object], key: str) -> str:
    value = table[key]
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{key} must be a non-empty string")
    return value


def _number(table: dict[str, object], key: str) -> float:
    value = table[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ConfigError(f"{key} must be a number")
    return float(value)


def _positive(table: dict[str, object], key: str) -> float:
    value = _number(table, key)
    if value <= 0:
        raise ConfigError(f"{key} must be greater than zero")
    return value
