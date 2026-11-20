---
name: Aircraft CSCI Phraseology
overview: Add a separate Python aircraft CSCI with its own tailored MIL-STD-498 StrictDoc set, a deterministic point-mass model, and FAA AIM/JO 7110.65 pattern phraseology. The tower link is an in-memory port only; no radio, socket, or wire format is chosen.
todos:
  - id: save-plan
    content: "Save this plan under plans/ and commit it with Requirements: None"
    status: in_progress
  - id: grammar-sdp
    content: Confirm StrictDoc 0.31 include syntax, add the shared grammar, and write AC-SDP001 and AC-SDP002
    status: pending
  - id: concept-interface
    content: Write AC-OCD001–005, AC-SSS001–008, and AC-IRS001–004 as one-paragraph fragments with parent links
    status: pending
  - id: software-reqs
    content: Write AC-SRS001–022 as one-paragraph fragments traced to the aircraft SSS
    status: pending
  - id: design-docs
    content: Write AC-SSDD, AC-SDD, AC-IDD, and AC-DBDD fragments, including the deferred encoding
    status: pending
  - id: verification-support-plans
    content: Write AC-STP, AC-STD, AC-SIP, AC-STrP, and AC-SUM before code execution results exist
    status: pending
  - id: python-package
    content: Implement the aircraft package, n123ab.toml, Makefile target, and pytest pin, each module commented with its UID
    status: pending
  - id: tests-and-reports
    content: Add pytest for phraseology, dynamics, readback, Unable, link faults, and emergency; then write AC-STR, AC-SPS, and AC-SVD from the actual run
    status: pending
  - id: html-trace
    content: Validate StrictDoc, generate reqs/html, and confirm parent, file, and commit links for every AC- UID
    status: pending
isProject: false
---

# Mock aircraft CSCI with FAA pattern phraseology

## Decisions

The ten scope choices are closed as follows.

- Separate Aircraft CSCI. Its StrictDoc UIDs use an `AC-` prefix so they cannot collide with the tower UIDs already reserved in [plans/do178c-airport-tower-requirements-and-traced-erlang-service.md](plans/do178c-airport-tower-requirements-and-traced-erlang-service.md) and cited by [apps/atc_tower/src/atc_tower_app.erl](apps/atc_tower/src/atc_tower_app.erl). The Erlang tower is not modified.
- Python package under [apps/aircraft/](apps/aircraft/).
- Phraseology covers the local pattern: ATIS, taxi, hold short, line up and wait, takeoff, landing, go-around, sequence, runway assignment, frequency change, position report, pattern entry, the option, touch-and-go, and stop-and-go. Requirements name the AIM and JO 7110.65 and the information order. They do not paste phraseology tables.
- The communication method stays unselected. Product code exposes a port. Tests use an in-memory fake. No TCP, stdin, radio, or byte encoding.
- Motion is a deterministic point-mass model advanced by `step(dt)`.
- One configured civil N-number, always spoken in full. No abbreviated call sign.
- Every safety-critical clearance is read back in AIM order, or refused with Unable.
- A down link and a blocked or garbled transmission are in scope.
- The aircraft can declare Mayday or Pan-Pan. No tower reply is required or modeled.
- Document set matches the tower tailoring: OCD, SSS, SRS, IRS, SSDD, SDD, IDD, DBDD, STP, STD, STR, SDP, SIP, STrP, SUM, SPS, SVD. SIOM, SCOM, COM, CPM, and FSM are tailored out in the SDP.

Further limits this plan closes:

- This is simulation software. Every aircraft requirement is DAL E. No DO-178C approval and no real-aircraft or live-facility connection is claimed.
- One runway, one pattern direction, no LAHSO, no intersection departure, no taxiway graph. The option outcome is a config value: full stop, touch-and-go, stop-and-go, or low approach.
- A transmission for another call sign or another runway is ignored. Unable is only for a clearance addressed to this aircraft that it will not fly.
- Wind and altimeter may appear in an inbound clearance and are not read back.
- The pilot response to a go-around instruction is "going around", then the call sign.
- Digits are spoken individually; 9 is "niner"; 0 is "zero"; letters use the ICAO alphabet.
- Requests are ordered: facility, full call sign, position when the contact is initial or is a position report, then the request. Readbacks put the operative clearance first and the full call sign last.
- Lost link: send nothing, including a readback or a declaration; keep the last fully accepted clearance; if none, stay stopped on the ground or continue the current airborne leg without entering a new runway clearance. A garbled clearance is not accepted. Each blocked outbound transmission is repeated once.
- Mayday and Pan-Pan carry facility, call sign, nature, current position, and intention. The declaration does not itself change the maneuver.
- The Erlang tower's future pilot interface is a subset of this phrase set. Taxi, ATIS, frequency, the option, touch-and-go, stop-and-go, and emergency are answered in tests by a Python scripted peer, not by `atc_tower`.
- Invalid aircraft TOML means the aircraft does not fly.
- Persistent data is the TOML file only. Flight state and the decision log stay in memory.

## Requirement shape

Confirm StrictDoc 0.31.0 include and relation syntax from the existing [.venv](.venv) before the first fragment. Pinned in [requirements.txt](requirements.txt).

Shared grammar [reqs/grammar.sgra](reqs/grammar.sgra) with the fields the tower plan already named: UID, TITLE, STATEMENT, RATIONALE, DAL, REQUIREMENT_LEVEL, VERIFICATION, ASSUMPTIONS, plus Parent and File relations. Aircraft DAL is `E`. Verification is `Test` or `Review`.

Each requirement is one fragment. `STATEMENT` is one paragraph: condition, behavior, limit, and acceptance outcome. Parents are StrictDoc relations. Implementing Python carries `# Implements: AC-SRS001` and `# @relation(AC-SRS001, scope=file)`, matching the Erlang relation style. [strictdoc.toml](strictdoc.toml) already indexes `apps/**`.

Documents live under `reqs/aircraft/<did>/`, one parent `.sdoc` per DID and one fragment per UID.

```mermaid
flowchart TD
  SDP --> OCD
  OCD --> SSS
  SSS --> SRS
  SSS --> SSDD
  IRS --> IDD
  SRS --> SDD
  SDD --> pythonCSCI [Python_aircraft]
  SRS --> STD
  pythonCSCI --> pytestNode [pytest]
  pytestNode --> STD
  STD --> STR
```

## Catalog

Parents are written on the fragments. Levels: OCD operational, SSS system, SRS high-level, IRS interface, SDD and IDD and DBDD low-level.

SDP

- AC-SDP001 Lifecycle, DID list, DAL E, Python, deferred transport, trace rules
- AC-SDP002 SIOM, SCOM, COM, CPM, and FSM tailored out, with reasons

OCD

- AC-OCD001 One configured civil aircraft flies a local pattern at one configured airport
- AC-OCD002 The pilot speaks FAA phraseology through a link whose method is not chosen
- AC-OCD003 The spoken position matches the point-mass state
- AC-OCD004 A blocked, garbled, or lost link does not create a clearance
- AC-OCD005 The pilot may declare Mayday or Pan-Pan without an answer

SSS

- AC-SSS001 Accepted clearances shall drive the point-mass maneuver
- AC-SSS002 Requests and readbacks shall cover the pattern set in AIM order
- AC-SSS003 Every transmission shall use the one full spoken N-number
- AC-SSS004 A clearance outside performance or legal phase shall be refused with Unable and shall not be flown
- AC-SSS005 A lost link shall preserve the last accepted clearance and originate nothing
- AC-SSS006 A garbled addressed transmission shall be refused and queried; a blocked own transmission shall be repeated once
- AC-SSS007 Mayday and Pan-Pan shall be declared in standard form with no reply required
- AC-SSS008 The port shall carry information content and rendered phrase text, and shall not select a wire encoding

SRS, child of the SSS item in parentheses

- AC-SRS001 Reject invalid TOML and do not fly (AC-SSS008)
- AC-SRS002 Speak the full N-number on every transmission (AC-SSS003)
- AC-SRS003 Render requests as facility, call sign, position, request (AC-SSS002)
- AC-SRS004 Render readbacks as operative clearance, then call sign (AC-SSS002)
- AC-SRS005 Request ATIS or include the information letter (AC-SSS002)
- AC-SRS006 Request taxi and read back the taxi clearance (AC-SSS001, AC-SSS002)
- AC-SRS007 Report holding short and read back hold short with the runway (AC-SSS002)
- AC-SRS008 Read back line up and wait, align, and wait (AC-SSS001)
- AC-SRS009 Report ready, read back cleared for takeoff, and fly the roll and climb (AC-SSS001)
- AC-SRS010 Request pattern entry and landing, and read back runway and landing clearance (AC-SSS001, AC-SSS002)
- AC-SRS011 Fly and say "going around" when the pilot or the controller initiates it (AC-SSS001)
- AC-SRS012 Read back the sequence number (AC-SSS002)
- AC-SRS013 Read back a frequency change and address the new facility afterward (AC-SSS002)
- AC-SRS014 Build position reports from the dynamics state, with stated rounding (AC-SSS002)
- AC-SRS015 Request and fly the option, touch-and-go, and stop-and-go, including low approach (AC-SSS001)
- AC-SRS016 Say Unable and keep the previous maneuver when phase or performance forbids the clearance (AC-SSS004)
- AC-SRS017 On link down, send nothing and continue only the last accepted maneuver (AC-SSS005)
- AC-SRS018 On an addressed garble, say again and do not accept it (AC-SSS006)
- AC-SRS019 On a blocked own transmission, repeat that transmission once (AC-SSS006)
- AC-SRS020 Declare Mayday or Pan-Pan with nature, position, and intention (AC-SSS007)
- AC-SRS021 Advance the point-mass state only through deterministic `step(dt)` (AC-SSS001)
- AC-SRS022 Append an in-memory decision record naming the UID that authorized the change (traceability)

IRS

- AC-IRS001 Transmission content: facility, call sign, position, intent or clearance kind, runway, sequence, ATIS letter, frequency, wind and altimeter as optional ignored readback fields, emergency nature and intention
- AC-IRS002 Link events: delivered, blocked, garbled, down, up
- AC-IRS003 Aircraft and airport TOML schema
- AC-IRS004 Phrase string is the notation; byte encoding is explicitly not selected

Design

- AC-SSDD001 Aircraft, one runway, and the tower as an external system; the link is the only failure domain in this CSCI
- AC-SDD001 Objects and which one owns `step`, receive, and request
- AC-SDD002 Phase machine and the clearance that enables each transition
- AC-SDD003 Point-mass integration and the rectangular pattern geometry
- AC-SDD004 Closed phrase set: one renderer and one parser, round-tripped
- AC-IDD001 In-memory `Transmission` and link events; encoding deferred to a later plan
- AC-DBDD001 TOML is the only persistent store

Verification and support

- AC-STP001 Maps each SRS item to a pytest
- AC-STD001 through AC-STD012, one paragraph each, grouped the way the tower STD groups related clearance items
- AC-STR001, AC-SPS001, and AC-SVD001 written only after pytest has been run, recording the command and the result
- AC-SIP001 Create the virtualenv and run one configured aircraft
- AC-STrP001 Hand over the package, the TOML, the phrase set, and the unselected transport
- AC-SUM001 Step one pattern scenario and read the phrase log

## Software

Package [apps/aircraft/src/aircraft/](apps/aircraft/src/aircraft/). Standard library plus pytest. No network library.

- `callsign.py` implements AC-SRS002
- `transmission.py` implements AC-IRS001
- `phrasebook.py` implements AC-SRS003, AC-SRS004, and AC-SDD004
- `link.py` implements AC-IRS002 and AC-IDD001, including `InMemoryLink`
- `config.py` implements AC-SRS001 and AC-IRS003
- `dynamics.py` implements AC-SRS021 and AC-SDD003
- `aircraft.py` implements the phase machine, readback, Unable, lost-link, garble, repeat, emergency, and decision log
- `mission.py` flies one scripted pattern against the port

Example config [config/n123ab.toml](config/n123ab.toml): fictional `N123AB`, performance distances, airport elevation, runway 27, left pattern, option choice.

Geometry: runway threshold at the origin, centerline along runway heading, hold-short point a configured distance before the threshold, pattern legs from configured distances. Reports round altitude to the nearest 100 feet and distance to the nearest whole nautical mile.

`Aircraft` methods used by tests and by `PatternMission`: request helpers, `receive`, `declare_emergency`, and `step`. The scripted peer lives under [apps/aircraft/tests/](apps/aircraft/tests/) and is not product behavior.

Add a pinned pytest to [requirements.txt](requirements.txt) and an `aircraft-test` target to [Makefile](Makefile).

## Commits

First execution step: save this plan under [plans/](plans/) and commit it with `Requirements: None`.

Before the first commit, set the local repository identity to `$(whoami) | Cursor.sh | Grok 4.7` and `$(whoami)@$(hostname).local`. Fetch origin. Merge upstream only if that remote exists. Push after each commit when a remote exists.

Install [scripts/git-hooks/pre-commit](scripts/git-hooks/pre-commit) before the first `.sdoc` commit so `reqs/html` is regenerated with each fragment. Each new file is its own commit. Allowed groupings: a fragment with the Python file that implements it, and those files with the plan checkbox they complete. After the first `.sdoc` exists, every commit message has a `Requirements:` section. Do not put `!` in commit text.
