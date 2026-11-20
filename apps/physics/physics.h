#ifndef AIRTRAFFICCONTROL_PHYSICS_H
#define AIRTRAFFICCONTROL_PHYSICS_H

/* Climb, cruise, descent, and one great-circle step.
   phase: 0 climb, 1 cruise, 2 descent, 3 done. */

typedef struct PhysState {
    double lat_deg;
    double lon_deg;
    double alt_ft;
    double heading_deg;
    double tas_kt;
    double vertical_fpm;
    double distance_nm;
    double distance_remaining_nm;
    int phase;
    int pad;
} PhysState;

typedef struct PhysRoute {
    double origin_lat;
    double origin_lon;
    double origin_alt_ft;
    double dest_lat;
    double dest_lon;
    double dest_alt_ft;
    double cruise_alt_ft;
    double climb_fpm;
    double descent_fpm;
    double climb_tas_kt;
    double cruise_tas_kt;
    double descent_tas_kt;
} PhysRoute;

int phys_state_size(void);
void phys_step(PhysState *state, const PhysRoute *route, double dt_s);

#endif
