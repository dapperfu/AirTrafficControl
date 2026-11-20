"""Pattern position becomes the enroute origin with no jump."""

from aircraft.continuity import continue_leg, local_to_geo, truth_track
from aircraft.dynamics import Kinematics
from aircraft.enroute import Field

FIELD = Field(37.619806, -122.374821, 13.0)
DEST = Field(41.9786, -87.9048, 680.0)


def test_pattern_hands_off_without_a_position_jump() -> None:
    state = Kinematics(
        north_ft=2500.0,
        east_ft=-800.0,
        altitude_ft=1400.0,
        heading_deg=270.0,
        ground_speed_kt=90.0,
        vertical_speed_fpm=500.0,
    )
    latitude, longitude = local_to_geo(FIELD, state.north_ft, state.east_ft)
    leg = continue_leg(FIELD, state, DEST, "piston")
    assert leg.state.lat_deg == latitude
    assert leg.state.lon_deg == longitude
    assert leg.state.alt_ft == state.altitude_ft
    assert leg.state.heading_deg == state.heading_deg
    before = (leg.state.lat_deg, leg.state.lon_deg, leg.state.alt_ft)
    leg.step(1.0)
    assert (leg.state.lat_deg, leg.state.lon_deg) != (FIELD.latitude, FIELD.longitude)
    assert leg.state.alt_ft != before[2] or leg.state.lat_deg != before[0]


def test_truth_track_names_the_aircraft() -> None:
    track = truth_track("N123AB", 5.0, 37.6, -122.3, 1400.0, 10.0, 0.0, "small", "climb")
    assert track["id"] == "N123AB"
    assert track["time_s"] == 5.0
    assert track["phase"] == "climb"
