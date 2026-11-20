"""SFO to ORD reaches the Chicago terminal area, and the step repeats."""

from aircraft.enroute import PERFORMANCE, EnrouteLeg, Field

SFO = Field(37.619806, -122.374821, 13.0)
ORD = Field(41.9786, -87.9048, 680.0)


def snapshot(leg: EnrouteLeg) -> tuple:
    state = leg.state
    return (
        state.phase,
        round(state.lat_deg, 5),
        round(state.lon_deg, 5),
        round(state.alt_ft, 2),
        round(state.distance_nm, 3),
        round(state.distance_remaining_nm, 3),
    )


def test_sfo_ord_reaches_terminal_and_matches() -> None:
    first = EnrouteLeg(SFO, ORD, "jet")
    second = EnrouteLeg(SFO, ORD, "jet")
    first.fly_to_terminal(30.0)
    second.fly_to_terminal(30.0)
    assert first.state.distance_remaining_nm < 30.0
    assert first.state.lat_deg > 40.0
    assert first.state.lon_deg > -90.0
    assert snapshot(first) == snapshot(second)
    assert PERFORMANCE["jet"]["cruise_tas_kt"] == 450.0
