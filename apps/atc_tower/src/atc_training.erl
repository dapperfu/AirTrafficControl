%%%-------------------------------------------------------------------
%%% @doc Sharded training demand, record and replay, injects, and scores.
%%% Implements: SRS024
%%% Implements: SRS025
%%% @relation(SRS024, SRS025, scope=file)
%%%-------------------------------------------------------------------
-module(atc_training).

-export([shard/2, demand/1, inject/3, record/1, replay/1, score/1, peak/1]).

%% Implements: SRS024
%% @relation(SRS024, scope=line)
shard(Airports, national) ->
    lists:sort(Airports);
shard(Airports, {region, Prefix}) when is_binary(Prefix) ->
    lists:sort([
        Airport
     || Airport <- Airports, binary:longest_common_prefix([Airport, Prefix]) =:= byte_size(Prefix)
    ]);
shard(Airports, {airport, Id}) ->
    [Id || lists:member(Id, Airports)].

%% Implements: SRS024
%% @relation(SRS024, scope=line)
demand(#{airport := Airport, airline := Pairs, ga := Count}) ->
    Airline = [
        #{kind => airline, airport => Airport, origin => Origin, dest => Dest}
     || {Origin, Dest} <- Pairs
    ],
    Ga = [
        #{kind => ga, airport => Airport, id => Index}
     || Index <- lists:seq(1, Count)
    ],
    Airline ++ Ga.

%% Implements: SRS024
%% @relation(SRS024, scope=line)
inject(World, emergency, Aircraft) ->
    atc_world:add_emergency(World, Aircraft);
inject(World, nordo, Aircraft) ->
    atc_world:add_nordo(World, Aircraft);
inject(World, vehicle, Vehicle) ->
    atc_world:add_vehicle(World, Vehicle);
inject(World, deviation, Aircraft) ->
    atc_world:publish_track(World, #{
        id => Aircraft,
        time_s => maps:get(time_s, World),
        deviation => true
    });
inject(World, weather, Weather) ->
    atc_world:set_weather(World, Weather).

record(Events) when is_list(Events) ->
    Events.

replay(Events) when is_list(Events) ->
    Events.

%% Implements: SRS024
%% @relation(SRS024, scope=line)
score(Events) when is_list(Events) ->
    #{
        losses => count(Events, <<"loss">>),
        incursions => count(Events, <<"incursion">>),
        deferred => count(Events, <<"deferred">>),
        radio_s => lists:sum([maps:get(radio_s, Event, 0) || Event <- Events])
    }.

%% Implements: SRS025
%% @relation(SRS025, scope=line)
peak(Count) when is_integer(Count), Count > 8 ->
    Runway = <<"27">>,
    Runways = #{Runway => #{designation => both, independent => true, intersects => []}},
    Limits = atc_profile:limits(training),
    Sep0 = atc_separation:new(#{
        runways => Runways,
        max_aircraft => maps:get(max_aircraft, Limits)
    }),
    World0 = atc_world:new(#{runways => Runways}),
    Ids = [iolist_to_binary(io_lib:format("N~3..0B", [Index])) || Index <- lists:seq(1, Count)],
    {_Sep, _World, Issued} = lists:foldl(
        fun(Id, {Sep, World, SoFar}) ->
            World1 = atc_world:publish_track(World, #{
                id => Id,
                time_s => 0,
                runway => Runway,
                intent => departure,
                wake => small,
                x_ft => 3000.0,
                y_ft => 400.0
            }),
            case atc_policy:propose(Sep, World1, {taxi, Id}) of
                {issue, Command} ->
                    {ok, Next, _Rec} = atc_separation:transition(Sep, Command),
                    {Next, atc_world:note_issued(World1, Next, Command), SoFar + 1};
                {defer, Package} ->
                    {Sep, atc_world:push_exception(World1, Package), SoFar}
            end
        end,
        {Sep0, World0, 0},
        Ids
    ),
    #{
        aircraft => Count,
        issued => Issued,
        checked => atc_bounds:limits()
    }.

count(Events, Kind) ->
    length([Event || Event <- Events, maps:get(kind, Event, none) =:= Kind]).
