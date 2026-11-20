<!-- @relation(SDD003, SSS008, scope=file) -->

# Refinement mapping from the Tower CSCI to AtcTower

This note is the refinement argument required by SDD003 and SSS008. It is a review argument. It is not a machine-checked proof that the Erlang code refines the TLA+ specification.

## What TLA+ establishes

`specs/tla/AtcTower.tla` defines the clearance actions and the invariant `Inv`. TLC checks `Inv` on the finite instance in `specs/tla/AtcTower.cfg`: two aircraft, two runways, one conflict pair, and one runway restricted to arrival. The 2026-11-20 run reported 414 distinct states, depth 8, and no invariant violation. That run verifies SSS001, SSS007, and SRS013 for that instance only.

`Inv` is the conjunction of:

- `TypeOK`, the phases `out`, `queued`, `hold`, `occupying`, `air`, and `gone`
- `Exclusive`, at most one occupying aircraft in a runway or a conflicting runway
- `HeadOnly`, an occupying aircraft is the head of that runway sequence
- `NoClosedOccupancy`, an occupying aircraft is not on a closed runway

Handoff is enabled only when `linkUp` is true. Link loss is the action `LinkDown`.

## Variable mapping

| Erlang field in `atc_separation` | TLA+ variable | Remark |
| --- | --- | --- |
| `aircraft[Id].phase` | `phase[Id]` | Same phase names |
| `aircraft[Id].runway` | `runwayOf[Id]` | Erlang `none` is TLA+ `"NONE"` |
| `aircraft[Id].intent` | `intent[Id]` | `arrival` or `departure` |
| `seq[Runway]` | `seq[Runway]` | Erlang list head is TLA+ index 1 |
| `links[Neighbor]` | `linkUp` | The model has one link. Erlang has one flag per neighbor. A down neighbor disables only that neighbor's handoff. |
| issued `log` | the sequence of successful actions | Refusals are audit records and are not successful actions |
| `audit` | none | Operational traceability, outside the safety model |

Action names match. `assign`, `hold_short`, `line_up`, `takeoff`, `land`, `vacate`, `go_around`, and `handoff` in `atc_separation:transition/2` are the Erlang forms of `Assign`, `HoldShort`, `LineUp`, `Takeoff`, `Land`, `Vacate`, `GoAround`, and `Handoff`.

## Assumptions the mapping depends on

- Ra delivers one ordered log of issued commands. Raft is not proved in this repository. See SDD004.
- A restarted member does not issue until it has the committed prefix. The pure cluster model and the PropEr samples check that policy. They do not prove Ra's log.
- Neighbor messages are not authenticated beyond the process boundary of this CSCI.
- An aircraft occupies one protected region at a time. Wake, speed, and timing are not in the model.
- The operator stays inside the envelope of 4 runways, 8 aircraft, and 2 neighbors. SRS014 refuses a larger picture.

## Open obligations

These items are not discharged. They must stay open.

1. There is no machine-checked refinement proof from `atc_separation` to `AtcTower`. PropEr samples the Erlang transition and is conformance evidence only.
2. TLC checks 2 aircraft and 2 runways. The software accepts up to 8 aircraft and 4 runways. The larger bound is the same transition system, but it is not the instance TLC explores.
3. Erlang per-neighbor link flags are a family of the single `linkUp` flag. The correspondence for two neighbors at once is by review, not by a TLC instance.
4. Ra linearizability and leader completeness are assumed.
5. Great-circle neighbor distance is outside the TLA+ model. It only chooses which link exists.
6. Phrase text is outside the safety model. IRS001 checks that the fields and the phrase agree. The wording is not a formal action.
