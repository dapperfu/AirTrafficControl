"""The compose file has one service per scenario airport and the scheduler bucket."""

from __future__ import annotations

import sys
from pathlib import Path

NAVDATA = Path(__file__).resolve().parents[1] / "navdata"
TRAFFIC = Path(__file__).resolve().parent
sys.path.insert(0, str(NAVDATA))
sys.path.insert(0, str(TRAFFIC))

from compose import write_compose  # noqa: E402
from import_navdata import build  # noqa: E402


def test_compose_lists_every_airport_and_bucket(tmp_path: Path) -> None:
    scenario = build(NAVDATA / "fixtures", tmp_path)
    compose = tmp_path / "docker-compose.yml"
    write_compose(scenario, compose)
    text = compose.read_text()
    assert "enroute:" in text
    assert 'SCHEDULERS: "1"' in text
    for icao, airport in scenario["airports"].items():
        assert f"airport-{icao.lower()}:" in text
        assert f'SCHEDULERS: "{airport["schedulers"]}"' in text
    assert "traffic:" in text
    assert '"max"' in text
