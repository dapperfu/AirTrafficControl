------------------------------ MODULE AtcTower ------------------------------
\* Verifies: SSS001, SSS007, SRS013
\* @relation(SSS001, SSS007, SRS013, scope=file)
\* Finite model of tower clearances. TLC checks that every enabled action
\* preserves exclusive runway occupancy, head-of-queue occupancy, and the
\* closed-runway ban. Neighbor handoff is enabled only while the link is up.

EXTENDS Integers, Sequences, FiniteSets, TLC

CONSTANTS a1, a2, r1, r2

Aircraft == {a1, a2}
Runways == {r1, r2}
\* r1 accepts arrival and departure. r2 is arrival only. The two runways conflict.
Designation == (r1 :> "both" @@ r2 :> "arrival")
Conflicts == {{r1, r2}}

VARIABLES phase, runwayOf, intent, seq, linkUp

vars == <<phase, runwayOf, intent, seq, linkUp>>

Phases == {"out", "queued", "hold", "occupying", "air", "gone"}
Intents == {"none", "arrival", "departure"}

TypeOK ==
  /\ phase \in [Aircraft -> Phases]
  /\ runwayOf \in [Aircraft -> Runways \cup {"NONE"}]
  /\ intent \in [Aircraft -> Intents]
  /\ seq \in [Runways -> Seq(Aircraft)]
  /\ linkUp \in BOOLEAN

RunwayAllows(r, want) ==
  /\ Designation[r] /= "closed"
  /\ \/ Designation[r] = "both"
     \/ Designation[r] = want

Conflicting(left, right) ==
  \/ left = right
  \/ {left, right} \in Conflicts

Occupied(r) ==
  \E a \in Aircraft :
    /\ phase[a] = "occupying"
    /\ runwayOf[a] \in Runways
    /\ Conflicting(runwayOf[a], r)

OnRunway(a) ==
  /\ runwayOf[a] \in Runways
  /\ Len(seq[runwayOf[a]]) > 0

IsHead(a) ==
  /\ OnRunway(a)
  /\ seq[runwayOf[a]][1] = a

Init ==
  /\ phase = [a \in Aircraft |-> "out"]
  /\ runwayOf = [a \in Aircraft |-> "NONE"]
  /\ intent = [a \in Aircraft |-> "none"]
  /\ seq = [r \in Runways |-> <<>>]
  /\ linkUp = TRUE

Assign(a, r, want) ==
  /\ phase[a] = "out"
  /\ RunwayAllows(r, want)
  /\ phase' = [phase EXCEPT ![a] = "queued"]
  /\ runwayOf' = [runwayOf EXCEPT ![a] = r]
  /\ intent' = [intent EXCEPT ![a] = want]
  /\ seq' = [seq EXCEPT ![r] = Append(@, a)]
  /\ UNCHANGED linkUp

HoldShort(a) ==
  /\ phase[a] = "queued"
  /\ phase' = [phase EXCEPT ![a] = "hold"]
  /\ UNCHANGED <<runwayOf, intent, seq, linkUp>>

LineUp(a) ==
  /\ phase[a] \in {"queued", "hold"}
  /\ intent[a] = "departure"
  /\ IsHead(a)
  /\ ~Occupied(runwayOf[a])
  /\ RunwayAllows(runwayOf[a], "departure")
  /\ phase' = [phase EXCEPT ![a] = "occupying"]
  /\ UNCHANGED <<runwayOf, intent, seq, linkUp>>

Takeoff(a) ==
  /\ phase[a] = "occupying"
  /\ intent[a] = "departure"
  /\ IsHead(a)
  /\ RunwayAllows(runwayOf[a], "departure")
  /\ phase' = [phase EXCEPT ![a] = "air"]
  /\ seq' = [seq EXCEPT ![runwayOf[a]] = Tail(@)]
  /\ UNCHANGED <<runwayOf, intent, linkUp>>

Land(a) ==
  /\ phase[a] \in {"queued", "hold"}
  /\ intent[a] = "arrival"
  /\ IsHead(a)
  /\ RunwayAllows(runwayOf[a], "arrival")
  /\ ~Occupied(runwayOf[a])
  /\ phase' = [phase EXCEPT ![a] = "occupying"]
  /\ UNCHANGED <<runwayOf, intent, seq, linkUp>>

Vacate(a) ==
  /\ phase[a] = "occupying"
  /\ intent[a] = "arrival"
  /\ IsHead(a)
  /\ phase' = [phase EXCEPT ![a] = "out"]
  /\ runwayOf' = [runwayOf EXCEPT ![a] = "NONE"]
  /\ intent' = [intent EXCEPT ![a] = "none"]
  /\ seq' = [seq EXCEPT ![runwayOf[a]] = Tail(@)]
  /\ UNCHANGED linkUp

GoAround(a) ==
  /\ phase[a] = "occupying"
  /\ intent[a] = "arrival"
  /\ IsHead(a)
  /\ phase' = [phase EXCEPT ![a] = "air"]
  /\ seq' = [seq EXCEPT ![runwayOf[a]] = Tail(@)]
  /\ UNCHANGED <<runwayOf, intent, linkUp>>

Handoff(a) ==
  /\ linkUp
  /\ phase[a] \in {"out", "air", "queued", "hold"}
  /\ phase' = [phase EXCEPT ![a] = "gone"]
  /\ runwayOf' = [runwayOf EXCEPT ![a] = "NONE"]
  /\ intent' = [intent EXCEPT ![a] = "none"]
  /\ seq' = IF runwayOf[a] \in Runways
            THEN [seq EXCEPT ![runwayOf[a]] =
                    SelectSeq(@, LAMBDA x : x /= a)]
            ELSE seq
  /\ UNCHANGED linkUp

LinkDown ==
  /\ linkUp = TRUE
  /\ linkUp' = FALSE
  /\ UNCHANGED <<phase, runwayOf, intent, seq>>

LinkUpAct ==
  /\ linkUp = FALSE
  /\ linkUp' = TRUE
  /\ UNCHANGED <<phase, runwayOf, intent, seq>>

Next ==
  \/ \E a \in Aircraft, r \in Runways, want \in {"arrival", "departure"} :
       Assign(a, r, want)
  \/ \E a \in Aircraft : HoldShort(a)
  \/ \E a \in Aircraft : LineUp(a)
  \/ \E a \in Aircraft : Takeoff(a)
  \/ \E a \in Aircraft : Land(a)
  \/ \E a \in Aircraft : Vacate(a)
  \/ \E a \in Aircraft : GoAround(a)
  \/ \E a \in Aircraft : Handoff(a)
  \/ LinkDown
  \/ LinkUpAct

Spec == Init /\ [][Next]_vars

Exclusive ==
  \A a, b \in Aircraft :
    (a /= b /\ phase[a] = "occupying" /\ phase[b] = "occupying") =>
      ~Conflicting(runwayOf[a], runwayOf[b])

HeadOnly ==
  \A r \in Runways :
    \A a \in Aircraft :
      (phase[a] = "occupying" /\ runwayOf[a] = r) =>
        (Len(seq[r]) > 0 /\ seq[r][1] = a)

NoClosedOccupancy ==
  \A a \in Aircraft :
    phase[a] = "occupying" =>
      (runwayOf[a] \in Runways /\ Designation[runwayOf[a]] /= "closed")

Inv == TypeOK /\ Exclusive /\ HeadOnly /\ NoClosedOccupancy

=============================================================================
