# Verifies: AC-OCD002
# @relation(AC-OCD002, AC-STD005, scope=file)
"""Test peer. It is not part of the aircraft product."""

from __future__ import annotations

from aircraft.aircraft import Aircraft, Phase
from aircraft.phrasebook import render
from aircraft.transmission import Kind, Role, Transmission


class ScriptedTower:
    """Answer the closed phrase set with the clearances a pattern needs."""

    def __init__(self, information: str = "A") -> None:
        self.information = information
        self.takeoff_sent = False

    def respond(self, phrase: str) -> list[Transmission]:
        tx = _parsed(phrase)
        if tx.role not in {Role.REQUEST, Role.REPORT}:
            return []
        if tx.kind is Kind.ATIS and tx.role is Role.REQUEST:
            return [_advisory(self.information)]
        if tx.kind is Kind.PATTERN:
            return [
                _clearance(Kind.RUNWAY, runway_id=tx.runway_id),
                _clearance(Kind.SEQUENCE, sequence=1, runway_id=tx.runway_id),
            ]
        if tx.kind is Kind.TAXI:
            return [_clearance(Kind.TAXI, runway_id=tx.runway_id, hold_short=True)]
        if tx.kind is Kind.READY:
            return [_clearance(Kind.LINE_UP, runway_id=tx.runway_id)]
        if tx.kind is Kind.LANDING:
            return [_clearance(Kind.LANDING, runway_id=tx.runway_id)]
        if tx.kind is Kind.OPTION:
            return [_clearance(Kind.OPTION, runway_id=tx.runway_id)]
        if tx.kind is Kind.TOUCH_AND_GO:
            return [_clearance(Kind.TOUCH_AND_GO, runway_id=tx.runway_id)]
        if tx.kind is Kind.STOP_AND_GO:
            return [_clearance(Kind.STOP_AND_GO, runway_id=tx.runway_id)]
        if tx.kind is Kind.FREQUENCY and tx.role is Role.REQUEST:
            return [
                _clearance(
                    Kind.FREQUENCY,
                    next_facility="Departure",
                    frequency_mhz=124.5,
                )
            ]
        return []

    def proactive(self, aircraft: Aircraft) -> Transmission | None:
        if aircraft.phase is Phase.LINE_UP and aircraft.lined_up and not self.takeoff_sent:
            self.takeoff_sent = True
            return _clearance(Kind.TAKEOFF, runway_id=aircraft.config.runway.id)
        return None


def _parsed(phrase: str) -> Transmission:
    from aircraft.phrasebook import parse

    return parse(phrase)


def _advisory(letter: str) -> Transmission:
    tx = Transmission(role=Role.ADVISORY, kind=Kind.INFORMATION, atis_letter=letter)
    tx.phrase = render(tx)
    return tx


def _clearance(kind: Kind, **fields: object) -> Transmission:
    tx = Transmission(role=Role.CLEARANCE, kind=kind, **fields)  # type: ignore[arg-type]
    tx.phrase = render(tx)
    return tx
