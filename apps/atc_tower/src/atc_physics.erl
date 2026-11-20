%%%-------------------------------------------------------------------
%%% @doc Project a flight with the C physics model.
%%% Implements: SRS026
%%% @relation(SRS026, scope=file)
%%%-------------------------------------------------------------------
-module(atc_physics).

-export([project/5]).

-on_load(load/0).

%% Implements: SRS026
%% @relation(SRS026, scope=line)
project(State, Route, Course, Dt, Steps) ->
    nif(state_map(State), route_map(Route), course_map(Course), float(Dt), Steps).

nif(_State, _Route, _Course, _Dt, _Steps) ->
    erlang:nif_error(atc_physics_nif).

load() ->
    erlang:load_nif(filename:join(priv_dir(), "atc_physics"), 0).

priv_dir() ->
    case code:priv_dir(atc_tower) of
        {error, _} ->
            filename:join([filename:dirname(code:which(?MODULE)), "..", "priv"]);
        Dir ->
            Dir
    end.

state_map(State) ->
    #{
        lat_deg => number(State, lat_deg, 0.0),
        lon_deg => number(State, lon_deg, 0.0),
        alt_ft => number(State, alt_ft, 0.0),
        heading_deg => number(State, heading_deg, 0.0),
        tas_kt => number(State, tas_kt, 0.0),
        vertical_fpm => number(State, vertical_fpm, 0.0),
        distance_nm => number(State, distance_nm, 0.0),
        distance_remaining_nm => number(State, distance_remaining_nm, 0.0),
        phase => trunc(number(State, phase, 1))
    }.

route_map(Route) ->
    #{
        origin_lat => number(Route, origin_lat, 0.0),
        origin_lon => number(Route, origin_lon, 0.0),
        origin_alt_ft => number(Route, origin_alt_ft, 0.0),
        dest_lat => number(Route, dest_lat, 0.0),
        dest_lon => number(Route, dest_lon, 0.0),
        dest_alt_ft => number(Route, dest_alt_ft, 0.0),
        cruise_alt_ft => number(Route, cruise_alt_ft, 0.0),
        climb_fpm => number(Route, climb_fpm, 0.0),
        descent_fpm => number(Route, descent_fpm, 0.0),
        climb_tas_kt => number(Route, climb_tas_kt, 0.0),
        cruise_tas_kt => number(Route, cruise_tas_kt, 0.0),
        descent_tas_kt => number(Route, descent_tas_kt, 0.0)
    }.

course_map(Course) ->
    #{
        guidance => maps:get(guidance, Course, track),
        heading_deg => number(Course, heading_deg, 0.0),
        use_alt => maps:get(use_alt, Course, false) =:= true,
        assigned_alt_ft => number(Course, assigned_alt_ft, 0.0),
        use_tas => maps:get(use_tas, Course, false) =:= true,
        assigned_tas_kt => number(Course, assigned_tas_kt, 0.0)
    }.

number(Map, Key, Default) ->
    float(maps:get(Key, Map, Default)).
