#include "physics.h"

#include "erl_nif.h"

#include <stdlib.h>

static int map_number(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, double *out) {
    ERL_NIF_TERM value;
    ErlNifSInt64 whole;

    if (!enif_get_map_value(env, map, enif_make_atom(env, key), &value)) {
        return 0;
    }
    if (enif_get_double(env, value, out)) {
        return 1;
    }
    if (enif_get_int64(env, value, &whole)) {
        *out = (double)whole;
        return 1;
    }
    return 0;
}

static int map_bool(ErlNifEnv *env, ERL_NIF_TERM map, const char *key, int *out) {
    ERL_NIF_TERM value;
    if (!enif_get_map_value(env, map, enif_make_atom(env, key), &value)) {
        return 0;
    }
    if (enif_is_identical(value, enif_make_atom(env, "true"))) {
        *out = 1;
        return 1;
    }
    if (enif_is_identical(value, enif_make_atom(env, "false"))) {
        *out = 0;
        return 1;
    }
    return 0;
}

static int read_state(ErlNifEnv *env, ERL_NIF_TERM map, PhysState *state) {
    double phase;
    if (!map_number(env, map, "lat_deg", &state->lat_deg) ||
        !map_number(env, map, "lon_deg", &state->lon_deg) ||
        !map_number(env, map, "alt_ft", &state->alt_ft) ||
        !map_number(env, map, "heading_deg", &state->heading_deg) ||
        !map_number(env, map, "tas_kt", &state->tas_kt) ||
        !map_number(env, map, "vertical_fpm", &state->vertical_fpm) ||
        !map_number(env, map, "distance_nm", &state->distance_nm) ||
        !map_number(env, map, "distance_remaining_nm", &state->distance_remaining_nm) ||
        !map_number(env, map, "phase", &phase)) {
        return 0;
    }
    state->phase = (int)phase;
    state->pad = 0;
    return 1;
}

static int read_route(ErlNifEnv *env, ERL_NIF_TERM map, PhysRoute *route) {
    return map_number(env, map, "origin_lat", &route->origin_lat) &&
           map_number(env, map, "origin_lon", &route->origin_lon) &&
           map_number(env, map, "origin_alt_ft", &route->origin_alt_ft) &&
           map_number(env, map, "dest_lat", &route->dest_lat) &&
           map_number(env, map, "dest_lon", &route->dest_lon) &&
           map_number(env, map, "dest_alt_ft", &route->dest_alt_ft) &&
           map_number(env, map, "cruise_alt_ft", &route->cruise_alt_ft) &&
           map_number(env, map, "climb_fpm", &route->climb_fpm) &&
           map_number(env, map, "descent_fpm", &route->descent_fpm) &&
           map_number(env, map, "climb_tas_kt", &route->climb_tas_kt) &&
           map_number(env, map, "cruise_tas_kt", &route->cruise_tas_kt) &&
           map_number(env, map, "descent_tas_kt", &route->descent_tas_kt);
}

static int read_course(ErlNifEnv *env, ERL_NIF_TERM map, PhysCourse *course) {
    ERL_NIF_TERM guidance;
    course->pad = 0;
    if (!enif_get_map_value(env, map, enif_make_atom(env, "guidance"), &guidance)) {
        return 0;
    }
    if (enif_is_identical(guidance, enif_make_atom(env, "heading"))) {
        course->guidance = 1;
    } else if (enif_is_identical(guidance, enif_make_atom(env, "track"))) {
        course->guidance = 0;
    } else {
        return 0;
    }
    return map_number(env, map, "heading_deg", &course->heading_deg) &&
           map_number(env, map, "assigned_alt_ft", &course->assigned_alt_ft) &&
           map_number(env, map, "assigned_tas_kt", &course->assigned_tas_kt) &&
           map_bool(env, map, "use_alt", &course->use_alt) &&
           map_bool(env, map, "use_tas", &course->use_tas);
}

static ERL_NIF_TERM sample_term(ErlNifEnv *env, const PhysState *state, double t_s) {
    ERL_NIF_TERM keys[10];
    ERL_NIF_TERM values[10];
    ERL_NIF_TERM map;

    keys[0] = enif_make_atom(env, "t_s");
    keys[1] = enif_make_atom(env, "lat_deg");
    keys[2] = enif_make_atom(env, "lon_deg");
    keys[3] = enif_make_atom(env, "alt_ft");
    keys[4] = enif_make_atom(env, "heading_deg");
    keys[5] = enif_make_atom(env, "tas_kt");
    keys[6] = enif_make_atom(env, "vertical_fpm");
    keys[7] = enif_make_atom(env, "distance_nm");
    keys[8] = enif_make_atom(env, "distance_remaining_nm");
    keys[9] = enif_make_atom(env, "phase");
    values[0] = enif_make_double(env, t_s);
    values[1] = enif_make_double(env, state->lat_deg);
    values[2] = enif_make_double(env, state->lon_deg);
    values[3] = enif_make_double(env, state->alt_ft);
    values[4] = enif_make_double(env, state->heading_deg);
    values[5] = enif_make_double(env, state->tas_kt);
    values[6] = enif_make_double(env, state->vertical_fpm);
    values[7] = enif_make_double(env, state->distance_nm);
    values[8] = enif_make_double(env, state->distance_remaining_nm);
    values[9] = enif_make_int(env, state->phase);
    if (!enif_make_map_from_arrays(env, keys, values, 10, &map)) {
        return enif_make_badarg(env);
    }
    return map;
}

static ERL_NIF_TERM nif_project(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    PhysState start;
    PhysRoute route;
    PhysCourse course;
    PhysState *out;
    double dt;
    int steps;
    int wrote;
    int i;
    ERL_NIF_TERM *cells;
    ERL_NIF_TERM list;

    if (argc != 5 || !read_state(env, argv[0], &start) || !read_route(env, argv[1], &route) ||
        !read_course(env, argv[2], &course)) {
        return enif_make_badarg(env);
    }
    if (!enif_get_double(env, argv[3], &dt)) {
        ErlNifSInt64 whole;
        if (!enif_get_int64(env, argv[3], &whole)) {
            return enif_make_badarg(env);
        }
        dt = (double)whole;
    }
    if (!enif_get_int(env, argv[4], &steps) || steps < 1 || steps > 400 || dt <= 0.0 || dt > 120.0) {
        return enif_make_badarg(env);
    }
    out = enif_alloc((size_t)steps * sizeof(PhysState));
    cells = enif_alloc((size_t)steps * sizeof(ERL_NIF_TERM));
    if (out == 0 || cells == 0) {
        enif_free(out);
        enif_free(cells);
        return enif_make_badarg(env);
    }
    wrote = phys_project(&start, &route, &course, dt, steps, out);
    if (wrote != steps) {
        enif_free(out);
        enif_free(cells);
        return enif_make_badarg(env);
    }
    for (i = 0; i < steps; i++) {
        cells[i] = sample_term(env, &out[i], ((double)(i + 1)) * dt);
    }
    list = enif_make_list_from_array(env, cells, (unsigned)steps);
    enif_free(out);
    enif_free(cells);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), list);
}

static ErlNifFunc funcs[] = {
    {"nif", 5, nif_project, 0}
};

ERL_NIF_INIT(atc_physics, funcs, 0, 0, 0, 0)
