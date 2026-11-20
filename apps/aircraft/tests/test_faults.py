# Verifies: AC-SRS016
# Verifies: AC-SRS017
# Verifies: AC-SRS018
# Verifies: AC-SRS019
# Verifies: AC-SRS020
# @relation(AC-SRS016, AC-SRS017, AC-SRS018, AC-SRS019, AC-SRS020, AC-STD012, scope=file)
"""Verifies: AC-SRS016, AC-SRS017, AC-SRS018, AC-SRS019, and AC-SRS020"""

from pathlib import Path

from aircraft.aircraft import Aircraft, Phase
from aircraft.config import load_config
from aircraft.link import InMemoryLink, LinkEvent

EXAMPLE = Path(__file__).resolve().parents[3] / "config" / "n123ab.toml"
CALL = "November one two three alpha bravo"


def _aircraft() -> Aircraft:
    return Aircraft(load_config(EXAMPLE), InMemoryLink())


def test_lost_link_sends_nothing_and_keeps_the_maneuver() -> None:
    aircraft = _aircraft()
    aircraft.receive(parse_taxi())
    for _ in range(5):
        aircraft.step(0.5)
    moved = aircraft.dynamics.state.east_ft
    spoken = list(aircraft.phrases)
    aircraft.receive(LinkEvent(kind="down"))
    assert aircraft.request_taxi() is None
    assert aircraft.declare_emergency("mayday", "engine failure", "landing runway two seven") is None
    assert aircraft.phrases == spoken
    for _ in range(5):
        aircraft.step(0.5)
    assert aircraft.dynamics.state.east_ft != moved
    assert aircraft.phase is Phase.TAXI
    assert any(uid == "AC-SRS017" for uid, _summary in aircraft.decisions)
    assert not any(uid == "AC-SRS020" for uid, _summary in aircraft.decisions)


def test_addressed_garble_is_not_accepted() -> None:
    aircraft = _aircraft()
    aircraft.receive(LinkEvent(kind="garbled", addressed=True))
    aircraft.receive(LinkEvent(kind="garbled", addressed=False))
    assert aircraft.phrases == [f"Say again, {CALL}."]
    assert aircraft.phase is Phase.RAMP
    assert any(uid == "AC-SRS018" for uid, _summary in aircraft.decisions)


def test_blocked_transmission_is_repeated_once() -> None:
    aircraft = _aircraft()
    aircraft.link.block_next(1)
    sent = aircraft.request_atis()
    assert sent is not None
    assert [item.phrase for item in aircraft.link.outbound] == [sent.phrase]
    assert any(uid == "AC-SRS019" for uid, _summary in aircraft.decisions)

    aircraft.link.block_next(2)
    before = len(aircraft.link.outbound)
    assert aircraft.request_taxi() is None
    assert len(aircraft.link.outbound) == before


def test_emergency_declaration_does_not_change_the_maneuver() -> None:
    aircraft = _aircraft()
    phrase = aircraft.declare_emergency("mayday", "engine failure", "landing runway two seven")
    pan = aircraft.declare_emergency("pan_pan", "low fuel", "landing runway two seven")
    assert phrase is not None
    assert phrase.phrase == (
        "Mayday, Mayday, Mayday, Example Tower, "
        f"{CALL}, engine failure, at the ramp, landing runway two seven."
    )
    assert pan is not None and pan.phrase.startswith("Pan-Pan, Pan-Pan, Pan-Pan,")
    assert aircraft.phase is Phase.RAMP
    assert aircraft.dynamics.state.ground_speed_kt == 0
    assert any(uid == "AC-SRS020" for uid, _summary in aircraft.decisions)


def parse_taxi():
    from aircraft.phrasebook import parse

    return parse("Taxi to runway two seven, hold short runway two seven.")
