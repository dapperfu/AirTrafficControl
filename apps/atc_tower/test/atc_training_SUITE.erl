%%%-------------------------------------------------------------------
%%% Verifies: SRS017, SRS018, SRS019, SRS020, SRS021, SRS022, SRS023, SRS024, SRS025
%%% @relation(SRS017, SRS018, SRS019, SRS020, SRS021, SRS022, SRS023, SRS024, SRS025, scope=file)
%%%-------------------------------------------------------------------
-module(atc_training_SUITE).

-export([all/0]).
-export([
    tracks/1,
    probe_and_policy/1,
    exception_queue/1,
    training_profile/1,
    pattern_memory/1,
    cab_memory/1,
    emergency_and_weather/1,
    phrase_audit/1,
    national_and_peak/1
]).

all() ->
    [
        tracks,
        probe_and_policy,
        exception_queue,
        training_profile,
        pattern_memory,
        cab_memory,
        emergency_and_weather,
        phrase_audit,
        national_and_peak
    ].

tracks(_Config) ->
    First = atc_tracks:publish(atc_tracks:new(), sample_track(<<"N1">>, 1)),
    Second = atc_tracks:publish(First, sample_track(<<"N1">>, 2)),
    Third = atc_tracks:publish(Second, sample_track(<<"N2">>, 2)),
    2 = maps:get(time_s, atc_tracks:get(Third, <<"N1">>)),
    2 = length(atc_tracks:list(Third)),
    Sep = atc_separation:new(#{runways => runways(), max_aircraft => 8}),
    [] = atc_separation:issued(Sep).

probe_and_policy(_Config) ->
    Sep0 = fresh(),
    World0 = atc_world:new(#{runways => runways()}),
    Graph = maps:get(taxi, World0),
    4 = length([Node || Node <- maps:get(nodes, Graph), maps:get(runway, Node) =:= <<"27">>]),
    {X, Y} = atc_taxi:point(Graph, <<"27">>, 1000.0),
    true = atc_taxi:on_runway(Graph, <<"27">>, X, Y),
    WorldV = atc_world:add_vehicle(World0, #{
        id => <<"V1">>, x_ft => X, y_ft => Y, runway => <<"27">>, cleared => false
    }),
    {ok, Sep1, _} = atc_separation:transition(Sep0, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, Sep2, _} = atc_separation:transition(Sep1, {hold_short, <<"N1">>}),
    {conflict, #{incursion := true}} = atc_probe:assess(Sep2, WorldV, {line_up, <<"N1">>}),
    {defer, Conflict} = atc_policy:propose(Sep2, WorldV, {line_up, <<"N1">>}),
    conflict = maps:get(reason, Conflict),
    [] = [
        Rec
     || Rec <- atc_separation:issued(Sep2), maps:get(command, Rec) =:= {line_up, <<"N1">>}
    ],
    WorldI = atc_world:publish_track(World0, #{
        id => <<"N1">>, intersection => true, runway => <<"27">>, time_s => 0
    }),
    {defer, intersection} = atc_probe:assess(Sep2, WorldI, {takeoff, <<"N1">>}),
    WorldO = atc_world:publish_track(World0, #{
        id => <<"N9">>, runway => <<"09">>, intent => arrival, time_s => 0
    }),
    {defer, opposite} = atc_probe:assess(Sep2, WorldO, {takeoff, <<"N1">>}),
    WorldT = atc_world:publish_track(
        World0#{windows => #{<<"27">> => #{free_at => 400, wake => heavy, id => <<"LEAD">>}}},
        #{id => <<"N2">>, runway => <<"27">>, wake => small, time_s => 0}
    ),
    {conflict, _} = atc_probe:assess(Sep0, WorldT, {takeoff, <<"N2">>}),
    {issue, {assign, <<"N3">>, <<"27">>, departure}} =
        atc_policy:propose(Sep0, atc_world:publish_track(World0, #{
            id => <<"N3">>, runway => <<"27">>, intent => departure, time_s => 0,
            x_ft => 3000.0, y_ft => 400.0
        }), {taxi, <<"N3">>}).

exception_queue(_Config) ->
    World = atc_world:new(#{runways => runways()}),
    Package = atc_exception:package(<<"N1">>, emergency, {line_up, <<"N1">>}, [<<"N2">>], none),
    Queued = atc_world:push_exception(World, Package),
    [Stored] = atc_exception:list(maps:get(exceptions, Queued)),
    <<"N1">> = maps:get(aircraft, Stored),
    [<<"N2">>] = maps:get(affected, Stored),
    none = maps:get(last_clearance, Stored),
    Picture = atc_world:picture(Queued),
    1 = length(maps:get(<<"exceptions">>, Picture)).

training_profile(_Config) ->
    #{max_runways := 4, max_aircraft := 8, max_neighbors := 2} = atc_bounds:limits(),
    #{max_aircraft := 64, max_runways := 12} = atc_profile:limits(training),
    Checked = picture(4, 9, 2, 1),
    {error, envelope} = atc_bounds:check(Checked),
    {error, envelope} = atc_profile:check(checked, Checked),
    ok = atc_profile:check(training, picture(12, 9, 2, 1)).

pattern_memory(_Config) ->
    Closed = atc_pattern:demand(closed, 3),
    3 = length(Closed),
    Sequenced = atc_pattern:sequence(Closed, 90, 0),
    [0, 90, 180] = [maps:get(slot_s, Row) || Row <- Sequenced],
    [Straight] = atc_pattern:demand(straight_in, 1),
    ifr = maps:get(kind, Straight),
    Call = atc_pattern:traffic_call(<<"N2">>, <<"N1">>),
    true = binary:match(Call, <<"traffic to follow">>) =/= nomatch,
    true = atc_pattern:readback_ok(<<"runway 27, cleared to land">>, <<"cleared to land">>),
    false = atc_pattern:readback_ok(<<"cleared to land">>, <<"hold short">>),
    [<<"N2">>, <<"N3">>, <<"N1">>] =
        atc_pattern:reinsert([<<"N1">>, <<"N2">>, <<"N3">>], <<"N1">>).

cab_memory(_Config) ->
    Freqs = atc_cab:frequencies(),
    true = maps:is_key(clearance_delivery, Freqs),
    true = maps:is_key(ground, Freqs),
    true = maps:is_key(local, Freqs),
    true = maps:is_key(flight_data, Freqs),
    {ok, Strip} = atc_cab:ifr(<<"N1">>, <<"SFO-ORD">>, [<<"SFO-ORD">>]),
    <<"SFO-ORD">> = maps:get(plan, Strip),
    <<"A">> = maps:get(atis, Strip),
    false = maps:get(readback, Strip),
    {error, unknown_route} = atc_cab:ifr(<<"N1">>, <<"NOWHERE">>, [<<"SFO-ORD">>]),
    true = atc_cab:weather_gate(atc_cab:weather_open()),
    false = atc_cab:weather_gate((atc_cab:weather_open())#{routine => false}),
    {handoff, <<"N1">>, <<"KAPP">>, true} = atc_cab:handoff_command(<<"N1">>, <<"KAPP">>),
    {assign, <<"N8">>, <<"27">>, arrival} = atc_cab:release_command(<<"N8">>, <<"27">>),
    Read = atc_cab:check_readback(Strip, <<"cleared to land">>, <<"cleared to land">>),
    true = maps:get(readback, Read),
    World = atc_world:set_weather(
        atc_world:new(#{runways => runways()}),
        (atc_cab:weather_open())#{routine => false}
    ),
    none = maps:get(configuration, World),
    Sep = atc_separation:new(#{
        runways => runways(),
        links => #{<<"KAPP">> => true},
        max_aircraft => 8
    }),
    Release = atc_cab:release_command(<<"N8">>, <<"27">>),
    {issue, Release} = atc_policy:propose(Sep, atc_world:new(#{runways => runways()}), Release).

emergency_and_weather(_Config) ->
    Sep0 = atc_separation:new(#{runways => two_runways(), max_aircraft => 8}),
    World0 = atc_world:new(#{runways => two_runways()}),
    {ok, Sep1, _} = atc_separation:transition(Sep0, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, Sep2, _} = atc_separation:transition(Sep1, {hold_short, <<"N1">>}),
    {ok, Sep3, _} = atc_separation:transition(Sep2, {assign, <<"N2">>, <<"18">>, departure}),
    {ok, Sep4, _} = atc_separation:transition(Sep3, {hold_short, <<"N2">>}),
    WorldE = atc_training:inject(World0, emergency, <<"N1">>),
    {defer, Emergency} = atc_policy:propose(Sep4, WorldE, {line_up, <<"N1">>}),
    emergency = maps:get(reason, Emergency),
    {issue, {line_up, <<"N2">>}} = atc_policy:propose(Sep4, WorldE, {line_up, <<"N2">>}),
    {ok, Sep5, _} = atc_separation:transition(Sep4, {line_up, <<"N2">>}),
    true = atc_separation:invariant(Sep5),
    [] = [
        Rec
     || Rec <- atc_separation:issued(Sep5), maps:get(command, Rec) =:= {line_up, <<"N1">>}
    ],
    WorldW = atc_training:inject(World0, weather, (atc_cab:weather_open())#{shear => true}),
    {defer, Weather} = atc_policy:propose(Sep0, WorldW, {taxi, <<"N9">>}),
    weather = maps:get(reason, Weather),
    none = maps:get(configuration, WorldW).

phrase_audit(_Config) ->
    Sep0 = fresh(),
    {ok, Sep1, _} = atc_separation:transition(Sep0, {assign, <<"N1">>, <<"27">>, departure}),
    Text = atc_phraseology:render({hold_short, <<"N1">>}, Sep1),
    ok = atc_phrase_audit:routine(Text),
    ok = atc_phrase_audit:routine(<<"N1, traffic to follow, N2">>),
    {error, pasted_order} = atc_phrase_audit:routine(<<"see 7110.65">>).

national_and_peak(_Config) ->
    Airports = [<<"KSFO">>, <<"KMOD">>, <<"KSTS">>, <<"EGLL">>],
    [<<"EGLL">>, <<"KMOD">>, <<"KSFO">>, <<"KSTS">>] = atc_training:shard(Airports, national),
    [<<"KMOD">>, <<"KSFO">>, <<"KSTS">>] = atc_training:shard(Airports, {region, <<"K">>}),
    [<<"KSTS">>] = atc_training:shard(Airports, {airport, <<"KSTS">>}),
    Demand = atc_training:demand(#{
        airport => <<"KSTS">>,
        airline => [{<<"KSTS">>, <<"KMOD">>}],
        ga => 2
    }),
    3 = length(Demand),
    Events = atc_training:record([
        #{kind => <<"deferred">>, radio_s => 2},
        #{kind => <<"incursion">>, radio_s => 1},
        #{kind => <<"loss">>, radio_s => 4}
    ]),
    Events = atc_training:replay(Events),
    Score = atc_training:score(Events),
    1 = maps:get(deferred, Score),
    1 = maps:get(incursions, Score),
    1 = maps:get(losses, Score),
    7 = maps:get(radio_s, Score),
    Peak = atc_training:peak(9),
    9 = maps:get(aircraft, Peak),
    true = maps:get(issued, Peak) > 8,
    #{max_aircraft := 8, max_runways := 4, max_neighbors := 2} = maps:get(checked, Peak).

fresh() ->
    atc_separation:new(#{runways => runways(), max_aircraft => 8}).

sample_track(Id, Time) ->
    #{
        id => Id,
        time_s => Time,
        x_ft => 10,
        y_ft => 20,
        alt_ft => 30,
        vx_fps => 1,
        vy_fps => 2,
        wake => heavy
    }.

runways() ->
    #{
        <<"27">> => #{designation => both, independent => true, intersects => []},
        <<"09">> => #{designation => arrival, independent => false, intersects => [<<"27">>]}
    }.

two_runways() ->
    #{
        <<"27">> => #{designation => both, independent => true, intersects => []},
        <<"18">> => #{designation => both, independent => true, intersects => []}
    }.

picture(MaxRunways, MaxAircraft, MaxNeighbors, RunwayCount) ->
    Ids = [iolist_to_binary(io_lib:format("~2..0B", [Index])) || Index <- lists:seq(1, RunwayCount)],
    #{
        runways => maps:from_list([
            {Id, #{designation => both, independent => true, intersects => []}}
         || Id <- Ids
        ]),
        neighbors => [],
        max_runways => MaxRunways,
        max_aircraft => MaxAircraft,
        max_neighbors => MaxNeighbors,
        computers => 1
    }.
