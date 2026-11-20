"""More than one aircraft publishes a track on the same step."""

from dataclasses import replace
from pathlib import Path

from aircraft.aircraft import Aircraft
from aircraft.config import load_config
from aircraft.enroute import Field
from aircraft.fleet import Fleet

ROOT = Path(__file__).resolve().parents[3]
FIELD = Field(40.0, -75.0, 0.0)


def test_two_aircraft_publish_distinct_tracks() -> None:
    config = load_config(ROOT / "config" / "n123ab.toml")
    other = replace(
        config,
        aircraft=replace(config.aircraft, n_number="N456CD"),
        ramp=replace(config.ramp, north_ft=400.0, east_ft=200.0),
    )
    fleet = Fleet([Aircraft(config), Aircraft(other)])
    fleet.step(1.0)
    tracks = fleet.tracks(FIELD, 1.0)
    assert len(tracks) == 2
    assert {row["id"] for row in tracks} == {"N123AB", "N456CD"}
    assert tracks[0]["lat"] != tracks[1]["lat"] or tracks[0]["lon"] != tracks[1]["lon"]
