# Implements: AC-SRS003
# Implements: AC-SRS004
# Implements: AC-SRS014
# Implements: AC-SDD004
# Implements: AC-SSS002
# Implements: AC-OCD002
# Implements: AC-IRS004
# @relation(AC-SRS003, AC-SRS004, AC-SRS014, AC-SDD004, AC-SSS002, AC-OCD002, AC-IRS004, scope=file)
"""Closed FAA pattern phrase set. Render and parse are inverses for this set."""

from __future__ import annotations

import math
import re

from aircraft.callsign import CallSign, parse_spoken_callsign
from aircraft.transmission import Kind, Role, Transmission

_WORD = (
    "zero",
    "one",
    "two",
    "three",
    "four",
    "five",
    "six",
    "seven",
    "eight",
    "niner",
)
_DIGIT_FROM_WORD = {word: str(index) for index, word in enumerate(_WORD)}
_DIGIT_FROM_WORD["niner"] = "9"
_PHONETIC = {
    "A": "alpha",
    "B": "bravo",
    "C": "charlie",
    "D": "delta",
    "E": "echo",
    "F": "foxtrot",
    "G": "golf",
    "H": "hotel",
    "I": "india",
    "J": "juliett",
    "K": "kilo",
    "L": "lima",
    "M": "mike",
    "N": "november",
    "O": "oscar",
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
_LETTER_FROM_PHONETIC = {word: letter for letter, word in _PHONETIC.items()}
_SIDE_FROM_SUFFIX = {"L": "left", "R": "right", "C": "center"}
_SUFFIX_FROM_SIDE = {side: suffix for suffix, side in _SIDE_FROM_SUFFIX.items()}
_DIGIT_WORDS = "|".join(_WORD)
_RUNWAY_RE = re.compile(
    rf"\b((?:{_DIGIT_WORDS}) (?:{_DIGIT_WORDS})(?: left| right| center)?)\b"
)
_WIND_RE = re.compile(
    rf",?\s*wind\s+(?:(?:{_DIGIT_WORDS})\s+){{3}}at\s+(?:(?:{_DIGIT_WORDS})\s*){{1,3}}"
)
_ALTIMETER_RE = re.compile(
    rf",?\s*altimeter\s+(?:(?:{_DIGIT_WORDS})\s*){{4}}"
)
_NM_FT = 6076.12


class PhraseError(ValueError):
    """The text is outside the closed phrase set."""


def speak_runway(runway_id: str) -> str:
    match = re.fullmatch(r"(\d{2})([LCR])?", runway_id)
    if match is None:
        raise PhraseError(runway_id)
    words = " ".join(_WORD[int(char)] for char in match.group(1))
    suffix = match.group(2)
    if suffix:
        return f"{words} {_SIDE_FROM_SUFFIX[suffix]}"
    return words


def parse_runway_words(words: str) -> str:
    match = _RUNWAY_RE.fullmatch(words.strip())
    if match is None:
        raise PhraseError(words)
    parts = match.group(1).split()
    digits = _DIGIT_FROM_WORD[parts[0]] + _DIGIT_FROM_WORD[parts[1]]
    if len(parts) == 3:
        return digits + _SUFFIX_FROM_SIDE[parts[2]]
    return digits


def speak_frequency(mhz: float) -> str:
    text = f"{mhz:.3f}".rstrip("0").rstrip(".")
    whole, _, frac = text.partition(".")
    words = [_WORD[int(char)] for char in whole]
    if frac:
        words.append("point")
        words.extend(_WORD[int(char)] for char in frac)
    return " ".join(words)


def parse_frequency_words(words: str) -> float:
    whole, _, frac = words.strip().partition(" point ")
    if not frac or not whole:
        raise PhraseError(words)
    try:
        left = "".join(_DIGIT_FROM_WORD[part] for part in whole.split())
        right = "".join(_DIGIT_FROM_WORD[part] for part in frac.split())
    except KeyError as exc:
        raise PhraseError(words) from exc
    return float(f"{left}.{right}")


def speak_altitude(feet: float) -> str:
    rounded = int(round(feet / 100.0)) * 100
    if rounded <= 0:
        return "zero"
    thousands, remainder = divmod(rounded, 1000)
    hundreds = remainder // 100
    parts: list[str] = []
    if thousands:
        parts.append(f"{_small(thousands)} thousand")
    if hundreds:
        parts.append(f"{_WORD[hundreds]} hundred")
    return " ".join(parts)


def speak_distance(north_ft: float, east_ft: float) -> str:
    feet = math.hypot(north_ft, east_ft)
    if feet < 100:
        return "at the field"
    rounded = int(round(feet / _NM_FT))
    if rounded <= 0:
        return "less than one mile"
    if rounded == 1:
        return "one mile"
    digits = " ".join(_WORD[int(char)] for char in str(rounded))
    return f"{digits} miles"


def compass(north_ft: float, east_ft: float) -> str:
    names = (
        "north",
        "northeast",
        "east",
        "southeast",
        "south",
        "southwest",
        "west",
        "northwest",
    )
    degrees = math.degrees(math.atan2(east_ft, north_ft)) % 360
    return names[int((degrees + 22.5) // 45) % 8]


def describe_position(
    *,
    phase: str,
    north_ft: float,
    east_ft: float,
    altitude_ft: float,
    runway_id: str,
    pattern: str,
) -> str:
    """Position clause used in requests, reports, and emergency calls."""
    runway = speak_runway(runway_id)
    if phase == "ramp":
        return "at the ramp"
    if phase == "taxi":
        return f"taxiing to runway {runway}"
    if phase == "hold_short":
        return f"holding short runway {runway}"
    if phase == "line_up":
        return f"line up and wait runway {runway}"
    if phase in {"takeoff_roll", "rollout"}:
        return f"on runway {runway}"
    if phase == "stopped":
        return f"stopped on runway {runway}"
    altitude = speak_altitude(altitude_ft)
    leg = _pattern_leg(phase, pattern, runway, altitude)
    if leg is not None:
        return leg
    place = speak_distance(north_ft, east_ft)
    if place == "at the field":
        return f"at the field at {altitude}"
    return f"{place} {compass(north_ft, east_ft)} at {altitude}"


def render(tx: Transmission) -> str:
    """AIM order: requests put the facility and call sign first; readbacks put the call sign last."""
    if tx.role is Role.EMERGENCY:
        word = "Mayday" if tx.kind is Kind.MAYDAY else "Pan-Pan"
        phrase = (
            f"{word}, {word}, {word}, {tx.facility}, {tx.call_sign}, "
            f"{tx.nature}, {tx.position}, {tx.intention}."
        )
        return _normalize(phrase)
    if tx.role is Role.QUERY and tx.kind is Kind.SAY_AGAIN:
        return _normalize(f"Say again, {tx.call_sign}.")
    if tx.role is Role.READBACK and tx.kind is Kind.UNABLE:
        return _normalize(f"Unable {tx.position}, {tx.call_sign}.")
    if tx.role is Role.READBACK:
        return _normalize(f"{_operative(tx)}, {tx.call_sign}.")
    if tx.kind is Kind.POSITION:
        return _normalize(f"{tx.facility}, {tx.call_sign}, {tx.position}.")
    if tx.role in {Role.REQUEST, Role.REPORT}:
        message = _request_message(tx)
        if tx.position:
            return _normalize(
                f"{tx.facility}, {tx.call_sign}, {tx.position}, {message}."
            )
        return _normalize(f"{tx.facility}, {tx.call_sign}, {message}.")
    if tx.role is Role.ADVISORY and tx.kind is Kind.INFORMATION:
        return _normalize(f"Information {_PHONETIC[tx.atis_letter or '']}.")
    if tx.role is Role.CLEARANCE:
        return _normalize(f"{_clearance_sentence(tx)}.")
    raise PhraseError(f"cannot render {tx.role} {tx.kind}")


def parse(text: str) -> Transmission:
    """Parse one phrase from this closed set. Wind and altimeter are discarded."""
    raw = _normalize(text)
    body = raw[:-1]
    body = _WIND_RE.sub("", body)
    body = _ALTIMETER_RE.sub("", body)
    body = " ".join(body.replace(" ,", ",").split()).strip(" ,")
    if body.startswith("Mayday, Mayday, Mayday, "):
        return _parse_emergency(body, Kind.MAYDAY, raw)
    if body.startswith("Pan-Pan, Pan-Pan, Pan-Pan, "):
        return _parse_emergency(body, Kind.PAN_PAN, raw)
    if body.startswith("Say again, "):
        spoken = body.removeprefix("Say again, ")
        call = parse_spoken_callsign(spoken)
        return Transmission(
            role=Role.QUERY,
            kind=Kind.SAY_AGAIN,
            call_sign=call.spoken,
            n_number=call.n_number,
            phrase=raw,
        )
    if body.startswith("Unable "):
        left, spoken = _split_trailing_callsign(body)
        reason = left.removeprefix("Unable ").strip()
        call = parse_spoken_callsign(spoken)
        return Transmission(
            role=Role.READBACK,
            kind=Kind.UNABLE,
            call_sign=call.spoken,
            n_number=call.n_number,
            position=reason,
            phrase=raw,
        )
    if body.startswith("Information "):
        phonetic = body.removeprefix("Information ").strip()
        letter = _LETTER_FROM_PHONETIC.get(phonetic)
        if letter is None:
            raise PhraseError(text)
        return Transmission(
            role=Role.ADVISORY,
            kind=Kind.INFORMATION,
            atis_letter=letter,
            phrase=raw,
        )
    if ", November " in body:
        return _parse_with_callsign(body, raw)
    clearance = _parse_clearance_sentence(body)
    clearance.phrase = raw
    return clearance


def _parse_with_callsign(body: str, raw: str) -> Transmission:
    marker = ", November "
    index = body.find(marker)
    if index == -1:
        raise PhraseError(body)
    left = body[:index]
    spoken, message = _split_callsign_words(body[index + 2 :])
    call = parse_spoken_callsign(spoken)
    if message == "" and _looks_like_operative(left):
        tx = _parse_operative(left)
        tx.role = Role.READBACK
        tx.call_sign = call.spoken
        tx.n_number = call.n_number
        tx.phrase = raw
        return tx
    tx = _parse_request_message(message)
    tx.facility = left
    tx.call_sign = call.spoken
    tx.n_number = call.n_number
    tx.phrase = raw
    return tx


def _split_callsign_words(rest: str) -> tuple[str, str]:
    """Split 'November one two alpha, message' into the spoken call sign and the message."""
    if ", " not in rest:
        return rest, ""
    spoken, message = rest.split(", ", 1)
    parse_spoken_callsign(spoken)
    return spoken, message


def _split_trailing_callsign(body: str) -> tuple[str, str]:
    marker = ", November "
    index = body.rfind(marker)
    if index == -1:
        raise PhraseError(body)
    return body[:index], body[index + 2 :]


def _looks_like_operative(text: str) -> bool:
    try:
        _parse_operative(text)
    except PhraseError:
        return False
    return True


def _parse_request_message(message: str) -> Transmission:
    position = None
    atis_letter = None
    text = message
    if ", request " in text:
        head, tail = text.rsplit(", request ", 1)
        text = "request " + tail
        marker = ", with information "
        if marker in head:
            position, phonetic = head.split(marker)
            atis_letter = _LETTER_FROM_PHONETIC[phonetic]
        elif head.startswith("with information "):
            atis_letter = _LETTER_FROM_PHONETIC[head.removeprefix("with information ")]
        else:
            position = head
    if text == "request ATIS":
        return Transmission(role=Role.REQUEST, kind=Kind.ATIS, position=position, atis_letter=atis_letter)
    if text.startswith("request taxi to runway "):
        runway = parse_runway_words(text.removeprefix("request taxi to runway "))
        return Transmission(
            role=Role.REQUEST, kind=Kind.TAXI, position=position, runway_id=runway, atis_letter=atis_letter
        )
    if text.startswith("holding short runway ") and text.endswith(", ready for takeoff"):
        runway_words = text.removeprefix("holding short runway ").removesuffix(", ready for takeoff")
        return Transmission(
            role=Role.REQUEST,
            kind=Kind.READY,
            runway_id=parse_runway_words(runway_words),
            position=position,
        )
    if text.startswith("holding short runway "):
        return Transmission(
            role=Role.REPORT,
            kind=Kind.HOLD_SHORT,
            runway_id=parse_runway_words(text.removeprefix("holding short runway ")),
            position=position,
        )
    if text == "going around":
        return Transmission(role=Role.REQUEST, kind=Kind.GO_AROUND, position=position)
    if text == "request frequency change":
        return Transmission(role=Role.REQUEST, kind=Kind.FREQUENCY, position=position)
    if text.startswith("request the option runway "):
        return Transmission(
            role=Role.REQUEST,
            kind=Kind.OPTION,
            runway_id=parse_runway_words(text.removeprefix("request the option runway ")),
            position=position,
            atis_letter=atis_letter,
        )
    if text.startswith("request touch and go runway "):
        return Transmission(
            role=Role.REQUEST,
            kind=Kind.TOUCH_AND_GO,
            runway_id=parse_runway_words(text.removeprefix("request touch and go runway ")),
            position=position,
            atis_letter=atis_letter,
        )
    if text.startswith("request stop and go runway "):
        return Transmission(
            role=Role.REQUEST,
            kind=Kind.STOP_AND_GO,
            runway_id=parse_runway_words(text.removeprefix("request stop and go runway ")),
            position=position,
            atis_letter=atis_letter,
        )
    if text.startswith("request landing runway "):
        return Transmission(
            role=Role.REQUEST,
            kind=Kind.LANDING,
            runway_id=parse_runway_words(text.removeprefix("request landing runway ")),
            position=position,
            atis_letter=atis_letter,
        )
    for side in ("left", "right"):
        prefix = f"request {side} traffic runway "
        if text.startswith(prefix):
            return Transmission(
                role=Role.REQUEST,
                kind=Kind.PATTERN,
                runway_id=parse_runway_words(text.removeprefix(prefix)),
                position=position,
                pattern_side=side,
                atis_letter=atis_letter,
            )
    return Transmission(role=Role.REPORT, kind=Kind.POSITION, position=message, atis_letter=atis_letter)


def _parse_clearance_sentence(body: str) -> Transmission:
    tx = _parse_operative(body)
    tx.role = Role.CLEARANCE
    return tx


def _parse_operative(text: str) -> Transmission:
    if text.startswith("Taxi to runway "):
        rest = text.removeprefix("Taxi to runway ")
        hold = False
        if ", hold short runway " in rest:
            first, second = rest.split(", hold short runway ")
            if first != second:
                raise PhraseError(text)
            hold = True
            rest = first
        return Transmission(role=Role.CLEARANCE, kind=Kind.TAXI, runway_id=parse_runway_words(rest), hold_short=hold)
    if text.startswith("Hold short runway "):
        return Transmission(
            role=Role.CLEARANCE,
            kind=Kind.HOLD_SHORT,
            runway_id=parse_runway_words(text.removeprefix("Hold short runway ")),
            hold_short=True,
        )
    if text.startswith("Runway ") and text.endswith(", line up and wait"):
        runway = parse_runway_words(text.removeprefix("Runway ").removesuffix(", line up and wait"))
        return Transmission(role=Role.CLEARANCE, kind=Kind.LINE_UP, runway_id=runway)
    if text.startswith("Line up and wait runway "):
        return Transmission(
            role=Role.READBACK,
            kind=Kind.LINE_UP,
            runway_id=parse_runway_words(text.removeprefix("Line up and wait runway ")),
        )
    if text.startswith("Runway ") and text.endswith(", cleared for takeoff"):
        runway = parse_runway_words(text.removeprefix("Runway ").removesuffix(", cleared for takeoff"))
        return Transmission(role=Role.CLEARANCE, kind=Kind.TAKEOFF, runway_id=runway)
    if text.startswith("Cleared for takeoff runway "):
        return Transmission(
            role=Role.READBACK,
            kind=Kind.TAKEOFF,
            runway_id=parse_runway_words(text.removeprefix("Cleared for takeoff runway ")),
        )
    if text.startswith("Runway ") and text.endswith(", cleared to land"):
        runway = parse_runway_words(text.removeprefix("Runway ").removesuffix(", cleared to land"))
        return Transmission(role=Role.CLEARANCE, kind=Kind.LANDING, runway_id=runway)
    if text.startswith("Cleared to land runway "):
        return Transmission(
            role=Role.READBACK,
            kind=Kind.LANDING,
            runway_id=parse_runway_words(text.removeprefix("Cleared to land runway ")),
        )
    if text.startswith("Cleared for the option runway "):
        return Transmission(
            role=Role.CLEARANCE,
            kind=Kind.OPTION,
            runway_id=parse_runway_words(text.removeprefix("Cleared for the option runway ")),
        )
    if text.startswith("Cleared touch and go runway "):
        return Transmission(
            role=Role.CLEARANCE,
            kind=Kind.TOUCH_AND_GO,
            runway_id=parse_runway_words(text.removeprefix("Cleared touch and go runway ")),
        )
    if text.startswith("Cleared stop and go runway "):
        return Transmission(
            role=Role.CLEARANCE,
            kind=Kind.STOP_AND_GO,
            runway_id=parse_runway_words(text.removeprefix("Cleared stop and go runway ")),
        )
    if text == "Go around":
        return Transmission(role=Role.CLEARANCE, kind=Kind.GO_AROUND)
    if text == "Going around":
        return Transmission(role=Role.READBACK, kind=Kind.GO_AROUND)
    if text.startswith("Number "):
        return _parse_number(text)
    if text.startswith("Contact ") and " on " in text:
        facility, freq = text.removeprefix("Contact ").rsplit(" on ", 1)
        return Transmission(
            role=Role.CLEARANCE,
            kind=Kind.FREQUENCY,
            next_facility=facility,
            frequency_mhz=parse_frequency_words(freq),
        )
    if " point " in text and text.split()[0] in _WORD:
        return Transmission(
            role=Role.READBACK,
            kind=Kind.FREQUENCY,
            frequency_mhz=parse_frequency_words(text),
        )
    if text.startswith("Runway "):
        return Transmission(
            role=Role.CLEARANCE,
            kind=Kind.RUNWAY,
            runway_id=parse_runway_words(text.removeprefix("Runway ")),
        )
    raise PhraseError(text)


def _parse_number(text: str) -> Transmission:
    rest = text.removeprefix("Number ")
    runway_id = None
    if ", runway " in rest:
        number_words, runway_words = rest.split(", runway ")
        runway_id = parse_runway_words(runway_words)
    else:
        number_words = rest
    sequence = int("".join(_DIGIT_FROM_WORD[word] for word in number_words.split()))
    return Transmission(role=Role.CLEARANCE, kind=Kind.SEQUENCE, sequence=sequence, runway_id=runway_id)


def _parse_emergency(body: str, kind: Kind, raw: str) -> Transmission:
    marker = ", November "
    index = body.find(marker)
    if index == -1:
        raise PhraseError(body)
    prefix = body[:index]
    rest = body[index + len(marker) :]
    spoken_body, tail = rest.split(", ", 1)
    call = parse_spoken_callsign("November " + spoken_body)
    nature, position, intention = tail.split(", ", 2)
    word = "Mayday, Mayday, Mayday, " if kind is Kind.MAYDAY else "Pan-Pan, Pan-Pan, Pan-Pan, "
    facility = prefix.removeprefix(word)
    return Transmission(
        role=Role.EMERGENCY,
        kind=kind,
        facility=facility,
        call_sign=call.spoken,
        n_number=call.n_number,
        nature=nature,
        position=position,
        intention=intention,
        phrase=raw,
    )


def _request_message(tx: Transmission) -> str:
    runway = speak_runway(tx.runway_id) if tx.runway_id else ""
    if tx.kind is Kind.ATIS:
        return "request ATIS"
    if tx.kind is Kind.TAXI:
        return f"request taxi to runway {runway}"
    if tx.kind is Kind.READY:
        return f"holding short runway {runway}, ready for takeoff"
    if tx.kind is Kind.HOLD_SHORT:
        return f"holding short runway {runway}"
    if tx.kind is Kind.GO_AROUND:
        return "going around"
    if tx.kind is Kind.FREQUENCY:
        return "request frequency change"
    if tx.kind is Kind.OPTION:
        return f"request the option runway {runway}"
    if tx.kind is Kind.TOUCH_AND_GO:
        return f"request touch and go runway {runway}"
    if tx.kind is Kind.STOP_AND_GO:
        return f"request stop and go runway {runway}"
    if tx.kind is Kind.LANDING:
        return f"request landing runway {runway}"
    if tx.kind is Kind.PATTERN:
        lead = ""
        if tx.atis_letter:
            lead = f"with information {_PHONETIC[tx.atis_letter]}, "
        return f"{lead}request {tx.pattern_side} traffic runway {runway}"
    if tx.kind is Kind.POSITION:
        return tx.position or ""
    raise PhraseError(tx.kind.value)


def _operative(tx: Transmission) -> str:
    runway = speak_runway(tx.runway_id) if tx.runway_id else ""
    if tx.kind is Kind.TAXI and tx.hold_short:
        return f"Taxi to runway {runway}, hold short runway {runway}"
    if tx.kind is Kind.TAXI:
        return f"Taxi to runway {runway}"
    if tx.kind is Kind.HOLD_SHORT:
        return f"Hold short runway {runway}"
    if tx.kind is Kind.LINE_UP:
        return f"Line up and wait runway {runway}"
    if tx.kind is Kind.TAKEOFF:
        return f"Cleared for takeoff runway {runway}"
    if tx.kind is Kind.LANDING:
        return f"Cleared to land runway {runway}"
    if tx.kind is Kind.OPTION:
        return f"Cleared for the option runway {runway}"
    if tx.kind is Kind.TOUCH_AND_GO:
        return f"Cleared touch and go runway {runway}"
    if tx.kind is Kind.STOP_AND_GO:
        return f"Cleared stop and go runway {runway}"
    if tx.kind is Kind.GO_AROUND:
        return "Going around"
    if tx.kind is Kind.RUNWAY:
        return f"Runway {runway}"
    if tx.kind is Kind.SEQUENCE and tx.runway_id:
        return f"Number {_sequence_words(tx.sequence or 0)}, runway {runway}"
    if tx.kind is Kind.SEQUENCE:
        return f"Number {_sequence_words(tx.sequence or 0)}"
    if tx.kind is Kind.FREQUENCY and tx.frequency_mhz is not None:
        return speak_frequency(tx.frequency_mhz)
    raise PhraseError(tx.kind.value)


def _clearance_sentence(tx: Transmission) -> str:
    runway = speak_runway(tx.runway_id) if tx.runway_id else ""
    if tx.kind is Kind.TAXI and tx.hold_short:
        return f"Taxi to runway {runway}, hold short runway {runway}"
    if tx.kind is Kind.HOLD_SHORT:
        return f"Hold short runway {runway}"
    if tx.kind is Kind.LINE_UP:
        return f"Runway {runway}, line up and wait"
    if tx.kind is Kind.TAKEOFF:
        return f"Runway {runway}, cleared for takeoff"
    if tx.kind is Kind.LANDING:
        return f"Runway {runway}, cleared to land"
    if tx.kind is Kind.OPTION:
        return f"Cleared for the option runway {runway}"
    if tx.kind is Kind.TOUCH_AND_GO:
        return f"Cleared touch and go runway {runway}"
    if tx.kind is Kind.STOP_AND_GO:
        return f"Cleared stop and go runway {runway}"
    if tx.kind is Kind.GO_AROUND:
        return "Go around"
    if tx.kind is Kind.RUNWAY:
        return f"Runway {runway}"
    if tx.kind is Kind.SEQUENCE and tx.runway_id:
        return f"Number {_sequence_words(tx.sequence or 0)}, runway {runway}"
    if tx.kind is Kind.SEQUENCE:
        return f"Number {_sequence_words(tx.sequence or 0)}"
    if tx.kind is Kind.FREQUENCY and tx.frequency_mhz is not None and tx.next_facility:
        return f"Contact {tx.next_facility} on {speak_frequency(tx.frequency_mhz)}"
    raise PhraseError(tx.kind.value)


def unable_reason(tx: Transmission) -> str:
    runway = speak_runway(tx.runway_id) if tx.runway_id else ""
    if tx.kind is Kind.TAXI:
        return f"taxi to runway {runway}"
    if tx.kind is Kind.HOLD_SHORT:
        return f"hold short runway {runway}"
    if tx.kind is Kind.LINE_UP:
        return f"line up and wait runway {runway}"
    if tx.kind is Kind.TAKEOFF:
        return f"cleared for takeoff runway {runway}"
    if tx.kind is Kind.LANDING:
        return f"cleared to land runway {runway}"
    if tx.kind is Kind.OPTION:
        return f"cleared for the option runway {runway}"
    if tx.kind is Kind.TOUCH_AND_GO:
        return f"touch and go runway {runway}"
    if tx.kind is Kind.STOP_AND_GO:
        return f"stop and go runway {runway}"
    if tx.kind is Kind.GO_AROUND:
        return "go around"
    if tx.kind is Kind.FREQUENCY:
        return "frequency change"
    if tx.kind is Kind.SEQUENCE:
        return f"number {_sequence_words(tx.sequence or 0)}"
    if tx.kind is Kind.RUNWAY:
        return f"runway {runway}"
    return tx.kind.value


def _sequence_words(sequence: int) -> str:
    return " ".join(_WORD[int(char)] for char in str(sequence))


def _pattern_leg(phase: str, pattern: str, runway: str, altitude: str) -> str | None:
    side = pattern
    if phase in {"climb", "go_around"}:
        return f"upwind runway {runway} at {altitude}"
    if phase == "crosswind":
        return f"{side} crosswind runway {runway} at {altitude}"
    if phase == "downwind":
        return f"{side} downwind runway {runway} at {altitude}"
    if phase == "base":
        return f"{side} base runway {runway} at {altitude}"
    if phase == "final":
        return f"final runway {runway} at {altitude}"
    return None


def _small(value: int) -> str:
    if value < 10:
        return _WORD[value]
    return " ".join(_WORD[int(char)] for char in str(value))


def _normalize(text: str) -> str:
    phrase = " ".join(text.strip().split())
    if not phrase.endswith("."):
        phrase += "."
    return phrase
