#include "physics.h"

#include <math.h>

#define EARTH_RADIUS_NM 3440.065
#define PHASE_CLIMB 0
#define PHASE_CRUISE 1
#define PHASE_DESCENT 2
#define PHASE_DONE 3

static double deg2rad(double degrees) {
    return degrees * 3.14159265358979323846 / 180.0;
}

static double rad2deg(double radians) {
    return radians * 180.0 / 3.14159265358979323846;
}

static double wrap_lon(double degrees) {
    while (degrees > 180.0) {
        degrees -= 360.0;
    }
    while (degrees < -180.0) {
        degrees += 360.0;
    }
    return degrees;
}

static double remaining_nm(const PhysState *state, const PhysRoute *route) {
    double lat1 = deg2rad(state->lat_deg);
    double lon1 = deg2rad(state->lon_deg);
    double lat2 = deg2rad(route->dest_lat);
    double lon2 = deg2rad(route->dest_lon);
    double dlat = lat2 - lat1;
    double dlon = lon2 - lon1;
    double a = sin(dlat / 2.0) * sin(dlat / 2.0) +
               cos(lat1) * cos(lat2) * sin(dlon / 2.0) * sin(dlon / 2.0);
    return EARTH_RADIUS_NM * 2.0 * atan2(sqrt(a), sqrt(1.0 - a));
}

static double bearing_rad(const PhysState *state, const PhysRoute *route) {
    double lat1 = deg2rad(state->lat_deg);
    double lat2 = deg2rad(route->dest_lat);
    double dlon = deg2rad(route->dest_lon - state->lon_deg);
    double y = sin(dlon) * cos(lat2);
    double x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dlon);
    return atan2(y, x);
}

static void advance(PhysState *state, double bearing, double step_nm) {
    double angular = step_nm / EARTH_RADIUS_NM;
    double lat1 = deg2rad(state->lat_deg);
    double lon1 = deg2rad(state->lon_deg);
    double lat2 = asin(
        sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing)
    );
    double lon2 = lon1 + atan2(
        sin(bearing) * sin(angular) * cos(lat1),
        cos(angular) - sin(lat1) * sin(lat2)
    );
    state->lat_deg = rad2deg(lat2);
    state->lon_deg = wrap_lon(rad2deg(lon2));
    state->heading_deg = wrap_lon(rad2deg(bearing));
}

static void snap(PhysState *state, const PhysRoute *route, double remaining) {
    state->lat_deg = route->dest_lat;
    state->lon_deg = route->dest_lon;
    state->alt_ft = route->dest_alt_ft;
    state->tas_kt = 0.0;
    state->vertical_fpm = 0.0;
    state->distance_nm += remaining;
    state->distance_remaining_nm = 0.0;
    state->phase = PHASE_DONE;
}

int phys_state_size(void) {
    return (int)sizeof(PhysState);
}

void phys_step(PhysState *state, const PhysRoute *route, double dt_s) {
    double remaining;
    double descent_nm;
    double tas;
    double step_nm;
    double bearing;

    if (state->phase == PHASE_DONE || dt_s <= 0.0) {
        return;
    }
    remaining = remaining_nm(state, route);
    if (state->phase != PHASE_DESCENT &&
        state->alt_ft + 1.0 < route->cruise_alt_ft) {
        state->phase = PHASE_CLIMB;
    } else if (state->phase != PHASE_DESCENT) {
        descent_nm = ((route->cruise_alt_ft - route->dest_alt_ft) / route->descent_fpm) *
                     (route->descent_tas_kt / 60.0);
        state->phase = remaining <= descent_nm ? PHASE_DESCENT : PHASE_CRUISE;
    }
    if (state->phase == PHASE_CLIMB) {
        tas = route->climb_tas_kt;
        state->vertical_fpm = route->climb_fpm;
    } else if (state->phase == PHASE_DESCENT) {
        tas = route->descent_tas_kt;
        state->vertical_fpm = -route->descent_fpm;
    } else {
        tas = route->cruise_tas_kt;
        state->vertical_fpm = 0.0;
    }
    state->tas_kt = tas;
    step_nm = tas * dt_s / 3600.0;
    if (step_nm >= remaining) {
        snap(state, route, remaining);
        return;
    }
    state->alt_ft += state->vertical_fpm * (dt_s / 60.0);
    if (state->phase == PHASE_CLIMB && state->alt_ft > route->cruise_alt_ft) {
        state->alt_ft = route->cruise_alt_ft;
    }
    if (state->phase == PHASE_DESCENT && state->alt_ft < route->dest_alt_ft) {
        state->alt_ft = route->dest_alt_ft;
        state->vertical_fpm = 0.0;
    }
    bearing = bearing_rad(state, route);
    advance(state, bearing, step_nm);
    state->distance_nm += step_nm;
    state->distance_remaining_nm = remaining_nm(state, route);
}
