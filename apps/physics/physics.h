#ifndef AIRTRAFFICCONTROL_PHYSICS_H
#define AIRTRAFFICCONTROL_PHYSICS_H

/* Climb, cruise, descent, and one great-circle step.
   phase: 0 climb, 1 cruise, 2 descent, 3 done.
   A PhysCourse is an ATC amendment projected on top of that model.
   guidance 0 tracks the route. guidance 1 flies heading_deg.
   use_alt 0 follows the route profile. use_alt 1 levels at assigned_alt_ft.
   use_tas 0 uses the phase speed. use_tas 1 flies assigned_tas_kt. */

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

typedef struct PhysCourse {
    double heading_deg;
    double assigned_alt_ft;
    double assigned_tas_kt;
    int guidance;
    int use_alt;
    int use_tas;
    int pad;
} PhysCourse;

int phys_state_size(void);
int phys_course_size(void);
void phys_step(PhysState *state, const PhysRoute *route, double dt_s);
void phys_step_course(PhysState *state, const PhysRoute *route, const PhysCourse *course, double dt_s);
int phys_project(const PhysState *start, const PhysRoute *route, const PhysCourse *course,
                 double dt_s, int steps, PhysState *out);

#endif
