# Verifies: AC-SRS002
# @relation(AC-SRS002, AC-STD002, scope=file)
"""Verifies: AC-SRS002"""

from aircraft.callsign import CallSign, CallSignError, parse_spoken_callsign
import pytest


def test_full_spoken_form() -> None:
    sign = CallSign("N123AB")
    assert sign.spoken == "November one two three alpha bravo"
    assert parse_spoken_callsign(sign.spoken).n_number == "N123AB"


def test_niner_and_zero() -> None:
    assert CallSign("N90Z").spoken == "November niner zero zulu"


def test_rejects_leading_zero_and_forbidden_letters() -> None:
    with pytest.raises(CallSignError):
        CallSign("N0123")
    with pytest.raises(CallSignError):
        CallSign("N123I")
    with pytest.raises(CallSignError):
        CallSign("n123ab")
