%%%-------------------------------------------------------------------
%%% @doc Training limits sit beside the checked 4, 8, and 2 envelope.
%%% Implements: SRS021
%%% @relation(SRS021, scope=file)
%%%-------------------------------------------------------------------
-module(atc_profile).

-export([limits/1, check/2]).

%% Implements: SRS021
%% @relation(SRS021, scope=line)
limits(checked) ->
    atc_bounds:limits();
limits(training) ->
    #{max_runways => 12, max_aircraft => 64, max_neighbors => 8}.

%% Implements: SRS021
%% @relation(SRS021, scope=line)
check(checked, Config) ->
    atc_bounds:check(Config);
check(training, Config) ->
    Limits = limits(training),
    Runways = maps:size(maps:get(runways, Config, #{})),
    Neighbors = length(maps:get(neighbors, Config, [])),
    MaxRunways = maps:get(max_runways, Config),
    MaxAircraft = maps:get(max_aircraft, Config),
    MaxNeighbors = maps:get(max_neighbors, Config),
    Computers = maps:get(computers, Config, 1),
    case
        fits(Runways, MaxRunways, maps:get(max_runways, Limits)) andalso
            fits(Neighbors, MaxNeighbors, maps:get(max_neighbors, Limits)) andalso
            is_integer(MaxAircraft) andalso MaxAircraft > 0 andalso
            MaxAircraft =< maps:get(max_aircraft, Limits) andalso
            is_integer(Computers) andalso Computers > 0
    of
        true -> ok;
        false -> {error, envelope}
    end.

fits(Count, Configured, Cap) ->
    is_integer(Count) andalso is_integer(Configured) andalso is_integer(Cap) andalso
        Count =< Cap andalso Count =< Configured andalso Configured =< Cap andalso
        Configured > 0.
