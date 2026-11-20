"""Print how many Fisk arrivals land on Wittman's open runways."""

from __future__ import annotations

import argparse
from collections import Counter

from oshkosh.field import CLOSED, FLOWS, PAVED, PAVED_FLOW, Surface, clock, surfaces
from oshkosh.sim import DEFAULT_ARRIVALS, Result, busiest_hour, fly_in, land


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Count AirVenture arrivals that land on Wittman's open runways."
    )
    parser.add_argument("--arrivals", type=int, default=DEFAULT_ARRIVALS)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--flow", default="36-27", choices=tuple(FLOWS))
    args = parser.parse_args(argv)
    if args.arrivals < 0:
        parser.error("arrivals must be zero or more")

    stream = fly_in(args.arrivals, args.seed)
    show = land(stream, flow=args.flow, simultaneous=True)
    serial = land(stream, flow=args.flow, simultaneous=False)
    paved = land(stream, runways=PAVED_FLOW[args.flow], simultaneous=False)
    active = FLOWS[args.flow]

    print("Oshkosh")
    print("Wittman Regional (KOSH), one AirVenture arrival day.")
    paved_text = ", ".join(f"{name} {length} ft" for name, length, _width in PAVED)
    print(f"Paved runways: {paved_text}.")
    print(f"Closed for the show: {', '.join(CLOSED)}.")
    print(f"Active flow {args.flow}: {', '.join(active)}.")
    print(f"{args.arrivals} aircraft flew in. Seed {args.seed}.")
    print()
    _print_policy(
        "AirVenture procedure, with a second aircraft allowed on another mark",
        show,
        active,
    )
    arrived = busiest_hour([item.at_s for item in stream])
    landed = busiest_hour([item.at_s for item in show.landings])
    print(
        f"Busiest arrival hour starts at {clock(arrived[0])} with {arrived[1]} aircraft."
    )
    print(
        f"Busiest landing hour starts at {clock(landed[0])} with {landed[1]} aircraft."
    )
    print()
    _print_policy("Same surfaces, one aircraft on a runway at a time", serial, active)
    print()
    _print_policy(
        "The two paved runways that stay open, one aircraft at a time",
        paved,
        PAVED_FLOW[args.flow],
    )
    print()
    print("Each arrival uses the earliest mark on the runway that has accepted fewer aircraft.")
    print("The gap, the occupancy, and the mix are assumptions in the oshkosh package.")
    print("The result is a model of those runway limits.")
    return 0


def _print_policy(title: str, result: Result, names: tuple[str, ...]) -> None:
    print(title)
    for line in _lines(result, surfaces(names)):
        print(line)


def _lines(result: Result, active: tuple[Surface, ...]) -> list[str]:
    tally: Counter[tuple[str, str]] = Counter(
        (item.runway, item.spot) for item in result.landings
    )
    lines = [
        f"flew in: {result.flew_in}",
        f"landed: {result.landed}",
        f"go-arounds: {result.go_arounds}",
        f"diverted: {result.diverted}",
    ]
    for surface in active:
        total = sum(tally[(surface.runway, spot.name)] for spot in surface.spots)
        if not surface.spots:
            lines.append(f"  {surface.runway}: 0, closed")
            continue
        marks = ", ".join(
            f"{spot.name} {tally[(surface.runway, spot.name)]}" for spot in surface.spots
        )
        lines.append(f"  {surface.runway}: {total} ({marks})")
    return lines


if __name__ == "__main__":
    raise SystemExit(main())
