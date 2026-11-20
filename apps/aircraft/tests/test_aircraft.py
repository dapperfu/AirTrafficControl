# Verifies: AC-SRS006
# Verifies: AC-SRS007
# Verifies: AC-SRS008
# Verifies: AC-SRS009
# Verifies: AC-SRS011
# Verifies: AC-SRS012
# Verifies: AC-SRS013
# Verifies: AC-SRS015
# Verifies: AC-SRS016
# Verifies: AC-SRS022
# @relation(AC-SRS006, AC-SRS007, AC-SRS008, AC-SRS009, AC-SRS010, AC-SRS011, AC-SRS012, AC-SRS013, AC-SRS015, AC-SRS016, AC-SRS022, AC-STD006, AC-STD007, AC-STD008, AC-STD009, AC-STD010, AC-STD011, AC-STD012, scope=file)
"""Verifies the pattern clearances, readbacks, Unable, and the decision log."""

from pathlib import Path

from aircraft.aircraft import Aircraft, Phase
from aircraft.config import load_config
from aircraft.link import InMemoryLink
from aircraft.phrasebook import parse
from aircraft.transmission import Kind

EXAMPLE = Path(__file__).resolve().parents[3] / "config" / "n123ab.toml"
CALL = "November one two three alpha bravo"


def _aircraft(**replacements: object) -> Aircraft:
    config = load_config(EXAMPLE)
    return Aircraft(config, InMemoryLink())


def _until(aircraft: Aircraft, ready, limit: int = 2500) -> None:
    for _ in range(limit):
        if ready():
            return
        aircraft.step(0.5)
    raise AssertionError(f"still in {aircraft.phase} after {limit} steps")


def test_taxi_hold_short_lineup_and_takeoff_readbacks() -> None:
    aircraft = _aircraft()
    start = (aircraft.dynamics.state.north_ft, aircraft.dynamics.state.east_ft)
    taxi = parse("Taxi to runway two seven, hold short runway two seven.")
    readback = aircraft.receive(taxi)
    assert readback is not None
    assert readback.phrase == (
        "Taxi to runway two seven, hold short runway two seven, "
        "November one two three alpha bravo."
    )
    assert (aircraft.dynamics.state.north_ft, aircraft.dynamics.state.east_ft) == start
    _until(aircraft, lambda: aircraft.phase is Phase.HOLD_SHORT and aircraft.dynamics.state.ground_speed_kt == 0)
    assert aircraft.position_text() == "holding short runway two seven"
    report = aircraft.report_holding_short()
    assert report is not None
    assert report.phrase == f"Example Tower, {CALL}, holding short runway two seven."
    lineup = aircraft.receive(parse("Runway two seven, line up and wait."))
    assert lineup is not None
    assert lineup.phrase == f"Line up and wait runway two seven, {CALL}."
    _until(aircraft, lambda: aircraft.lined_up and aircraft.dynamics.state.ground_speed_kt == 0)
    assert aircraft.phase is Phase.LINE_UP
    takeoff = aircraft.receive(parse("Runway two seven, wind two seven zero at one zero, cleared for takeoff."))
    assert takeoff is not None
    assert takeoff.phrase == f"Cleared for takeoff runway two seven, {CALL}."
    assert "wind" not in takeoff.phrase
    _until(aircraft, lambda: aircraft.phase is Phase.CLIMB)
    assert abs(aircraft.dynamics.state.north_ft) < 5
    assert any(uid == "AC-SRS021" for uid, _summary in aircraft.decisions)


def test_sequence_and_frequency_do_not_change_the_maneuver() -> None:
    aircraft = _aircraft()
    aircraft.receive(parse("Taxi to runway two seven, hold short runway two seven."))
    _until(aircraft, lambda: aircraft.phase is Phase.HOLD_SHORT)
    before = (
        aircraft.phase,
        aircraft.dynamics.state.north_ft,
        aircraft.dynamics.state.east_ft,
    )
    sequence = aircraft.receive(parse("Number two, runway two seven."))
    runway = aircraft.receive(parse("Runway two seven."))
    assert sequence is not None and sequence.phrase == f"Number two, runway two seven, {CALL}."
    assert runway is not None and runway.phrase == f"Runway two seven, {CALL}."
    assert aircraft.sequence == 2
    frequency = aircraft.receive(parse("Contact Departure on one two four point five."))
    assert frequency is not None
    assert frequency.phrase == f"one two four point five, {CALL}."
    assert aircraft.facility == "Departure"
    later = aircraft.request_atis()
    assert later is not None and later.phrase.startswith("Departure, ")
    assert (
        aircraft.phase,
        aircraft.dynamics.state.north_ft,
        aircraft.dynamics.state.east_ft,
    ) == before


def test_other_call_sign_and_other_runway_are_ignored() -> None:
    aircraft = _aircraft()
    aircraft.receive(parse(f"Runway two seven, cleared for takeoff, November niner niner niner zulu zulu."))
    aircraft.receive(parse("Runway two eight, cleared to land."))
    assert aircraft.phase is Phase.RAMP
    assert aircraft.phrases == []
    assert not any(uid == "AC-SRS016" for uid, _summary in aircraft.decisions)


def test_unable_keeps_the_previous_maneuver() -> None:
    aircraft = _aircraft()
    aircraft.receive(parse("Taxi to runway two seven, hold short runway two seven."))
    _until(aircraft, lambda: aircraft.phase is Phase.HOLD_SHORT and aircraft.dynamics.state.ground_speed_kt == 0)
    aircraft.receive(parse("Runway two seven, line up and wait."))
    _until(aircraft, lambda: aircraft.lined_up)
    from dataclasses import replace

    aircraft.config = replace(
        aircraft.config,
        runway=replace(aircraft.config.runway, length_ft=800),
    )
    phrase = aircraft.receive(parse("Runway two seven, cleared for takeoff."))
    assert phrase is not None
    assert phrase.phrase == f"Unable cleared for takeoff runway two seven, {CALL}."
    assert aircraft.phase is Phase.LINE_UP
    assert aircraft.dynamics.state.ground_speed_kt == 0


def test_option_touch_and_go_and_low_approach() -> None:
    aircraft = _fly_airborne()
    aircraft.receive(parse("Cleared touch and go runway two seven."))
    seen_roll = False
    lowest = aircraft.dynamics.state.altitude_ft
    for _ in range(3000):
        aircraft.step(0.5)
        lowest = min(lowest, aircraft.dynamics.state.altitude_ft)
        if aircraft.phase is Phase.TAKEOFF_ROLL and lowest < 80:
            seen_roll = True
            break
    assert seen_roll
    assert lowest < 80

    stopped = _fly_airborne()
    stopped.receive(parse("Cleared stop and go runway two seven."))
    saw_rollout = False
    slowest = 999.0
    rolling_again = False
    for _ in range(4000):
        stopped.step(0.5)
        if stopped.phase is Phase.ROLLOUT:
            saw_rollout = True
            slowest = min(slowest, stopped.dynamics.state.ground_speed_kt)
        if (
            saw_rollout
            and stopped.phase is Phase.TAKEOFF_ROLL
            and stopped.dynamics.state.ground_speed_kt > 10
        ):
            rolling_again = True
            break
    assert saw_rollout and slowest < 5 and rolling_again

    from dataclasses import replace

    low = _fly_airborne()
    low.config = replace(low.config, option=replace(low.config.option, choice="low_approach"))
    low.receive(parse("Cleared for the option runway two seven."))
    floor = 1000.0
    climbed = False
    for _ in range(4000):
        low.step(0.5)
        if low.phase in {Phase.FINAL, Phase.GO_AROUND, Phase.CROSSWIND, Phase.BASE, Phase.DOWNWIND}:
            floor = min(floor, low.dynamics.state.altitude_ft)
        if low.phase is Phase.GO_AROUND and low.dynamics.state.altitude_ft > 400:
            climbed = True
            break
    assert floor >= 150
    assert climbed


def test_go_around_uses_pilot_wording_and_climbs() -> None:
    aircraft = _fly_airborne()
    sent = aircraft.request_go_around()
    assert sent is not None
    assert sent.phrase == f"Example Tower, {CALL}, going around."
    assert aircraft.phase is Phase.GO_AROUND
    altitude = aircraft.dynamics.state.altitude_ft
    for _ in range(10):
        aircraft.step(0.5)
    assert aircraft.dynamics.state.altitude_ft >= altitude
    other = _fly_airborne()
    readback = other.receive(parse("Go around."))
    assert readback is not None
    assert readback.phrase == f"Going around, {CALL}."
    assert other.phase is Phase.GO_AROUND


def _fly_airborne() -> Aircraft:
    aircraft = _aircraft()
    aircraft.receive(parse("Taxi to runway two seven, hold short runway two seven."))
    _until(aircraft, lambda: aircraft.phase is Phase.HOLD_SHORT and aircraft.dynamics.state.ground_speed_kt == 0)
    aircraft.receive(parse("Runway two seven, line up and wait."))
    _until(aircraft, lambda: aircraft.lined_up)
    aircraft.receive(parse("Runway two seven, cleared for takeoff."))
    _until(aircraft, lambda: aircraft.phase is Phase.DOWNWIND)
    return aircraft
