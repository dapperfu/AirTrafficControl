# Implements: AC-IRS001
# @relation(AC-IRS001, scope=file)
"""Information content of one aircraft transmission."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class Role(Enum):
    REQUEST = "request"
    READBACK = "readback"
    CLEARANCE = "clearance"
    ADVISORY = "advisory"
    QUERY = "query"
    EMERGENCY = "emergency"
    REPORT = "report"


class Kind(Enum):
    ATIS = "atis"
    PATTERN = "pattern"
    TAXI = "taxi"
    HOLD_SHORT = "hold_short"
    READY = "ready"
    LINE_UP = "line_up"
    TAKEOFF = "takeoff"
    LANDING = "landing"
    GO_AROUND = "go_around"
    SEQUENCE = "sequence"
    RUNWAY = "runway"
    FREQUENCY = "frequency"
    POSITION = "position"
    OPTION = "option"
    TOUCH_AND_GO = "touch_and_go"
    STOP_AND_GO = "stop_and_go"
    SAY_AGAIN = "say_again"
    UNABLE = "unable"
    MAYDAY = "mayday"
    PAN_PAN = "pan_pan"
    INFORMATION = "information"


@dataclass
class Transmission:
    """One phrase and the fields it carries. No byte encoding is stored."""

    role: Role
    kind: Kind
    facility: str = ""
    call_sign: str = ""
    n_number: str | None = None
    position: str | None = None
    runway_id: str | None = None
    sequence: int | None = None
    atis_letter: str | None = None
    frequency_mhz: float | None = None
    next_facility: str | None = None
    nature: str | None = None
    intention: str | None = None
    hold_short: bool = False
    pattern_side: str | None = None
    phrase: str = ""
