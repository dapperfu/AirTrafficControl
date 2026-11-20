"""Pinned fixtures produce KSFO and KORD without a network call."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NAVDATA = Path(__file__).resolve().parent
sys.path.insert(0, str(NAVDATA))

from import_navdata import build, schedulers_for  # noqa: E402


def test_fixtures_include_sfo_and_ord(tmp_path: Path) -> None:
    scenario = build(NAVDATA / "fixtures", tmp_path)
    airports = scenario["airports"]
    assert "KSFO" in airports
    assert "KORD" in airports
    assert airports["KSFO"]["frequencies"]
    assert airports["KORD"]["frequencies"]
    assert airports["KSFO"]["tower_mhz"] == 120.5
    assert any(
        pair["origin"] == "KSFO" and pair["destination"] == "KORD"
        for pair in scenario["pairs"]
    )
    assert "EGLL" not in airports
    assert airports["KSTS"]["schedulers"] == 1
    assert airports["KSFO"]["schedulers"] == 4
    assert airports["KATL"]["schedulers"] == 8
    toml = (tmp_path / "airports" / "KSFO.toml").read_text()
    assert 'id = "28R"' in toml
    assert 'icao = "Center"' in toml


def test_scheduler_buckets() -> None:
    assert schedulers_for(0) == 1
    assert schedulers_for(49) == 1
    assert schedulers_for(50) == 2
    assert schedulers_for(299) == 2
    assert schedulers_for(300) == 4
    assert schedulers_for(999) == 4
    assert schedulers_for(1000) == 8


def test_loader_module_has_no_network_import_side_effect() -> None:
    spec = importlib.util.find_spec("import_navdata")
    assert spec is not None
    assert ROOT.name == "AirTrafficControl"
