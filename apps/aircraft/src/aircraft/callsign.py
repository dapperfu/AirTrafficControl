# Implements: AC-SRS002
# Implements: AC-SSS003
# @relation(AC-SRS002, AC-SSS003, scope=file)
"""Spoken form of one civil N-number."""

from __future__ import annotations

import re

_DIGIT = {
    "0": "zero",
    "1": "one",
    "2": "two",
    "3": "three",
    "4": "four",
    "5": "five",
    "6": "six",
    "7": "seven",
    "8": "eight",
    "9": "niner",
}
_LETTER = {
    "A": "alpha",
    "B": "bravo",
    "C": "charlie",
    "D": "delta",
    "E": "echo",
    "F": "foxtrot",
    "G": "golf",
    "H": "hotel",
    "J": "juliett",
    "K": "kilo",
    "L": "lima",
    "M": "mike",
    "N": "november",
    "P": "papa",
    "Q": "quebec",
    "R": "romeo",
    "S": "sierra",
    "T": "tango",
    "U": "uniform",
    "V": "victor",
    "W": "whiskey",
    "X": "x-ray",
    "Y": "yankee",
    "Z": "zulu",
}
_SPOKEN_DIGIT = {word: digit for digit, word in _DIGIT.items()}
_SPOKEN_LETTER = {word: letter for letter, word in _LETTER.items()}

# 1-5 digits, or 1-4 digits and one letter, or 1-3 digits and two letters.
# The first digit is never zero. I and O are not registration letters.
_NNUMBER = re.compile(
    r"^N(?:"
    r"[1-9][0-9]{0,4}"
    r"|[1-9][0-9]{0,3}[A-HJ-NP-Z]"
    r"|[1-9][0-9]{0,2}[A-HJ-NP-Z]{2}"
    r")$"
)


class CallSignError(ValueError):
    """The configured registration is not a civil N-number."""


class CallSign:
    """One uppercase civil registration and its full spoken form."""

    def __init__(self, n_number: str) -> None:
        if not isinstance(n_number, str) or _NNUMBER.fullmatch(n_number) is None:
            raise CallSignError(f"invalid N-number: {n_number!r}")
        self.n_number = n_number

    @property
    def spoken(self) -> str:
        words = ["November"]
        for char in self.n_number[1:]:
            if char.isdigit():
                words.append(_DIGIT[char])
            else:
                words.append(_LETTER[char])
        return " ".join(words)

    def __eq__(self, other: object) -> bool:
        return isinstance(other, CallSign) and other.n_number == self.n_number


def parse_spoken_callsign(spoken: str) -> CallSign:
    """Reverse :meth:`CallSign.spoken` into a registration."""
    words = spoken.split()
    if not words or words[0] != "November":
        raise CallSignError(spoken)
    chars = ["N"]
    for word in words[1:]:
        if word in _SPOKEN_DIGIT:
            chars.append(_SPOKEN_DIGIT[word])
        elif word in _SPOKEN_LETTER:
            chars.append(_SPOKEN_LETTER[word])
        else:
            raise CallSignError(spoken)
    return CallSign("".join(chars))
