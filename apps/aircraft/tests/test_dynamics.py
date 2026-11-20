# Verifies: AC-SRS021
# Verifies: AC-SDD003
# @relation(AC-SRS021, AC-SDD003, AC-STD012, scope=file)
"""Verifies: AC-SRS021 and AC-SDD003"""

from aircraft.dynamics import Kinematics, PointMass


def _mass() -> PointMass:
    return PointMass(
        Kinematics(0, 0, 0, 0, 0, 0),
        turn_rate_deg_s=10,
        accel_kt_s=2,
        vertical_speed_fpm=600,
    )


def test_step_is_deterministic_and_rejects_a_non_positive_dt() -> None:
    first = _mass()
    second = _mass()
    first.target_speed_kt = 20
    second.target_speed_kt = 20
    first.target_heading_deg = 90
    second.target_heading_deg = 90
    first.target_altitude_ft = 100
    second.target_altitude_ft = 100
    before = (first.state.north_ft, first.state.altitude_ft)
    with __import__("pytest").raises(ValueError):
        first.step(0)
    assert (first.state.north_ft, first.state.altitude_ft) == before
    first.step(1)
    second.step(1)
    assert first.state.ground_speed_kt == second.state.ground_speed_kt == 2
    assert first.state.heading_deg == second.state.heading_deg == 10
    assert first.state.altitude_ft == second.state.altitude_ft
    assert first.state.north_ft == second.state.north_ft
    assert first.state.east_ft == second.state.east_ft
