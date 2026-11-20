# Verifies: AC-SRS001
# Verifies: AC-IRS003
# Verifies: AC-DBDD001
# @relation(AC-SRS001, AC-IRS003, AC-DBDD001, AC-STD001, scope=file)
"""Verifies: AC-SRS001 and AC-IRS003"""

from pathlib import Path

import pytest

from aircraft.config import ConfigError, load_config

EXAMPLE = Path(__file__).resolve().parents[3] / "config" / "n123ab.toml"


def test_example_loads() -> None:
    config = load_config(EXAMPLE)
    assert config.aircraft.n_number == "N123AB"
    assert config.runway.id == "27"
    assert config.option.choice == "full_stop"


def test_invalid_files_do_not_fly(tmp_path: Path) -> None:
    empty = tmp_path / "empty.toml"
    empty.write_text("", encoding="utf-8")
    missing_number = tmp_path / "missing.toml"
    text = EXAMPLE.read_text(encoding="utf-8").replace('n_number = "N123AB"\n', "")
    missing_number.write_text(text, encoding="utf-8")
    bad_pattern = tmp_path / "pattern.toml"
    bad_pattern.write_text(
        EXAMPLE.read_text(encoding="utf-8").replace('pattern = "left"', 'pattern = "sideways"'),
        encoding="utf-8",
    )
    bad_frequency = tmp_path / "freq.toml"
    bad_frequency.write_text(
        EXAMPLE.read_text(encoding="utf-8").replace("124.5", "100.0"),
        encoding="utf-8",
    )
    for path in (empty, missing_number, bad_pattern, bad_frequency, tmp_path / "absent.toml"):
        with pytest.raises(ConfigError):
            load_config(path)
