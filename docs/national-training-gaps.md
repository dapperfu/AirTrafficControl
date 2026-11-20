# Residual gaps after the national tower training increment

This software is a simulation. It is not a certified tower, STARS, ERAM, or ASDE-X, and it does not connect to a live NAS or a radio.

The checked proof stays the discrete model of 4 runways, 8 aircraft, and 2 neighbors. Training runs use a separate limit set. Scenario tests cover the continuous probe.

## Still outside this increment

- Full approach control. An approach neighbor can accept a handoff and a release. It does not vector, sequence a TRACON, or provide radar separation.
- Enroute separation. The great-circle leg flies a city pair. It does not separate an enroute sector.
- LAHSO. A land-and-hold-short case is detected and placed on the exception queue. It is not auto-issued.
- PRM. Precision runway monitoring is not modeled.
- Visual-separation judgment. A visual-separation request is detected and deferred. The controller decides it.
- Opposite-direction and intersection departures. They are detected and deferred, not auto-issued.
- Live NAS connection. Demand comes from fixtures or a downloaded catalog. There is no operational feed.
- Certification. Nothing in this repository is a certification claim or an operational approval.
- Helicopters. The fixed-wing pattern is the training pattern. A helicopter model was not added.
- Rich published taxi graphs and historical-track replay. Towers in the tests use the synthetic runway, parallel, and connectors. Bulk historical tracks stay out of git.

## What the training software does do

Routine taxi, hold-short, line-up, takeoff, landing, and vacate are proposed only when the conflict probe and the separation guard agree. The guard is the only writer of an issued clearance. Anything else waits on the exception queue for the existing tower window.
