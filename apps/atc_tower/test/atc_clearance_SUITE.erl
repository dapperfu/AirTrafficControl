%%%-------------------------------------------------------------------
%%% Verifies: SRS002, SRS005, SRS006, SRS007, SRS008, SRS009, SRS010, SRS011, SRS012, SRS013, SRS014, SRS016, IRS001
%%% @relation(SRS002, SRS005, SRS006, SRS007, SRS008, SRS009, SRS010, SRS011, SRS012, SRS013, SRS014, SRS016, IRS001, scope=file)
%%%-------------------------------------------------------------------
-module(atc_clearance_SUITE).

-export([all/0]).
-export([
    designation_and_conflict/1,
    sequence_and_exclusive_runway/1,
    neighbor_link_and_phrase/1,
    audit_records_requirement/1,
    aircraft_envelope/1
]).

all() ->
    [
        designation_and_conflict,
        sequence_and_exclusive_runway,
        neighbor_link_and_phrase,
        audit_records_requirement,
    aircraft_envelope
    ].

designation_and_conflict(_Config) ->
    State = sample(),
    {error, designation, _} = atc_clearance:request(State, {assign, <<"N1">>, <<"09">>, departure}),
    {error, designation, _} = atc_clearance:request(State, {assign, <<"N1">>, <<"36">>, arrival}),
    {ok, Queued, _} = atc_clearance:request(State, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, Holding, _} = atc_clearance:request(Queued, {hold_short, <<"N1">>}),
    {ok, Lined, _} = atc_clearance:request(Holding, {line_up, <<"N1">>}),
    {ok, Other, _} = atc_clearance:request(Lined, {assign, <<"N2">>, <<"09">>, arrival}),
    {error, separation, _} = atc_clearance:request(Other, {land, <<"N2">>}),
    true = atc_separation:invariant(Other).

sequence_and_exclusive_runway(_Config) ->
    State = sample(),
    {ok, First, _} = atc_clearance:request(State, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, Second, _} = atc_clearance:request(First, {assign, <<"N2">>, <<"27">>, departure}),
    {error, separation, _} = atc_clearance:request(Second, {line_up, <<"N2">>}),
    {ok, Lined, _} = atc_clearance:request(Second, {line_up, <<"N1">>}),
    {ok, Air, Rec} = atc_clearance:request(Lined, {takeoff, <<"N1">>}),
    true = binary:match(maps:get(text, Rec), <<"wind 270 at 10">>) =/= nomatch,
    {ok, NextLined, _} = atc_clearance:request(Air, {line_up, <<"N2">>}),
    {ok, Departed, _} = atc_clearance:request(NextLined, {takeoff, <<"N2">>}),
    {ok, Parallel, _} = atc_clearance:request(Departed, {assign, <<"N3">>, <<"18">>, arrival}),
    {ok, Landed, LandRec} = atc_clearance:request(Parallel, {land, <<"N3">>}),
    true = binary:match(maps:get(text, LandRec), <<"cleared to land">>) =/= nomatch,
    {ok, Around, _} = atc_clearance:request(Landed, {go_around, <<"N3">>}),
    0 = maps:size(atc_separation:occupancy(Around)),
    {ok, Again, _} = atc_clearance:request(Around, {assign, <<"N4">>, <<"18">>, arrival}),
    {ok, SecondLand, _} = atc_clearance:request(Again, {land, <<"N4">>}),
    {ok, Clear, _} = atc_clearance:request(SecondLand, {vacate, <<"N4">>}),
    0 = maps:size(atc_separation:occupancy(Clear)),
    Calm = atc_separation:new(#{runways => runways(), max_aircraft => 8}),
    {ok, CalmQueued, _} = atc_clearance:request(Calm, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, CalmLined, _} = atc_clearance:request(CalmQueued, {line_up, <<"N1">>}),
    {ok, _, CalmRec} = atc_clearance:request(CalmLined, {takeoff, <<"N1">>}),
    nomatch = binary:match(maps:get(text, CalmRec), <<"wind">>).

neighbor_link_and_phrase(_Config) ->
    State = sample(),
    {ok, Queued, _} = atc_clearance:request(State, {assign, <<"N1">>, <<"27">>, departure}),
    {error, link_down, _} = atc_clearance:request(Queued, {handoff, <<"N1">>, <<"KFAR">>, true}),
    {ok, Kept, _} = atc_clearance:request(Queued, {link, <<"KNEAR">>, false}),
    true = atc_separation:stale(Kept, <<"KNEAR">>),
    {error, link_down, _} = atc_clearance:request(Kept, {handoff, <<"N1">>, <<"KNEAR">>, true}),
    queued = maps:get(phase, maps:get(<<"N1">>, maps:get(aircraft, Kept))),
    {ok, Up, _} = atc_clearance:request(Kept, {link, <<"KNEAR">>, true}),
    {ok, Gone, _} = atc_clearance:request(Up, {handoff, <<"N1">>, <<"KNEAR">>, true}),
    gone = maps:get(phase, maps:get(<<"N1">>, maps:get(aircraft, Gone))).

audit_records_requirement(_Config) ->
    State = sample(),
    {ok, Queued, Issued} = atc_clearance:request(State, {assign, <<"N1">>, <<"27">>, departure}),
    <<"SRS008">> = maps:get(uid, Issued),
    {ok, Both, _} = atc_clearance:request(Queued, {assign, <<"N2">>, <<"27">>, departure}),
    {error, separation, RefusedState} = atc_clearance:request(Both, {line_up, <<"N2">>}),
    Audit = atc_audit:entries(RefusedState),
    <<"SRS013">> = maps:get(uid, lists:last(Audit)),
    refused = maps:get(decision, lists:last(Audit)),
    true = is_binary(atc_audit:format(lists:last(Audit))),
    IssuedLog = atc_separation:issued(RefusedState),
    false = lists:any(fun(Rec) -> maps:get(decision, Rec) =:= refused end, IssuedLog).

aircraft_envelope(_Config) ->
    State = atc_separation:new(#{
        runways => #{
            <<"27">> => #{designation => both, independent => true, intersects => []}
        },
        max_aircraft => 2
    }),
    {ok, One, _} = atc_separation:transition(State, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, Two, _} = atc_separation:transition(One, {assign, <<"N2">>, <<"27">>, departure}),
    {error, envelope, _} = atc_separation:transition(Two, {assign, <<"N3">>, <<"27">>, departure}),
    0 = maps:size(atc_separation:occupancy(Two)).

sample() ->
    atc_separation:new(#{
        runways => runways(),
        links => #{<<"KNEAR">> => true},
        wind => <<"270 at 10">>,
        max_aircraft => 8
    }).

runways() ->
    #{
        <<"27">> => #{designation => both, independent => true, intersects => []},
        <<"09">> => #{designation => arrival, independent => false, intersects => [<<"27">>]},
        <<"18">> => #{designation => both, independent => true, intersects => []},
        <<"36">> => #{designation => closed, independent => true, intersects => []}
    }.
