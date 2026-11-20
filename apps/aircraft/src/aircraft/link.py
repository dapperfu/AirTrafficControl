# Implements: AC-IRS002
# Implements: AC-IDD001
# Implements: AC-SSS008
# Implements: AC-OCD004
# @relation(AC-IRS002, AC-IDD001, AC-SSS008, AC-OCD004, scope=file)
"""In-memory phraseology port. The wire method is not selected."""

from __future__ import annotations

from dataclasses import dataclass

from aircraft.transmission import Transmission


@dataclass
class LinkEvent:
    """One port event. ``addressed`` marks a garble meant for this aircraft."""

    kind: str
    transmission: Transmission | None = None
    addressed: bool = False


class InMemoryLink:
    """Deliver transmissions to a peer in this process, or report a fault."""

    def __init__(self) -> None:
        self.up = True
        self.outbound: list[Transmission] = []
        self._blocks = 0

    def block_next(self, count: int = 1) -> None:
        self._blocks += count

    def send(self, transmission: Transmission) -> str:
        """Return ``sent``, ``blocked``, or ``down``. A blocked send is not delivered."""
        if not self.up:
            return "down"
        if self._blocks > 0:
            self._blocks -= 1
            return "blocked"
        self.outbound.append(transmission)
        return "sent"
