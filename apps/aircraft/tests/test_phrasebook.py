# Verifies: AC-SRS003
# Verifies: AC-SRS004
# Verifies: AC-SRS014
# Verifies: AC-SDD004
# @relation(AC-SRS003, AC-SRS004, AC-SRS014, AC-SDD004, AC-STD003, AC-STD004, AC-STD009, scope=file)
"""Verifies: AC-SRS003, AC-SRS004, and AC-SDD004"""

from aircraft.phrasebook import parse, render, speak_altitude, speak_frequency, speak_runway
from aircraft.transmission import Kind, Role, Transmission

CALL = "November one two three alpha bravo"


def _request(**fields: object) -> Transmission:
    tx = Transmission(role=Role.REQUEST, call_sign=CALL, n_number="N123AB", facility="Example Tower", **fields)  # type: ignore[arg-type]
    tx.phrase = render(tx)
    return tx


def test_runway_and_frequency_speech() -> None:
    assert speak_runway("27") == "two seven"
    assert speak_runway("09") == "zero niner"
    assert speak_runway("27L") == "two seven left"
    assert speak_frequency(124.5) == "one two four point five"
    assert speak_altitude(1000) == "one thousand"
    assert speak_altitude(1500) == "one thousand five hundred"


def test_request_order_round_trip() -> None:
    samples = [
        _request(kind=Kind.ATIS),
        _request(kind=Kind.TAXI, runway_id="27"),
        _request(
            kind=Kind.PATTERN,
            position="at the ramp",
            runway_id="27",
            pattern_side="left",
            atis_letter="A",
        ),
        _request(kind=Kind.LANDING, position="final runway two seven at one thousand", runway_id="27"),
    ]
    assert samples[0].phrase == "Example Tower, November one two three alpha bravo, request ATIS."
    assert samples[2].phrase == (
        "Example Tower, November one two three alpha bravo, at the ramp, "
        "with information alpha, request left traffic runway two seven."
    )
    for tx in samples:
        parsed = parse(tx.phrase)
        assert parsed.kind is tx.kind
        assert parsed.n_number == "N123AB"
        assert parsed.phrase == tx.phrase


def test_readback_puts_call_sign_last_and_drops_wind() -> None:
    clearance = (
        "Runway two seven, wind two seven zero at one zero, "
        "altimeter two niner niner two, cleared for takeoff."
    )
    parsed = parse(clearance)
    assert parsed.kind is Kind.TAKEOFF
    assert parsed.runway_id == "27"
    readback = Transmission(
        role=Role.READBACK,
        kind=Kind.TAKEOFF,
        runway_id="27",
        call_sign=CALL,
        n_number="N123AB",
    )
    phrase = render(readback)
    assert phrase == "Cleared for takeoff runway two seven, November one two three alpha bravo."
    assert "wind" not in phrase
    assert "altimeter" not in phrase
    assert parse(phrase).kind is Kind.TAKEOFF


def test_position_rounding() -> None:
    from aircraft.phrasebook import describe_position, speak_distance

    assert speak_distance(0, 50) == "at the field"
    assert speak_distance(0, 2000) == "less than one mile"
    assert (
        describe_position(
            phase="climb",
            north_ft=0,
            east_ft=0,
            altitude_ft=1000,
            runway_id="27",
            pattern="left",
        )
        == "upwind runway two seven at one thousand"
    )
    assert (
        describe_position(
            phase="downwind",
            north_ft=-100,
            east_ft=0,
            altitude_ft=1500,
            runway_id="27",
            pattern="left",
        )
        == "left downwind runway two seven at one thousand five hundred"
    )
    assert (
        describe_position(
            phase="enroute",
            north_ft=0,
            east_ft=60761.2,
            altitude_ft=1000,
            runway_id="27",
            pattern="left",
        )
        == "one zero miles east at one thousand"
    )


def test_go_around_and_emergency_forms() -> None:
    assert parse("Go around.").kind is Kind.GO_AROUND
    readback = render(
        Transmission(role=Role.READBACK, kind=Kind.GO_AROUND, call_sign=CALL, n_number="N123AB")
    )
    assert readback == "Going around, November one two three alpha bravo."
    emergency = render(
        Transmission(
            role=Role.EMERGENCY,
            kind=Kind.MAYDAY,
            facility="Example Tower",
            call_sign=CALL,
            n_number="N123AB",
            nature="engine failure",
            position="at the ramp",
            intention="landing runway two seven",
        )
    )
    assert emergency.startswith("Mayday, Mayday, Mayday, Example Tower, November one two three alpha bravo,")
    parsed = parse(emergency)
    assert parsed.kind is Kind.MAYDAY
    assert parsed.nature == "engine failure"
    assert parsed.intention == "landing runway two seven"
