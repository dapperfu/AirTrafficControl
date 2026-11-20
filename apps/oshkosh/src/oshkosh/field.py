"""Wittman Regional (KOSH) as flown during EAA AirVenture.

The paved inventory is the FAA Chart Supplement: runway 18/36 is
8,002 by 150 feet, 09/27 is 6,179 by 150, 05/23 is 3,424 by 75, and
13/31 is 3,061 by 75. The show uses a shorter set. The FAA domestic
notice "EAA AIRVENTURE OSHKOSH 2026" closes 05/23 and 13/31, shortens
the concrete 18/36 to 6,700 feet as 18R/36L, and turns Taxiway A into
temporary runway 36R, 6,300 by 60 feet.

Landing spots are the named marks in that notice. The remaining
landing distance is the figure printed beside each mark. Approach
order is the longer remaining distance first, so the first spot is
the one nearer the threshold. On 36L and 36R the notice also prints
6,700 and 6,300 after the colored marks. Those match the shortened
surface lengths, so they are the lengths here and not extra spots.

The ultralight grass strip, the seaplane base, and the helicopter
arrival are separate procedures. They are not surfaces in this fly-in.

The arrival clock is the same notice: arrivals from 07:00 to 20:00 CDT,
the afternoon airshow and TFR from 14:15 to 18:30, and arrivals again
30 minutes after that airshow. The night shows are after the arrival
day has already closed.
"""

from __future__ import annotations

from dataclasses import dataclass

ARRIVAL_OPEN_S = 7 * 3600
ARRIVAL_CLOSE_S = 20 * 3600
SHOW_CLOSE_S = 14 * 3600 + 15 * 60
SHOW_RESUME_S = 19 * 3600

PAVED: tuple[tuple[str, int, int], ...] = (
    ("18/36", 8002, 150),
    ("09/27", 6179, 150),
    ("05/23", 3424, 75),
    ("13/31", 3061, 75),
)


@dataclass(frozen=True)
class Spot:
    """One colored mark, square, or named threshold on a show surface."""

    runway: str
    name: str
    remaining_ft: int
    width_ft: int

    @property
    def key(self) -> str:
        return f"{self.runway} {self.name}"


@dataclass(frozen=True)
class Surface:
    """One landing surface and the spots an arrival may be sent to."""

    runway: str
    length_ft: int
    width_ft: int
    spots: tuple[Spot, ...]


def _surface(
    runway: str,
    length_ft: int,
    width_ft: int,
    marks: tuple[tuple[str, int], ...],
) -> Surface:
    spots = tuple(
        Spot(runway, name, remaining_ft, width_ft) for name, remaining_ft in marks
    )
    ordered = tuple(sorted(spots, key=lambda spot: -spot.remaining_ft))
    if spots != ordered:
        raise ValueError(f"{runway} spots must be listed toward the far end")
    for spot in spots:
        if spot.remaining_ft > length_ft or spot.remaining_ft <= 0:
            raise ValueError(f"{spot.key} remaining distance is outside the surface")
    return Surface(runway, length_ft, width_ft, spots)


# Remaining distances are the 2026 notice figures, in approach order.
SHOW: tuple[Surface, ...] = (
    _surface(
        "36L",
        6700,
        150,
        (
            ("purple dot", 4950),
            ("yellow dot", 3400),
        ),
    ),
    _surface(
        "36R",
        6300,
        60,
        (
            ("green square", 4700),
            ("red square", 3150),
        ),
    ),
    _surface(
        "18R",
        6700,
        150,
        (
            ("blue dot", 6350),
            ("pink dot", 4850),
        ),
    ),
    _surface(
        "27",
        6179,
        150,
        (
            ("displaced threshold", 5647),
            ("orange dot", 4600),
            ("green dot", 3100),
        ),
    ),
    _surface(
        "09",
        6179,
        150,
        (
            ("threshold", 6179),
            ("white dot", 4400),
        ),
    ),
    _surface("05/23", 3424, 75, ()),
    _surface("13/31", 3061, 75, ()),
)

CLOSED: tuple[str, ...] = ("05/23", "13/31")

# One direction on the concrete pair, plus the temporary parallel when
# the flow is north. Opposite ends of one pavement are not both active.
FLOWS: dict[str, tuple[str, ...]] = {
    "36-27": ("36L", "36R", "27"),
    "36-09": ("36L", "36R", "09"),
    "18-27": ("18R", "27"),
    "18-09": ("18R", "09"),
}

PAVED_FLOW: dict[str, tuple[str, ...]] = {
    "36-27": ("36L", "27"),
    "36-09": ("36L", "09"),
    "18-27": ("18R", "27"),
    "18-09": ("18R", "09"),
}

_BY_RUNWAY = {surface.runway: surface for surface in SHOW}


def accepting(at_s: int) -> bool:
    """True when an arrival may touch down."""

    if at_s < ARRIVAL_OPEN_S or at_s >= ARRIVAL_CLOSE_S:
        return False
    if SHOW_CLOSE_S <= at_s < SHOW_RESUME_S:
        return False
    return True


def next_open(at_s: int) -> int | None:
    """The next second the field accepts a landing, if this day still has one."""

    if at_s < ARRIVAL_OPEN_S:
        return ARRIVAL_OPEN_S
    if SHOW_CLOSE_S <= at_s < SHOW_RESUME_S:
        return SHOW_RESUME_S
    return None


def surfaces(names: tuple[str, ...]) -> tuple[Surface, ...]:
    """Return the named surfaces. A closed runway has no spots."""

    if not names:
        raise ValueError("a flow needs a runway")
    if len(names) != len(set(names)):
        raise ValueError("a flow lists each runway once")
    missing = [name for name in names if name not in _BY_RUNWAY]
    if missing:
        known = ", ".join(surface.runway for surface in SHOW)
        raise ValueError(f"unknown runway {missing[0]}; known runways are {known}")
    return tuple(_BY_RUNWAY[name] for name in names)


def flow_surfaces(flow: str) -> tuple[Surface, ...]:
    if flow not in FLOWS:
        known = ", ".join(FLOWS)
        raise ValueError(f"flow must be one of: {known}")
    return surfaces(FLOWS[flow])


def clock(at_s: int) -> str:
    """Hour and minute on the arrival-day clock."""

    hour, rem = divmod(at_s, 3600)
    return f"{hour:02d}:{rem // 60:02d}"
