# AirTrafficControl

This repository holds two simulation programs and the requirements that describe them.

The tower is an Erlang/OTP service. It loads one airport from a TOML file, starts a small Raft group with Ra, and accepts or refuses clearances. The aircraft is a Python package. It speaks a closed set of FAA pattern phrases and flies a deterministic point-mass pattern. Both are mock software. Neither is connected to a real aircraft, a live tower, or a radio. Nothing in this repository is a certification claim.

The two programs do not talk to each other. The tower's phrase set is the clearance log used by its separation rules. The aircraft's phrase set is the pilot side of a local pattern, and its tests answer that speech with a Python script rather than with `atc_tower`.

## What you can run

From the repository root:

| Command | What it does |
| --- | --- |
| `make build` | Compiles the Erlang tower with rebar3. |
| `make run` | Builds a production release, loads `config/example-airport.toml`, prints readiness, and exits. |
| `make test` | Runs the tower Common Test suites. The cluster suite also runs a short PropEr check. |
| `make aircraft-test` | Creates the Python virtualenv if needed and runs the aircraft pytest suite. |
| `make tla-check` | Model-checks `specs/tla/AtcTower.tla` with TLC. |
| `make strictdoc-generate` | Writes the requirement HTML into `reqs/html`. |
| `make strictdoc-validate` | Parses the requirements and checks their links. |
| `make strictdoc-serve` | Serves the requirement browser. |
| `make strictdoc-tree` | Lists the `.sdoc` and `.sgra` files. |
| `make install-hooks` | Installs the pre-commit hook that regenerates `reqs/html` when requirement files are committed. |
| `make clean` | Removes `_build`, the TLC `states` directory, and the StrictDoc validation output. |

`make help` prints the same list.

## Toolchain

The Makefile looks for its tools under `.tools/`, which is gitignored:

- `.tools/erlang/bin/erl` on `PATH` for every Make target that builds or runs the tower
- `.tools/rebar3`
- `.tools/tla2tools.jar` for `make tla-check`

The tower declares OTP 27 in `rebar.config`. Its libraries are Ra 3.2.0 and tomerl 0.5.0. Tests add PropEr 1.5.0.

The aircraft package wants Python 3.12. `requirements.txt` pins StrictDoc 0.31.0 and pytest 9.2.0. The first `make aircraft-test`, `make strictdoc-init`, or `make strictdoc-generate` creates `.venv` and installs those pins. The aircraft code itself uses the standard library, including `tomllib`.

TLC needs a Java runtime. `make tla-check` runs two TLC workers.

## Repository map

```text
apps/atc_tower/     Erlang tower application, Ra machine, and tests
apps/aircraft/      Python aircraft package and pytest suite
config/             Airport files and the example aircraft file
reqs/               StrictDoc sources for both CSCIs, plus generated HTML
specs/tla/          TLA+ model of the tower clearance rules
specs/refinement/   Notes that relate the TLA+ model to the Erlang code
plans/              Planning records for the tower and the aircraft
```

`reqs/html` is generated. `make strictdoc-generate` replaces it. The pre-commit hook does that when a staged change touches a `.sdoc` or `.sgra` file.

## Tower

The tower CSCI is the OTP application `atc_tower`, version 0.1.0. One airport is one TOML file. Loading that file either opens a clearance authority or refuses to control traffic. A missing file, a missing runway designation, or a file outside the checked envelope does not start control.

The checked envelope is 4 runways, 8 aircraft, and 2 neighbors. The TOML `max_runways`, `max_aircraft`, and `max_neighbors` values have to sit inside those limits, and `computers` has to be a positive integer. `atc_bounds` enforces the envelope before `atc_service:open/1` runs.

### Start, and why `make run` exits

`make run` is the operator start path recorded for the example airport:

1. `rebar3 compile`
2. `rebar3 as prod release`
3. An Erlang node with the release on its code path
4. `atc_tower_cli:main([".../config/example-airport.toml"])`
5. `halt(0)` after the call returns

A good file prints a line of this form and then the node exits:

```text
airport KEXAMPLE ready on 1 computers
```

`computers` is the number of Ra servers in the airport group. `make run` creates all of them inside that one short-lived Erlang node. It does not start one operating-system process per computer, and it does not open a network port. The node is gone by the time Make returns.

Ra writes its data under `/tmp/<ICAO>-atc`. For the example airport that directory is `/tmp/KEXAMPLE-atc`.

A file that cannot control traffic prints `configuration refused: ...` and the CLI halts with status 1.

### Keep the tower node up

Use a shell when you want the authority to stay up and accept commands. From the repository root, with `.tools/erlang/bin` and `.tools` on `PATH`:

```bash
.tools/rebar3 shell
```

Then, in the Erlang shell:

```erlang
{ok, Text} = atc_tower_cli:run(["config/example-airport.toml"]).
Service = persistent_term:get(atc_service_current).
ServerId = hd(maps:get(ids, Service)).
```

`Text` is the same readiness binary that `make run` prints. `atc_tower_cli:run/1` has already called `ra:start/1`, `application:ensure_all_started(atc_tower)`, and `atc_service:open/1`.

`atc_service:submit/3` accepts a command only from the current leader. If `ServerId` is a follower, the return is `{error, {not_leader, Leader}}`. Submit the same command to `Leader`.

```erlang
{ok, {ok, _Assigned}, Leader} = atc_service:submit(
    Service, ServerId, {assign, <<"N123AB">>, <<"27">>, departure}).
{ok, {ok, _Holding}, _} = atc_service:submit(
    Service, Leader, {hold_short, <<"N123AB">>}).
{ok, {ok, _LinedUp}, _} = atc_service:submit(
    Service, Leader, {line_up, <<"N123AB">>}).
{ok, {ok, _Airborne}, _} = atc_service:submit(
    Service, Leader, {takeoff, <<"N123AB">>}).
atc_monitor:issued().
```

`atc_monitor:issued/0` reads the issued clearance log through the supervised monitor. `atc_service:issued/0` reads the same log directly. The log lives in Ra. Restarting the monitor process does not create a second clearance authority.

The command tuples the separation rules understand are:

| Command | Meaning |
| --- | --- |
| `{assign, Aircraft, Runway, departure \| arrival}` | Put the aircraft in the queue for that runway and intent. |
| `{hold_short, Aircraft}` | Move a queued aircraft to hold short. |
| `{line_up, Aircraft}` | Enter the runway when this aircraft is first and the runway is free. |
| `{takeoff, Aircraft}` | Leave a departure runway that this aircraft occupies. |
| `{land, Aircraft}` | Enter an arrival runway when this aircraft is first and the runway is free. |
| `{go_around, Aircraft}` | Leave an occupied arrival runway and remain airborne. |
| `{vacate, Aircraft}` | Leave an occupied arrival runway and drop the runway assignment. |
| `{handoff, Aircraft, Neighbor, Accept}` | Hand the aircraft to a neighbor. |
| `{link, Neighbor, true \| false}` | Record that the link to a neighbor is up or down. |

Aircraft and runway identifiers in these commands are binaries, matching the tests. A runway whose designation does not allow the intent is refused with `designation`. A second aircraft that tries to occupy a runway already occupied by the first is refused with `separation`. An unknown command is refused with `unknown_command`. Phrase text is attached only after the guard accepts the command. The wording is a paraphrase owned by this program. It does not copy a phraseology table.

### Stop the tower

From the same shell, after `Service` is still the map returned into `persistent_term`:

```erlang
ok = atc_service:close(Service).
q().
```

`close/1` force-deletes the Ra servers for that airport group. `q()` stops the shell. `make run` needs no separate stop. Its node has already halted.

### Airport file

`config/example-airport.toml` is the file `make run` loads. The `[airport]` table is:

| Key | Role |
| --- | --- |
| `icao` | Airport identifier. Also the name used under `/tmp`. |
| `latitude`, `longitude` | Position used to measure neighbor distance. |
| `communications_distance_nm` | Neighbors farther than this are not selected. |
| `computers` | Number of Ra servers in the group. |
| `max_runways`, `max_aircraft`, `max_neighbors` | Per-airport caps inside the global envelope. |
| `wind` | Optional wind text included in a takeoff clearance. |

Each `[[runway]]` entry has:

| Key | Role |
| --- | --- |
| `id` | Runway identifier used in commands. |
| `designation` | `both`, `arrival`, `departure`, or `closed`. |
| `independent` | Whether the runway is independent of the others. |
| `intersects` | Runway identifiers this runway crosses. |

Each `[[neighbor]]` entry has `icao`, `latitude`, and `longitude`. A neighbor outside `communications_distance_nm` is stored in the file and ignored by neighbor selection. In the example, `KNEAR` is inside 30 nm and `KFAR` is not.

To close a runway, edit that runway's `designation` to `closed` and start again. A closed runway is not assigned. The same restart is how a designation change takes effect. The running group does not watch the file.

### Other airport files

| File | ICAO | Computers | What it is for |
| --- | --- | --- | --- |
| `config/example-airport.toml` | `KEXAMPLE` | 1 | The default `make run` airport. Runway 27 is `both`. Runway 09 is `arrival` and intersects 27. |
| `config/mock-rural.toml` | `KFIELD` | 1 | One runway, no neighbor. Local service continues with the outside link down. |
| `config/mock-regional.toml` | `KREGN` | 2 | Crossing runways. One computer failure leaves no majority, so clearances stop. |
| `config/mock-metro.toml` | `KMETR` | 3 | Independent parallels plus a closed runway. One failure still leaves a majority of two. |

Load any of them by passing its path to `atc_tower_cli:run/1` instead of the example path. `make run` is wired only to `config/example-airport.toml`.

### Tower modules

| Module | Responsibility |
| --- | --- |
| `atc_tower_app` | OTP application callback. Starts the supervisor. |
| `atc_tower_sup` | One-for-one supervisor. Its only child is `atc_monitor`. |
| `atc_tower_cli` | Loads one TOML file, starts Ra and the application, and opens the airport. |
| `atc_config` | Parses the airport file with tomerl and rejects a file that cannot control traffic. |
| `atc_bounds` | Checks the runway, aircraft, neighbor, and computer limits. |
| `atc_service` | Starts the Ra cluster, submits a command to the leader, queries the issued log, and deletes the servers. |
| `atc_ra_machine` | Ra state machine. Each applied command goes through `atc_clearance`. |
| `atc_clearance` | Runs the separation transition and attaches phrase text only when the command is accepted. |
| `atc_separation` | Pure clearance rules: queue, hold short, line up, takeoff, land, go around, vacate, handoff, and link state. |
| `atc_phraseology` | Renders the accepted clearance as a short paraphrase. |
| `atc_neighbors` | Selects neighbors inside the communications distance and applies the fail-smart link policy. |
| `atc_audit` | Formats the issued and refused decision records. |
| `atc_cluster` | Pure model of the computer group. PropEr samples this. Ra remains the runtime log. |
| `atc_monitor` | Local `gen_server` that answers `issued` from the current Ra log. |

### Tower tests and the TLA+ model

`make test` runs:

- `atc_config_SUITE` for the TOML loader and the envelope
- `atc_clearance_SUITE` for designations, separation, and phrase text
- `atc_cluster_SUITE` for quorum, leader, and crash behavior, including `prop_clearance:quickcheck/0`

`make tla-check` runs TLC on `specs/tla/AtcTower.tla` with `specs/tla/AtcTower.cfg`. The model is a finite instance. `specs/refinement/Mapping.md` records how that model lines up with the Erlang modules and which obligations are still open. A passing TLC run and a passing PropEr sample are evidence about those artifacts. They are not a proof and they are not an authority finding.

## Aircraft

The aircraft CSCI is the Python package `aircraft`, version 0.1.0, under `apps/aircraft`. It is one fictional civil aircraft at one airport with one runway and one pattern direction. The example registration is `N123AB`. Every transmission speaks that registration in full. `N123AB` is spoken as `November one two three alpha bravo`. Digit 9 is `niner` and digit 0 is `zero`. The package does not abbreviate the call sign.

Motion changes only when `Aircraft.step(dt)` is called with a positive `dt`. Requests and clearances update the accepted plan. They do not teleport the aircraft. A clearance the aircraft cannot fly is answered with `Unable`, and the previous maneuver continues. A transmission for another call sign or another runway is ignored. If the link is down, the aircraft sends nothing and keeps the last accepted clearance.

The port is `InMemoryLink`. `send` returns `sent`, `blocked`, or `down`. No radio, socket, or byte encoding is selected.

### Aircraft modules

| Module | Responsibility |
| --- | --- |
| `aircraft.aircraft` | Phase machine, requests, readbacks, `Unable`, link faults, emergency calls, and the in-memory decision log. |
| `aircraft.mission` | `PatternMission`, which steps one pattern from the ATIS call through the frequency change. |
| `aircraft.phrasebook` | Renders and parses the closed phrase set. Wind and altimeter on an inbound clearance are not read back. |
| `aircraft.dynamics` | Point-mass integrator. Heading, speed, altitude, then position, in that order. |
| `aircraft.callsign` | Validates a civil N-number and speaks it in ICAO form. |
| `aircraft.transmission` | The in-memory transmission fields: facility, call sign, kind, runway, sequence, ATIS letter, frequency, nature, and intention. |
| `aircraft.link` | `InMemoryLink` and the link events `delivered`, `blocked`, `garbled`, `down`, and `up`. |
| `aircraft.config` | Loads the aircraft TOML file. An invalid file raises `ConfigError` and does not produce an aircraft. |

`apps/aircraft/tests/scripted_tower.py` is a test peer. It is not product behavior. It answers ATIS, pattern entry, taxi, line up and wait, landing, the option family, and the frequency change, and it offers takeoff once the aircraft is lined up.

### Run the aircraft tests

```bash
make aircraft-test
```

That runs `pytest` in `apps/aircraft`. The suite covers the call sign, the TOML accept and reject cases, phrase order, the time step, taxi through takeoff, landing types, `Unable`, lost link, garble, one repeat of a blocked transmission, Mayday, Pan-Pan, and one full pattern.

### Run one pattern

This is the same loop as `apps/aircraft/tests/test_mission.py`. The scripted peer has to stay on `PYTHONPATH` because it lives under the tests, not in the product package.

```bash
export PYTHONPATH="apps/aircraft/src:apps/aircraft/tests"
.venv/bin/python
```

```python
from pathlib import Path

from aircraft import Aircraft, PatternMission, load_config
from aircraft.link import InMemoryLink
from scripted_tower import ScriptedTower

aircraft = Aircraft(load_config(Path("config/n123ab.toml")), InMemoryLink())
mission = PatternMission(aircraft)
tower = ScriptedTower()

while not mission.done:
    mission.tick(0.5)
    proactive = tower.proactive(aircraft)
    if proactive is not None:
        aircraft.receive(proactive)
    while aircraft.link.outbound:
        phrase = aircraft.link.outbound.pop(0)
        print(phrase.phrase)
        for reply in tower.respond(phrase.phrase):
            aircraft.receive(reply)

print(aircraft.phase)
print(aircraft.facility)
```

`mission.tick(0.5)` advances one half-second. The mission requests ATIS, enters the left pattern for runway 27 with the information letter, taxis, reports holding short and ready, and on the downwind requests the landing that matches `option.choice`. After the aircraft stops, it requests the frequency change. When the scripted peer answers, later calls are addressed to `Departure`.

`aircraft.phrases` is the list of phrases that were actually sent. `aircraft.decisions` is a list of `(requirement_uid, summary)` pairs kept in memory. Neither log is written to disk. The only persistent aircraft input is the TOML file, and the flight path does not modify it.

The example option is `full_stop`, so the downwind request is a landing. The other choices are `touch_and_go`, `stop_and_go`, and `low_approach`. Change `[option] choice` in a copy of the file and load that path. A low approach descends only to `low_approach_ft` above the field elevation and then climbs.

Calls you can make yourself, without `PatternMission`:

| Method | When it applies |
| --- | --- |
| `request_atis()` | Ask for the information letter. |
| `request_pattern_entry()` | Initial call for the configured pattern and runway. |
| `request_taxi()` | From the ramp. |
| `report_holding_short()` | Report the hold-short point. |
| `report_ready()` | Report ready for takeoff. |
| `request_landing()` | Request a full-stop landing. |
| `request_option()` | Request the option. The outcome is the configured choice. |
| `request_touch_and_go()` | Request a touch-and-go. |
| `request_stop_and_go()` | Request a stop-and-go. |
| `request_go_around()` | Pilot-initiated go-around while airborne. The phrase is `going around`. |
| `request_frequency_change()` | Ask for the next facility. |
| `report_position()` | Speak the current leg, distance, and altitude. |
| `declare_emergency(kind, nature, intention)` | `kind` is `mayday` or `pan_pan`. The declaration does not change the maneuver. |
| `receive(item)` | Accept a `Transmission` or a `LinkEvent` from the peer. |
| `step(dt)` | Advance the point mass. `dt` has to be positive. |
| `position_text()` | The position clause the next report would use. |

A request is spoken as facility, full call sign, position when the call is initial or is a position report, then the request. A readback puts the operative clearance first and the full call sign last. The pilot readback of a controller `Go around` is `Going around`, then the call sign.

Altitude in a report is rounded to the nearest 100 feet. Distance under 100 feet from the threshold is `at the field`. A distance that rounds to zero nautical miles is `less than one mile`. Other distances use individual digits and an eight-point compass.

### Aircraft file

`config/n123ab.toml` is the example. The tables are `aircraft`, `performance`, `airport`, `runway`, `ramp`, and `option`. Extra keys and missing keys are errors.

The aircraft table names `n_number`, `facility`, `next_facility`, and `next_frequency_mhz`. The frequency has to sit in 118.000 to 136.975. The example next frequency is 124.5, spoken as `one two four point five`.

The performance table sets taxi, rotation, and pattern speeds in increasing order, pattern altitude, takeoff and landing distances, turn rate, acceleration, vertical speed, and the low-approach height. Pattern altitude is height above the airport elevation. Reported altitude is mean sea level once the aircraft is at pattern altitude.

The runway table sets the identifier, the centerline heading, the length, `left` or `right` pattern, the hold-short distance, the pattern offset, and the upwind distance. The upwind distance has to be longer than the runway. The ramp table is a north/east point in feet. The threshold is the origin. Heading zero is north and increases clockwise.

### Geometry the example flies

Runway 27 points west. The hold-short point is 200 feet before the threshold. Line up and wait stops 100 feet past the threshold, aligned with the runway, until a takeoff clearance. The crosswind corner is 7000 feet upwind and 5000 feet to the left. The aircraft then flies downwind, base, and final. On a full stop it rolls out and stops. Touch-and-go becomes another takeoff roll after the surface. Stop-and-go slows and then rolls. A controller or pilot go-around climbs on runway heading toward pattern altitude and then turns crosswind.

## Requirements

Both CSCIs are written in StrictDoc 0.31. Each requirement is its own fragment. A parent `.sdoc` in the same directory includes the fragments. Shared grammar fields are UID, title, statement, rationale, DAL, requirement level, verification method, assumptions, parent links, and file links. The aircraft documents import `reqs/grammar.sgra` through a same-directory link because this StrictDoc version rejects an import path that contains a slash or a parent directory. The tower documents keep a copy of the same field set in each directory.

Tower requirement identifiers have no prefix (`SRS001`, `SDD001`, and so on). Aircraft identifiers use the `AC-` prefix so the two sets cannot collide. Aircraft requirements are DAL E. The tower set uses the DAL recorded on each tower fragment.

The delivered descriptions, for each CSCI, are:

| Directory | Description |
| --- | --- |
| `sdp` | Software development plan, including which manuals were tailored out. |
| `sip` | Software installation plan. |
| `strp` | Software transition plan. |
| `ocd` | Operational concept description. |
| `sss` | System specification. |
| `srs` | Software requirements. |
| `irs` | Interface requirements. |
| `ssdd` | System design description. |
| `sdd` | Software design description. |
| `idd` | Interface design description. |
| `dbdd` | Database design description. |
| `stp` | Software test plan. |
| `std` | Software test description. |
| `str` | Software test report, written from an actual run. |
| `sum` | Software user manual. |
| `sps` | Software product specification. |
| `svd` | Software version description. |

Tower documents live in `reqs/<directory>/`. Aircraft documents live in `reqs/aircraft/<directory>/`. Both HTML trees are generated together into `reqs/html`. Open `reqs/html/index.html` after `make strictdoc-generate`, or run `make strictdoc-serve` and use the URL StrictDoc prints.

SIOM, SCOM, COM, CPM, and FSM are tailored out of both plans. The reasons are recorded in `SDP002` for the tower and `AC-SDP002` for the aircraft. There is no computer-center operator manual, no firmware manual, and no separate programming manual beyond the design descriptions and the source.

Source files point back at requirements with `@relation` comments. The aircraft Python modules use the same marker. `strictdoc.toml` indexes `apps/**`, `specs/**`, `config/**`, `rebar.config`, and the `Makefile`.

## How the two phrase sets differ

The tower renders clearances it has already accepted: runway assignment, hold short, line up and wait, takeoff with optional wind, landing with a sequence number, go around, vacated, and a handoff. The aircraft renders the pilot side of a local pattern: ATIS, taxi, hold short, ready, line up and wait, takeoff, landing, go around, sequence, runway assignment, frequency change, position, the option, touch-and-go, stop-and-go, `Unable`, `Say again`, Mayday, and Pan-Pan.

A later interface can treat the tower's pilot phrases as a subset of the aircraft set. That interface is not in this repository. The aircraft tests do not call `atc_tower`, and the tower tests do not import the Python package.
