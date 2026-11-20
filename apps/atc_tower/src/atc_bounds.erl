%%%-------------------------------------------------------------------
%%% @doc Checked envelope for one airport.
%%% Implements: SRS014
%%% @relation(SRS014, scope=file)
%%%-------------------------------------------------------------------
-module(atc_bounds).

-export([check/1, limits/0]).

-define(MAX_RUNWAYS, 4).
-define(MAX_AIRCRAFT, 8).
-define(MAX_NEIGHBORS, 2).

%% Implements: SRS014
%% @relation(SRS014, scope=line)
limits() ->
    #{
        max_runways => ?MAX_RUNWAYS,
        max_aircraft => ?MAX_AIRCRAFT,
        max_neighbors => ?MAX_NEIGHBORS
    }.

%% Implements: SRS014
%% @relation(SRS014, scope=line)
check(Config) ->
    Runways = maps:size(maps:get(runways, Config)),
    Neighbors = length(maps:get(neighbors, Config)),
    MaxRunways = maps:get(max_runways, Config),
    MaxAircraft = maps:get(max_aircraft, Config),
    MaxNeighbors = maps:get(max_neighbors, Config),
    Computers = maps:get(computers, Config),
    case
        Runways =< ?MAX_RUNWAYS andalso
            Runways =< MaxRunways andalso
            Neighbors =< ?MAX_NEIGHBORS andalso
            Neighbors =< MaxNeighbors andalso
            MaxRunways =< ?MAX_RUNWAYS andalso
            MaxAircraft =< ?MAX_AIRCRAFT andalso
            MaxAircraft > 0 andalso
            MaxNeighbors =< ?MAX_NEIGHBORS andalso
            is_integer(Computers) andalso Computers > 0
    of
        true ->
            ok;
        false ->
            {error, envelope}
    end.
