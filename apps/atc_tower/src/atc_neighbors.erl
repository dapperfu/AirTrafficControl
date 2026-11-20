%%%-------------------------------------------------------------------
%%% @doc Neighbor selection and fail-smart link policy.
%%% Implements: SRS005
%%% Implements: SRS006
%%% Implements: SRS007
%%% @relation(SRS005, SRS006, SRS007, scope=file)
%%%-------------------------------------------------------------------
-module(atc_neighbors).

-export([selected/1, distance_nm/2, link_up/2, within/2]).

-define(EARTH_RADIUS_NM, 3440.065).

%% Implements: SRS005
%% @relation(SRS005, scope=line)
selected(Config) ->
    lists:filter(fun(Neighbor) -> within(Config, Neighbor) end, maps:get(neighbors, Config)).

%% Implements: SRS005
%% @relation(SRS005, scope=line)
within(Config, Neighbor) ->
    distance_nm(Config, Neighbor) =< maps:get(communications_distance_nm, Config).

distance_nm(Config, Neighbor) ->
    haversine(
        maps:get(latitude, Config),
        maps:get(longitude, Config),
        maps:get(latitude, Neighbor),
        maps:get(longitude, Neighbor)
    ).

%% Implements: SRS006
%% Implements: SRS007
%% @relation(SRS006, SRS007, scope=line)
link_up(State, Neighbor) ->
    maps:get(Neighbor, maps:get(links, State), false) andalso
        not atc_separation:stale(State, Neighbor).

haversine(Lat1, Lon1, Lat2, Lon2) ->
    DLat = deg2rad(Lat2 - Lat1),
    DLon = deg2rad(Lon2 - Lon1),
    A =
        math:sin(DLat / 2) * math:sin(DLat / 2) +
            math:cos(deg2rad(Lat1)) * math:cos(deg2rad(Lat2)) *
                math:sin(DLon / 2) * math:sin(DLon / 2),
    C = 2 * math:atan2(math:sqrt(A), math:sqrt(1 - A)),
    ?EARTH_RADIUS_NM * C.

deg2rad(Degrees) ->
    Degrees * math:pi() / 180.
