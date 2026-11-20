"""Land a Fisk arrival stream on the runways Wittman has open.

The notice lets category 1 and 2 aircraft use the colored marks as
the separation cue. Marks on one runway are about 1,500 feet apart.
This model turns that into a 15 second gap between touchdowns on the
same surface, and it keeps each mark busy until that aircraft is off
the runway. A second aircraft may use another mark on the same runway
before the first has exited. With simultaneous landings off, the
whole runway stays busy until the occupant exits.

The 15 second gap, the occupancy times, the 60 second sequencing
window, the 4 minute go-around, and the traffic mix are assumptions.
They are not measured Oshkosh counts. The default fly-in is 1,500
arrivals because the FAA published 3,072 flights, arrivals and
departures together, for the busiest AirVenture day in 2021. Using
half of that day as arrivals is a scenario choice.

An aircraft that fits no open mark diverts. An aircraft that fits a
mark, but not inside the sequencing window, goes around and tries
again. After two go-arounds it diverts. A field closure holds up to
40 aircraft until the field reopens; the rest divert. Every aircraft
has either landed or diverted when the run ends.
"""

from __future__ import annotations

import heapq
import random
from dataclasses import dataclass

from oshkosh.field import (
    ARRIVAL_CLOSE_S,
    ARRIVAL_OPEN_S,
    SHOW_CLOSE_S,
    SHOW_RESUME_S,
    Spot,
    Surface,
    accepting,
    flow_surfaces,
    next_open,
    surfaces,
)

GAP_S = 15
SEQUENCE_S = 60
GO_AROUND_S = 4 * 60
MAX_GO_AROUNDS = 2
HOLD_LIMIT = 40
DEFAULT_ARRIVALS = 1500

# landing distance, wingspan, seconds on the runway
LIGHT = (1500, 40, 40)
TWIN = (2500, 45, 55)
LARGE = (4000, 80, 90)


@dataclass(frozen=True)
class Aircraft:
    seq: int
    at_s: int
    landing_ft: int
    width_ft: int
    occupancy_s: int


@dataclass(frozen=True)
class Landing:
    seq: int
    runway: str
    spot: str
    at_s: int


@dataclass(frozen=True)
class Result:
    flew_in: int
    landed: int
    go_arounds: int
    diverted: int
    landings: tuple[Landing, ...]


def fly_in(count: int = DEFAULT_ARRIVALS, seed: int = 1) -> list[Aircraft]:
    """Build a deterministic arrival list inside the open windows.

    The first two hours are the push. The rest of the morning is
    steadier. The hour after the airshow is lighter. Nothing is
    scheduled while the field is closed.
    """

    if count < 0:
        raise ValueError("fly-in count must be zero or more")
    windows = (
        (ARRIVAL_OPEN_S, ARRIVAL_OPEN_S + 2 * 3600, 2.0),
        (ARRIVAL_OPEN_S + 2 * 3600, SHOW_CLOSE_S, 1.0),
        (SHOW_RESUME_S, ARRIVAL_CLOSE_S, 0.7),
    )
    weights = [(end - start) * rate for start, end, rate in windows]
    total = sum(weights)
    rng = random.Random(seed)
    drafted: list[tuple[int, int, int, int, int]] = []
    for index in range(count):
        pick = rng.random() * total
        start, end = windows[-1][0], windows[-1][1]
        covered = 0.0
        for (window_start, window_end, _), weight in zip(windows, weights):
            covered += weight
            if pick < covered:
                start, end = window_start, window_end
                break
        roll = rng.random()
        if roll < 0.85:
            landing_ft, width_ft, occupancy_s = LIGHT
        elif roll < 0.97:
            landing_ft, width_ft, occupancy_s = TWIN
        else:
            landing_ft, width_ft, occupancy_s = LARGE
        drafted.append(
            (rng.randrange(start, end), index, landing_ft, width_ft, occupancy_s)
        )
    drafted.sort()
    return [
        Aircraft(seq, at_s, landing_ft, width_ft, occupancy_s)
        for seq, (at_s, _, landing_ft, width_ft, occupancy_s) in enumerate(drafted)
    ]


def land(
    aircraft: list[Aircraft],
    flow: str = "36-27",
    runways: tuple[str, ...] | None = None,
    simultaneous: bool = True,
    gap_s: int = GAP_S,
    sequence_s: int = SEQUENCE_S,
    go_around_s: int = GO_AROUND_S,
    max_go_arounds: int = MAX_GO_AROUNDS,
    hold_limit: int = HOLD_LIMIT,
) -> Result:
    """Accept the stream onto the selected surfaces.

    `runways` replaces the flow's surface list. Closed runways are
    selectable and contribute no spots.
    """

    if gap_s < 0 or sequence_s < 0 or go_around_s < 1:
        raise ValueError("gap and sequence must be zero or more, and a go-around takes time")
    if max_go_arounds < 0 or hold_limit < 0:
        raise ValueError("go-around and hold limits must be zero or more")
    selected = surfaces(runways) if runways is not None else flow_surfaces(flow)
    _check_aircraft(aircraft)

    by_runway = {surface.runway: surface for surface in selected}
    free_at = {
        spot.key: 0 for surface in selected for spot in surface.spots
    }
    runway_next = {surface.runway: 0 for surface in selected}
    runway_count = {surface.runway: 0 for surface in selected}
    fleet = {item.seq: item for item in aircraft}
    attempts = {item.seq: 0 for item in aircraft}
    waiting: set[int] = set()
    events: list[tuple[int, int]] = [(item.at_s, item.seq) for item in aircraft]
    heapq.heapify(events)
    landings: list[Landing] = []
    go_arounds = 0
    diverted = 0

    while events:
        at_s, seq = heapq.heappop(events)
        waiting.discard(seq)
        item = fleet[seq]
        if not accepting(at_s):
            reopen = next_open(at_s)
            if reopen is None or len(waiting) >= hold_limit:
                diverted += 1
                continue
            waiting.add(seq)
            heapq.heappush(events, (reopen, seq))
            continue
        choice = _choose(
            item,
            at_s,
            selected,
            free_at,
            runway_next,
            runway_count,
            simultaneous,
            sequence_s,
        )
        if choice is None:
            if not _fits_any(item, selected):
                diverted += 1
                continue
            if attempts[seq] >= max_go_arounds:
                diverted += 1
                continue
            attempts[seq] += 1
            go_arounds += 1
            heapq.heappush(events, (at_s + go_around_s, seq))
            continue
        ready, spot = choice
        _occupy(
            by_runway[spot.runway],
            spot.key,
            ready,
            item.occupancy_s,
            gap_s,
            free_at,
            runway_next,
            simultaneous,
        )
        runway_count[spot.runway] += 1
        landings.append(Landing(seq, spot.runway, spot.name, ready))

    return Result(len(aircraft), len(landings), go_arounds, diverted, tuple(landings))


def busiest_hour(times: list[int]) -> tuple[int, int]:
    """Return the start and count of the busiest clock hour."""

    if not times:
        return (0, 0)
    ordered = sorted(times)
    best = 0
    start = ordered[0]
    end_index = 0
    for begin, opened in enumerate(ordered):
        while end_index < len(ordered) and ordered[end_index] < opened + 3600:
            end_index += 1
        count = end_index - begin
        if count > best:
            best = count
            start = opened
    return (start, best)


def _check_aircraft(aircraft: list[Aircraft]) -> None:
    seen: set[int] = set()
    for item in aircraft:
        if item.seq in seen:
            raise ValueError("each aircraft needs its own sequence number")
        seen.add(item.seq)
        if item.landing_ft < 1 or item.width_ft < 1 or item.occupancy_s < 1:
            raise ValueError("landing distance, width, and occupancy must be positive")


def _fits(item: Aircraft, spot_remaining: int, spot_width: int) -> bool:
    return item.landing_ft <= spot_remaining and item.width_ft <= spot_width


def _fits_any(item: Aircraft, selected: tuple[Surface, ...]) -> bool:
    return any(
        _fits(item, spot.remaining_ft, spot.width_ft)
        for surface in selected
        for spot in surface.spots
    )


def _choose(
    item: Aircraft,
    at_s: int,
    selected: tuple[Surface, ...],
    free_at: dict[str, int],
    runway_next: dict[str, int],
    runway_count: dict[str, int],
    simultaneous: bool,
    sequence_s: int,
) -> tuple[int, Spot] | None:
    best_rank: tuple[int, int, int] | None = None
    best_spot: Spot | None = None
    for surface in selected:
        if surface.spots:
            runway_free = max(free_at[spot.key] for spot in surface.spots)
        else:
            runway_free = 0
        for spot in surface.spots:
            if not _fits(item, spot.remaining_ft, spot.width_ft):
                continue
            occupied = free_at[spot.key] if simultaneous else runway_free
            ready = max(at_s, occupied, runway_next[surface.runway])
            if not accepting(ready) or ready - at_s > sequence_s:
                continue
            # Earliest opening, then the runway with fewer landings, then the nearer mark.
            rank = (ready, runway_count[surface.runway], -spot.remaining_ft)
            if best_rank is None or rank < best_rank:
                best_rank = rank
                best_spot = spot
    if best_rank is None or best_spot is None:
        return None
    return best_rank[0], best_spot


def _occupy(
    surface: Surface,
    spot_key: str,
    ready: int,
    occupancy_s: int,
    gap_s: int,
    free_at: dict[str, int],
    runway_next: dict[str, int],
    simultaneous: bool,
) -> None:
    until = ready + occupancy_s
    if simultaneous:
        free_at[spot_key] = until
    else:
        for spot in surface.spots:
            free_at[spot.key] = until
    runway_next[surface.runway] = ready + gap_s
