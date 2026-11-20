"""SFO to ORD reaches the Chicago terminal area, and the step repeats."""

from aircraft.enroute import PERFORMANCE, EnrouteLeg, Field, PhysCourse

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


def test_projection_matches_repeated_steps() -> None:
    planned = EnrouteLeg(SFO, ORD, "jet")
    stepped = EnrouteLeg(SFO, ORD, "jet")
    samples = planned.project(PhysCourse(), 30.0, 8)
    assert planned.steps == 0
    for sample in samples:
        stepped.step(30.0)
        assert sample.phase == stepped.state.phase
        assert abs(sample.lat_deg - stepped.state.lat_deg) < 1e-9
        assert abs(sample.lon_deg - stepped.state.lon_deg) < 1e-9
        assert abs(sample.alt_ft - stepped.state.alt_ft) < 1e-6


def test_assigned_heading_moves_east_and_altitude_levels() -> None:
    leg = EnrouteLeg(Field(40.0, -100.0, 10000.0), Field(40.0, -90.0, 680.0), "jet")
    leg.state.alt_ft = 10000.0
    leg.state.phase = 0
    heading = PhysCourse(heading_deg=90.0, guidance=1, use_alt=1, assigned_alt_ft=10000.0)
    [moved] = leg.project(heading, 60.0, 1)
    assert moved.lon_deg > -100.0
    assert abs(moved.lat_deg - 40.0) < 0.05
    assert abs(moved.heading_deg - 90.0) < 0.01

    climb = PhysCourse(use_alt=1, assigned_alt_ft=11000.0, guidance=0)
    samples = leg.project(climb, 30.0, 3)
    assert abs(samples[0].alt_ft - 11000.0) < 1.0
    assert abs(samples[1].alt_ft - 11000.0) < 1.0
    assert abs(samples[2].alt_ft - 11000.0) < 1.0
