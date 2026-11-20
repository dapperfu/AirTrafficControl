# Verifies: AC-OCD001
# Verifies: AC-SUM001
# Verifies: AC-SRS005
# @relation(AC-OCD001, AC-SUM001, AC-SRS005, AC-SRS010, AC-STD005, AC-STD008, scope=file)
"""Verifies: AC-OCD001 and AC-SUM001"""

from pathlib import Path

from aircraft.aircraft import Aircraft
from aircraft.config import load_config
from aircraft.link import InMemoryLink
from aircraft.mission import PatternMission
from aircraft.phrasebook import parse
from scripted_tower import ScriptedTower

EXAMPLE = Path(__file__).resolve().parents[3] / "config" / "n123ab.toml"


def test_pattern_mission_reaches_the_new_facility() -> None:
    aircraft = Aircraft(load_config(EXAMPLE), InMemoryLink())
    mission = PatternMission(aircraft)
    tower = ScriptedTower()
    for _ in range(4000):
        mission.tick(0.5)
        proactive = tower.proactive(aircraft)
        if proactive is not None:
            aircraft.receive(proactive)
        while aircraft.link.outbound:
            phrase = aircraft.link.outbound.pop(0)
            for reply in tower.respond(phrase.phrase):
                aircraft.receive(reply)
        if mission.done:
            break
    assert mission.done
    assert aircraft.facility == "Departure"
    text = " ".join(aircraft.phrases)
    assert "request ATIS" in text
    assert "request taxi to runway two seven" in text
    assert "Cleared for takeoff runway two seven" in text
    assert "request landing runway two seven" in text
    assert "Cleared to land runway two seven" in text
    assert "one two four point five" in text
    assert any(uid == "AC-SRS022" or uid.startswith("AC-SRS") for uid, _summary in aircraft.decisions)
    assert parse(aircraft.phrases[0]).kind.name == "ATIS"
