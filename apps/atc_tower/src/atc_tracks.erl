%%%-------------------------------------------------------------------
%%% @doc Latest truth track for each aircraft. A publication is not a clearance.
%%% Implements: SRS017
%%% @relation(SRS017, scope=file)
%%%-------------------------------------------------------------------
-module(atc_tracks).

-export([new/0, publish/2, get/2, find/2, list/1, map/1]).

%% Implements: SRS017
%% @relation(SRS017, scope=line)
new() ->
    #{time_s => 0, tracks => #{}}.

%% Implements: SRS017
%% @relation(SRS017, scope=line)
publish(State, Track) when is_map(Track) ->
    Stored = normalize(Track),
    #{
        time_s => maps:get(time_s, Stored),
        tracks => maps:put(maps:get(id, Stored), Stored, maps:get(tracks, State))
    }.

get(State, Id) ->
    maps:get(Id, maps:get(tracks, State)).

find(State, Id) ->
    maps:get(Id, maps:get(tracks, State), none).

list(State) ->
    maps:values(maps:get(tracks, State)).

map(State) ->
    maps:get(tracks, State).

normalize(Track) ->
    #{
        id => maps:get(id, Track),
        time_s => number(maps:get(time_s, Track, 0)),
        x_ft => number(maps:get(x_ft, Track, 0)),
        y_ft => number(maps:get(y_ft, Track, 0)),
        alt_ft => number(maps:get(alt_ft, Track, 0)),
        vx_fps => number(maps:get(vx_fps, Track, 0)),
        vy_fps => number(maps:get(vy_fps, Track, 0)),
        wake => atc_wake:category(maps:get(wake, Track, small)),
        runway => maps:get(runway, Track, none),
        intent => maps:get(intent, Track, none),
        dist_ft => number(maps:get(dist_ft, Track, 0)),
        heading_deg => number(maps:get(heading_deg, Track, 0)),
        lahso => maps:get(lahso, Track, false) =:= true,
        visual => maps:get(visual, Track, false) =:= true,
        opposite => maps:get(opposite, Track, false) =:= true,
        intersection => maps:get(intersection, Track, false) =:= true,
        deviation => maps:get(deviation, Track, false) =:= true
    }.

number(Value) when is_number(Value) -> Value;
number(_) -> 0.
