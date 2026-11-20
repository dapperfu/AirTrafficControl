---
name: DO-178C Tower Requirements
overview: Write a tailored MIL-STD-498 StrictDoc set for an Erlang airport-tower service, using the Wikipedia DID names, then implement the traced tower, a TLA+ separation model, a refinement map, and PropEr conformance tests. The result is DO-178C lifecycle evidence for this repository, not an authority certification.
todos:
  - id: save-plan
    content: "Save this plan into plans/ and commit it with Requirements: None"
    status: in_progress
  - id: scaffold
    content: Add .gitignore, virtualenv StrictDoc, strictdoc.toml, Makefile, pre-commit hook, and rebar3 project skeleton
    status: pending
  - id: sdp-tailoring
    content: Write SDP001 and SDP002 with the 22 Wikipedia DIDs, DAL allocation, and tailored-out SIOM, SCOM, COM, CPM, and FSM
    status: pending
  - id: concept-system
    content: Write OCD001–OCD004 and SSS001–SSS010 as one-paragraph fragments with parent links
    status: pending
  - id: software-interface
    content: Write SRS001–SRS016 and IRS001–IRS004 as one-paragraph fragments traced to the SSS
    status: pending
  - id: design-docs
    content: Write SSDD, SDD including the refinement obligation, IDD, and DBDD fragments
    status: pending
  - id: verification-docs
    content: Write STP and STD fragments that name Formal, Refinement, PropEr, or Test for each SRS item
    status: pending
  - id: support-docs
    content: Write SIP, STrP, and SUM fragments; leave SPS, SVD, and STR until the build and tests exist
    status: pending
  - id: tla-model
    content: Write AtcTower.tla, the finite TLC config, and the refinement mapping with open obligations
    status: pending
  - id: erlang-service
    content: Implement the OTP tower, TOML config, Ra log, neighbor fail-smart behavior, and clearance guard, each module commented with its UID
    status: pending
  - id: tests-and-str
    content: Add PropEr and Common Test, run them, and write STR, SPS, and SVD from the actual results
    status: pending
  - id: html-trace
    content: Validate StrictDoc, generate reqs/html, and confirm parent, file, comment, and commit links for every UID
    status: pending
isProject: false
---

# DO-178C airport tower requirements and traced Erlang service

## Decisions already made

- Phraseology and runway separation follow FAA JO 7110.65. Requirements name the order and describe the information a clearance must carry. They do not paste phraseology tables.
- Document titles and acronyms are the 22 MIL-STD-498 data item descriptions on [Wikipedia](https://en.wikipedia.org/wiki/MIL-STD-498). In particular, **SSS** is the System/Subsystem Specification and **SRS** is the Software Requirements Specification. The repository hierarchy rule expands those two acronyms the other way; this plan follows the user and Wikipedia.
- One CSCI, named Tower. System requirements live in the SSS. Software requirements for that CSCI live in the SRS.
- Loss of separation, an unsafe clearance, and fail-smart behavior are DAL A. Split-brain of the clearance authority is DAL A. Availability beyond a single computer is only claimed when `n > 1`.
- TLA+ specifies clearance semantics, aircraft state transitions, and the separation invariant. TLC checks that every admissible clearance preserves separation inside a finite envelope and under explicit performance and environmental assumptions.
- Erlang/OTP implements the service. PropEr state-machine tests cover concurrent requests, process failure, recovery, and distributed-state consistency. Those tests are conformance evidence. They do not prove the implementation correct.
- A separate refinement mapping connects Erlang state to TLA+ state. Obligations that TLC and PropEr do not discharge stay labeled open in the SDD.
- This increment's safety property is exclusive use of a runway protected volume, exclusion of intersecting or dependent runways, and in-trail queue order with a configured gap. Visual separation, LAHSO, radar vectoring, TRACON, enroute, and wake RECAT are outside the envelope and are refused or not offered.
- Hold short, line up and wait, and go-around are included because runway exclusion cannot be enforced with only landing, queue, takeoff, and runway assignment.
- `n` is an integer greater than 0. `n = 1` is a valid rural airport with no local failover. `n > 1` is one Raft group with one ordered clearance log. Raft itself is an assumption, not a proof.
- Neighbor airports coordinate only inside configured communications distance. Loss of that link keeps local tower service and blocks clearances that need a neighbor. Stale neighbor state cannot reduce local separation.
- Each airport is configured by one TOML file: identity, position, communications distance, computer count, model bounds, and every runway with its designation (`arrival`, `departure`, `both`, `closed`) and whether it is independent.
- Checked envelope, also the operational limit the software will enforce: at most 4 runways, 8 aircraft under control, and 2 neighbor airports. Wider use requires the model to be extended first.
- No certification authority approval is claimed. No DER finding is claimed. Erlang process isolation is not claimed as DO-178C robust partitioning.

## Edge cases this plan closes

1. Deliver OCD, SSS, SRS, IRS, SSDD, SDD, DBDD, IDD, STP, STD, STR, SDP, SIP, STrP, SUM, SPS, and SVD. Tailor out SIOM, SCOM, COM, CPM, and FSM in the SDP, with the reason recorded there.
2. `n = 1` still controls the local airport and still applies the separation guard.
3. Aircraft, runway, and neighbor counts above the TLC envelope are rejected at startup.
4. A closed or wrongly designated runway cannot be assigned.
5. Two local computers cannot both issue clearances after a partition of the airport group.
6. A down neighbor link cannot be treated as an empty sky.
7. Invalid TOML prevents the node from controlling traffic.
8. Concurrent clearance requests are serialized by the replicated log.
9. Intersecting or non-independent runways exclude each other; independent parallels do not.
10. PropEr failures fail the build. They are never rewritten as formal proof.

## Requirement shape

Each requirement is one StrictDoc item. `TITLE` is the one-line summary. `STATEMENT` is one paragraph: condition, what the software shall do, the limit, and the acceptance outcome. DAL, verification method, assumptions, and parent links are fields, not extra paragraphs.

Example target for SSS004:

> When an airport can no longer exchange traffic state with a neighbor inside the configured communications distance, the local computers shall keep runway assignment, sequencing, landing, and takeoff service for aircraft already inside that airport's protected volume. The airport shall not issue a handoff or any other clearance that depends on neighbor state it cannot confirm. Last-known neighbor data shall stay marked stale and shall not reduce local separation. Coordinated handoffs shall resume only after the neighbor link is revalidated. This shall hold for a rural airport with one computer and no reachable neighbor.

## Where files go

Source documents live under [reqs/](reqs/) so HTML can be published from [reqs/html/](reqs/html/), per the StrictDoc GitHub Pages rule. One parent `.sdoc` per delivered DID, titled with the Wikipedia name. One fragment file per requirement UID so each file maps to one requirement. Confirm the include directive against the installed StrictDoc grammar before writing files.

```
reqs/sss/SSS.sdoc
reqs/sss/SSS001.sdoc
reqs/srs/SRS.sdoc
reqs/srs/SRS001.sdoc
```

Folders and parent titles:

- `ocd` Operational concept description
- `sss` System/subsystem specification
- `srs` Software requirements specification
- `irs` Interface requirements specification
- `ssdd` System/subsystem design description
- `sdd` Software design description
- `dbdd` Database design description
- `idd` Interface design description
- `stp` Software test plan
- `std` Software test description
- `str` Software test report
- `sdp` Software development plan
- `sip` Software installation plan
- `strp` Software transition plan, title acronym STrP
- `sum` Software user manual
- `sps` Software product specification
- `svd` Software version description

Grammar fields on every requirement: UID, TITLE, STATEMENT, RATIONALE, DAL, REQUIREMENT_LEVEL (`System`, `High-Level`, `Low-Level`, `Derived`, `Interface`), VERIFICATION (`Test`, `Analysis`, `Review`, `Formal`, `Refinement`), ASSUMPTIONS. Parent links use StrictDoc relations. After code exists, the implementing fragment gains a File relation to the Erlang, TLA+, or test file.

## Traceability

```mermaid
flowchart TD
  OCD --> SSS
  SSS --> SRS
  SSS --> SSDD
  IRS --> IDD
  SRS --> SDD
  SDD --> tlaSpec [TLA_spec]
  SDD --> erlangImpl [Erlang_CSCI]
  tlaSpec --> refinementMap [Refinement_map]
  erlangImpl --> refinementMap
  SRS --> STD
  erlangImpl --> properTests [PropEr]
  properTests --> STD
  STD --> STR
```

Every child names its parent UID. Every Erlang module header names the UID it implements, for example `% Implements: SRS001`. Every test names `% Verifies: SRS001`. The TLA+ spec names the SRS items it verifies. Commit messages use the `Requirements:` section with role `Specifies`, `Implements`, or `Verifies`, the UID, and the one-line summary. A code change that satisfies a requirement is committed with the fragment that links to that file.

## Requirement catalog

Parents are written on the fragments during execution. Levels: OCD operational, SSS system, SRS high-level, IRS interface, SDD and DBDD and IDD low-level, refinement items derived.

OCD

- OCD001 Local tower service replaces the manned tower for one configured airport
- OCD002 Neighbor airports coordinate aircraft that cross a shared communications boundary
- OCD003 A rural airport keeps working when the outside link is down
- OCD004 Pilots receive FAA tower clearances for runway, sequence, landing, and takeoff

SSS

- SSS001 Aircraft shall not occupy the same runway protected volume
- SSS002 Each airport shall run on n ATC computers for integer n greater than 0
- SSS003 Airports inside communications distance shall exchange the state a handoff requires
- SSS004 Loss of the outside link shall fail smart and preserve local separation
- SSS005 The tower shall give runway assignment, sequence, landing, takeoff, hold short, line up and wait, and go-around
- SSS006 Runways and their designations shall come from one TOML file per airport
- SSS007 Separation shall be demonstrated by a TLA+ model under stated assumptions and bounds
- SSS008 The Erlang service shall be tied to that model by a refinement argument
- SSS009 When n is greater than 1, one local computer failure shall leave a single clearance authority
- SSS010 A clearance the separation guard rejects shall not be issued

SRS, each a child of the SSS item named in parentheses

- SRS001 Reject invalid TOML and do not control traffic (SSS006)
- SRS002 Use runway designation and independence when assigning a runway (SSS005, SSS006)
- SRS003 Form the local group of size n, including n equals 1 (SSS002)
- SRS004 Replicate clearance state as one ordered log (SSS009)
- SRS005 Select neighbors by communications distance (SSS003)
- SRS006 Complete a handoff only with a reachable neighbor (SSS003)
- SRS007 On a dead neighbor link, continue local service and refuse dependent clearances (SSS004)
- SRS008 Assign a runway only when designation, independence, and occupancy allow it (SSS001, SSS005)
- SRS009 Keep arrival and departure sequence order (SSS005)
- SRS010 Issue or refuse takeoff clearance (SSS005, SSS010)
- SRS011 Issue or refuse landing clearance (SSS005, SSS010)
- SRS012 Issue hold short, line up and wait, and go-around when needed to keep the runway exclusive (SSS001)
- SRS013 Apply the separation guard before any clearance that changes occupancy (SSS001, SSS010)
- SRS014 Refuse operation outside the performance assumptions and the checked envelope (SSS007)
- SRS015 Restart a failed local computer without a second clearance authority (SSS009)
- SRS016 Record each decision with the requirement UID it carried out (traceability)

IRS

- IRS001 Pilot clearance content: aircraft identity, runway, sequence, clearance kind, and wind when the clearance needs it
- IRS002 Neighbor handoff request, accept, reject, and stale marker
- IRS003 TOML airport and runway schema
- IRS004 Intra-airport log command for a single clearance decision

Design

- SSDD001 Airport, local computers, and neighbor topology, with the two failure domains
- SDD001 OTP supervision tree for one airport group
- SDD002 Clearance state machine and the TLA+ actions that match it
- SDD003 Refinement mapping from Erlang state to TLA+ state, including open obligations
- SDD004 Consensus assumption: the Raft log is a single ordered history; Raft is not re-proved
- SDD005 Fail-smart mode and the stale-neighbor rule
- IDD001 Concrete schemas for IRS001 through IRS004
- DBDD001 The replicated clearance log is the operational store; TOML is configuration read at startup

Verification and plans

- SDP001 Lifecycle, Wikipedia DID set, tailoring, DAL, Erlang, TLA+, and trace rules
- SDP002 SIOM, SCOM, COM, CPM, and FSM tailored out, with reasons
- STP001 Which SRS items are discharged by TLC, by refinement review, by PropEr, and by example tests
- STD001 through STD012, one paragraph each, matching SRS001, SRS002, SRS003, SRS004, SRS005, SRS006, SRS007, the clearance group SRS008–SRS012, SRS013, the PropEr campaign, SRS014, and SRS016
- STR001 written only after the tests have actually been run, recording command and result
- SIP001 Install one release on n airport computers and point them at the TOML file
- STrP001 Hand the release, the TOML, the model, and the open proof obligations to a support engineer
- SUM001 Start, stop, and edit runway designations for one airport
- SPS001 and SVD001 written after the build exists, listing the delivered sources, the TLA+ spec, and the requirements HTML

## Formal model and Erlang

TLA+ in [specs/tla/AtcTower.tla](specs/tla/AtcTower.tla), with a TLC config for the finite envelope. Constants are the runway relation, the in-trail gap, occupancy intervals, and the neighbor-link status. The invariant is exclusive protected volume, dependent-runway exclusion, queue order, and no neighbor-dependent clearance while the link is down.

Refinement map in [specs/refinement/Mapping.md](specs/refinement/Mapping.md), linked from SDD003. It names Erlang variables, the TLA+ variables they represent, the Raft assumption, and any obligation left open.

Erlang release under [apps/atc_tower/](apps/atc_tower/), one primary UID per module:

- `atc_config.erl` implements SRS001 and SRS002
- `atc_cluster.erl` implements SRS003, SRS004, and SRS015, using Ra for the log
- `atc_neighbors.erl` implements SRS005, SRS006, and SRS007
- `atc_clearance.erl` implements SRS008 through SRS012
- `atc_separation.erl` implements SRS013 and is the refinement target
- `atc_bounds.erl` implements SRS014
- `atc_audit.erl` implements SRS016
- `atc_phraseology.erl` implements IRS001

Example airport TOML at [config/example-airport.toml](config/example-airport.toml).

PropEr state machine in [apps/atc_tower/test/prop_clearance.erl](apps/atc_tower/test/prop_clearance.erl), plus Common Test for TOML, runway designation, n equals 1, and the partition case. Operational audit logs are in scope. Debug prints are not.

## Tooling

Install StrictDoc into a project virtualenv. The MCP server currently points at a missing `/usr/local/bin/strictdoc`; use the virtualenv CLI. Add a top-level [Makefile](Makefile) with `clean`, `build`, `run`, `test`, `help`, and `strictdoc-init`, `strictdoc-generate`, `strictdoc-validate`, `strictdoc-export`, `strictdoc-serve`, `strictdoc-tree`, `strictdoc-help`. Add `tla-check` for TLC. Userspace installs only, no sudo.

[.gitignore](.gitignore) includes the required LaTeX artifact patterns and ignores the virtualenv, Rebar build output, and TLC scratch files. It does not ignore [reqs/](reqs/) or [plans/](plans/).

A hook script at [scripts/git-hooks/pre-commit](scripts/git-hooks/pre-commit) runs `make strictdoc-generate` when `.sdoc` files are staged, and is installed to `.git/hooks/pre-commit`.

## Commits

The first execution step saves this plan under [plans/](plans/). Before the first commit, set the local repository git identity to `$(whoami) | Cursor.sh | Grok 4.7` and `$(whoami)@$(hostname).local`. Sync upstream when that remote exists; otherwise fetch origin. Push after each commit when a remote exists.

Each new file is its own commit. Exceptions used here: an `.sdoc` fragment together with the generated HTML for that fragment; a fragment together with the source file that implements it; a fragment, its source, and the plan checkbox when that checkbox is exactly the work in those files. Commit messages use the project format. Until the first `.sdoc` exists, the requirements section says `None`. After that, every commit names the UID it specifies, implements, or verifies. Do not put `!` in commit text.

## Honest limit

TLC explores a finite airport. PropEr samples the Erlang state machine. The refinement document is the argument that those two describe the same transitions, and it will list what remains unproved. The software refuses traffic outside the checked envelope instead of implying the proof is unbounded.