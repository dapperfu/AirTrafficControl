"""Fixture demand, shards, replay, injects, and debrief scores."""

from pathlib import Path

import pytest

from aircraft.national import (
    airline_pairs,
    demand_for,
    ga_counts,
    inject,
    record,
    replay,
    score,
    shard,
    towered_airports,
)

ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "tools" / "navdata" / "fixtures"


def test_towered_demand_shards_and_score(tmp_path: Path) -> None:
    airports = towered_airports(FIXTURES)
    assert "KSFO" in airports
    assert "KSTS" in airports
    assert "EGLL" not in airports
    assert shard(airports, "national") == sorted(airports)
    assert shard(airports, ("airport", "KSTS")) == ["KSTS"]
    assert shard(airports, ("region", "KMO")) == ["KMOD"]
    pairs = airline_pairs(FIXTURES, set(airports))
    assert ("KSFO", "KORD") in pairs
    ga = ga_counts(FIXTURES)
    assert ga["KSFO"] >= 4
    assert ga["KSTS"] == 1
    flights = demand_for("KSTS", pairs, ga)
    assert any(flight["kind"] == "ga" for flight in flights)
    assert any(flight["kind"] == "airline" for flight in flights)
    scenario = inject({"airport": "KSTS"}, "emergency", "N123AB")
    scenario = inject(scenario, "weather", {"routine": False})
    scenario = inject(scenario, "vehicle", "V1")
    scenario = inject(scenario, "nordo", "N456CD")
    scenario = inject(scenario, "deviation", "N123AB")
    assert len(scenario["injects"]) == 5
    events = [
        {"kind": "deferred", "radio_s": 2},
        {"kind": "incursion", "radio_s": 1},
        {"kind": "loss", "radio_s": 3},
    ]
    path = tmp_path / "debrief.jsonl"
    record(path, events)
    assert replay(path) == events
    totals = score(events)
    assert totals == {"losses": 1.0, "incursions": 1.0, "deferred": 1.0, "radio_s": 6.0}


def test_unknown_inject_is_rejected() -> None:
    with pytest.raises(ValueError):
        inject({}, "vector", "turn left")
