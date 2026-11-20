# Implements: AC-SRS024
# @relation(AC-SRS024, scope=file)
"""UDP phrase path from one aircraft to the tower radio.

A stand-by reply is not a clearance. A clearance is applied only when the
reply is a guard phrase this module can hand to the aircraft.
"""

from __future__ import annotations

import socket

from aircraft.aircraft import Aircraft
from aircraft.phrasebook import render
from aircraft.transmission import Kind, Role, Transmission


def mhz_port(mhz: float) -> int:
    return 20000 + round((mhz - 118.0) / 0.025)


class TowerRadio:
    """One datagram socket aimed at a tower frequency."""

    def __init__(self, host: str, port: int) -> None:
        self.peer = (host, port)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind((host, 0))

    def exchange(
        self,
        flight: str,
        chapter: str,
        callsign: str,
        english: str,
        timeout: float = 3.0,
    ) -> str:
        packet = f"flight {flight} {chapter} {callsign}\n{english}\n".encode()
        self.socket.sendto(packet, self.peer)
        self.socket.settimeout(timeout)
        data, _address = self.socket.recvfrom(65535)
        return data.decode()

    def publish_track(
        self,
        ident: str,
        time_s: float,
        x_ft: float,
        y_ft: float,
        alt_ft: float,
        vx_fps: float,
        vy_fps: float,
        wake: str,
        runway: str,
    ) -> None:
        line = (
            f"track {ident} {time_s} {x_ft} {y_ft} {alt_ft} "
            f"{vx_fps} {vy_fps} {wake} {runway}\n"
        )
        self.socket.sendto(line.encode(), self.peer)

    def close(self) -> None:
        self.socket.close()


def reply_phrase(packet: str) -> str:
    lines = [line.strip() for line in packet.splitlines() if line.strip()]
    if len(lines) >= 2:
        return lines[-1]
    return packet.strip()


def is_standby(packet: str) -> bool:
    return reply_phrase(packet).lower().startswith("stand by")


def apply_reply(aircraft: Aircraft, packet: str) -> Transmission | None:
    """Apply a guard clearance. A stand-by or unknown sentence changes nothing."""
    if is_standby(packet) or reply_phrase(packet).lower().startswith("unable"):
        return None
    clearance = _clearance_for(reply_phrase(packet), aircraft.config.runway.id)
    if clearance is None:
        return None
    return aircraft.receive(clearance)


def _clearance_for(phrase: str, runway_id: str) -> Transmission | None:
    lower = phrase.lower()
    if "cleared for takeoff" in lower:
        kind = Kind.TAKEOFF
        hold = False
    elif "cleared to land" in lower:
        kind = Kind.LANDING
        hold = False
    elif "line up and wait" in lower:
        kind = Kind.LINE_UP
        hold = False
    elif "hold short" in lower:
        kind = Kind.HOLD_SHORT
        hold = True
    elif lower.startswith("runway ") and "for departure" in lower:
        kind = Kind.TAXI
        hold = True
    elif lower.startswith("runway ") and "for arrival" in lower:
        kind = Kind.RUNWAY
        hold = False
    else:
        return None
    tx = Transmission(
        role=Role.CLEARANCE,
        kind=kind,
        runway_id=runway_id,
        hold_short=hold,
    )
    tx.phrase = render(tx)
    return tx
