%%%-------------------------------------------------------------------
%%% Verifies: SRS004, SRS013, SRS015
%%% PropEr samples the Erlang state machine. A passing run is conformance
%%% evidence. It is not a proof that the implementation refines AtcTower.
%%% @relation(SRS013, SRS004, SRS015, scope=file)
%%%-------------------------------------------------------------------
-module(prop_clearance).

-include_lib("proper/include/proper.hrl").

-export([prop_separation/0, quickcheck/0]).
-export([
    initial_state/0,
    command/1,
    precondition/2,
    next_state/3,
    postcondition/3,
    do_command/3,
    do_crash/2,
    do_restart/2,
    do_replay/2
]).

quickcheck() ->
    proper:quickcheck(prop_separation(), [{numtests, 40}, {max_size, 20}]).

prop_separation() ->
    ?FORALL(
        Cmds,
        commands(?MODULE),
        begin
            {History, State, Result} = run_commands(?MODULE, Cmds),
            ?WHENFAIL(
                io:format("History: ~p~nState: ~p~nResult: ~p~n", [History, State, Result]),
                aggregate(command_names(Cmds), Result =:= ok)
            )
        end
    ).

initial_state() ->
    atc_cluster:form(3, atc_separation:new(#{
        runways => runways(),
        links => #{<<"KNEAR">> => true},
        max_aircraft => 8
    })).

command(View) ->
    oneof([
        {call, ?MODULE, do_command, [View, oneof([1, 2, 3]), clearance()]},
        {call, ?MODULE, do_crash, [View, oneof([1, 2, 3])]},
        {call, ?MODULE, do_restart, [View, oneof([1, 2, 3])]},
        {call, ?MODULE, do_replay, [View, oneof([1, 2, 3])]}
    ]).

precondition(_View, _Call) ->
    true.

next_state(_View, Result, _Call) ->
    {call, erlang, element, [1, Result]}.

postcondition(Prev, {call, _, do_command, _}, {Next, {error, _}}) ->
    occupancy(Prev) =:= occupancy(Next) andalso safe(Next);
postcondition(_Prev, {call, _, do_command, _}, {Next, {ok, _}}) ->
    safe(Next);
postcondition(_Prev, _Call, {Next, ok}) ->
    safe(Next).

do_command(View, Caller, Cmd) ->
    case atc_cluster:command(View, Caller, Cmd) of
        {ok, Rec, Next} ->
            {Next, {ok, Rec}};
        {error, Reason, Next} ->
            {Next, {error, Reason}}
    end.

do_crash(View, Id) ->
    {atc_cluster:crash(View, Id), ok}.

do_restart(View, Id) ->
    {atc_cluster:restart(View, Id), ok}.

do_replay(View, Id) ->
    {atc_cluster:finish_replay(View, Id), ok}.

occupancy(View) ->
    atc_separation:occupancy(maps:get(state, View)).

safe(View) ->
    State = maps:get(state, View),
    Alive = maps:get(alive, View),
    Replicas = maps:get(replicas, View),
    atc_separation:invariant(State) andalso
        lists:all(fun(Id) -> maps:get(Id, Replicas) =:= State end, Alive) andalso
        one_leader(View).

one_leader(View) ->
    case atc_cluster:leader(View) of
        none ->
            true;
        Id ->
            lists:member(Id, atc_cluster:voters(View))
    end.

clearance() ->
    Aircraft = oneof([<<"N1">>, <<"N2">>, <<"N3">>]),
    Runway = oneof([<<"27">>, <<"09">>, <<"18">>, <<"36">>]),
    Intent = oneof([arrival, departure]),
    Neighbor = oneof([<<"KNEAR">>, <<"KFAR">>]),
    oneof([
        {assign, Aircraft, Runway, Intent},
        {hold_short, Aircraft},
        {line_up, Aircraft},
        {takeoff, Aircraft},
        {land, Aircraft},
        {vacate, Aircraft},
        {go_around, Aircraft},
        {handoff, Aircraft, Neighbor, oneof([true, false])},
        {link, Neighbor, oneof([true, false])}
    ]).

runways() ->
    #{
        <<"27">> => #{designation => both, independent => true, intersects => []},
        <<"09">> => #{designation => arrival, independent => false, intersects => [<<"27">>]},
        <<"18">> => #{designation => both, independent => true, intersects => []},
        <<"36">> => #{designation => closed, independent => true, intersects => []}
    }.
