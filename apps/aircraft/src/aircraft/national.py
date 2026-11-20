# Implements: SRS024
# @relation(SRS024, scope=file)
"""Airline and general-aviation demand, shards, record, replay, injects, and scores.

Fixtures only. This module does not open a live NAS connection and does not
issue a clearance. The separation guard remains the clearance authority.
"""

from __future__ import annotations

import csv
import json
from pathlib import Path


def towered_airports(fixture_dir: Path) -> list[str]:
    """US airports in the fixture that publish a tower frequency."""
    towered = set()
    with (fixture_dir / "airport-frequencies.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            ident = row["airport_ident"]
            if row["type"] == "TWR" and ident.startswith("K"):
                towered.add(ident)
    return sorted(towered)


def airline_pairs(fixture_dir: Path, towered: set[str]) -> list[tuple[str, str]]:
    pairs = []
    with (fixture_dir / "t100.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            origin = "K" + row["ORIGIN"] if not row["ORIGIN"].startswith("K") else row["ORIGIN"]
            dest = "K" + row["DEST"] if not row["DEST"].startswith("K") else row["DEST"]
            if origin in towered and dest in towered:
                pairs.append((origin, dest))
    return pairs


def ga_counts(fixture_dir: Path) -> dict[str, int]:
    """Scale a public annual count down to a training-day handful."""
    counts = {}
    with (fixture_dir / "operations.csv").open(newline="") as handle:
        for row in csv.DictReader(handle):
            annual = int(row["annual_operations"])
            counts[row["icao"]] = max(1, annual // 100000)
    return counts


def demand_for(airport: str, pairs: list[tuple[str, str]], ga: dict[str, int]) -> list[dict[str, object]]:
    flights: list[dict[str, object]] = []
    for origin, dest in pairs:
        if origin == airport or dest == airport:
            flights.append(
                {"kind": "airline", "airport": airport, "origin": origin, "dest": dest}
            )
    for _index in range(ga.get(airport, 0)):
        flights.append({"kind": "ga", "airport": airport})
    return flights


def shard(airports: list[str], spec: str | tuple[str, str]) -> list[str]:
    if spec == "national":
        return sorted(airports)
    kind, value = spec
    if kind == "region":
        return sorted(airport for airport in airports if airport.startswith(value))
    if kind == "airport":
        return [value] if value in airports else []
    raise ValueError(kind)


def record(path: Path, events: list[dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as handle:
        for event in events:
            handle.write(json.dumps(event, sort_keys=True) + "\n")


def replay(path: Path) -> list[dict[str, object]]:
    events = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                events.append(json.loads(line))
    return events


def inject(scenario: dict[str, object], kind: str, payload: object) -> dict[str, object]:
    if kind not in {"emergency", "nordo", "vehicle", "deviation", "weather"}:
        raise ValueError(kind)
    events = list(scenario.get("injects", []))
    events.append({"kind": kind, "payload": payload})
    scenario["injects"] = events
    return scenario


def score(events: list[dict[str, object]]) -> dict[str, float]:
    return {
        "losses": float(sum(1 for event in events if event.get("kind") == "loss")),
        "incursions": float(sum(1 for event in events if event.get("kind") == "incursion")),
        "deferred": float(sum(1 for event in events if event.get("kind") == "deferred")),
        "radio_s": float(sum(float(event.get("radio_s", 0)) for event in events)),
    }
