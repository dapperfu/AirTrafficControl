%%%-------------------------------------------------------------------
%%% @doc Pure clearance transitions. The actions match AtcTower.tla.
%%% Implements: SRS006
%%% Implements: SRS007
%%% Implements: SRS008
%%% Implements: SRS009
%%% Implements: SRS010
%%% Implements: SRS011
%%% Implements: SRS012
%%% Implements: SRS013
%%% @relation(SRS006, SRS007, SRS008, SRS009, SRS010, SRS011, SRS012, SRS013, scope=file)
%%%-------------------------------------------------------------------
-module(atc_separation).

-export([
    new/1,
    transition/2,
    invariant/1,
    occupancy/1,
    issued/1,
    audit/1,
    stale/2,
    picture/1,
    command_view/1
]).

%% Implements: SRS013
%% @relation(SRS013, scope=line)
new(Opts) ->
    #{
        aircraft => #{},
        seq => #{},
        runways => maps:get(runways, Opts, #{}),
        links => maps:get(links, Opts, #{}),
        stale => #{},
        wind => maps:get(wind, Opts, undefined),
        max_aircraft => maps:get(max_aircraft, Opts, 8),
        log => [],
        audit => []
    }.

%% Implements: SRS013
%% @relation(SRS013, scope=line)
transition(State, Cmd) ->
    case decide(State, Cmd) of
        {ok, Next} ->
            Rec = audit_rec(issued, Cmd),
            {ok,
                Next#{
                    log => maps:get(log, State) ++ [Rec],
                    audit => maps:get(audit, State) ++ [Rec]
                },
                Rec};
        {error, Reason} ->
            Rec = (audit_rec(refused, Cmd))#{reason => Reason},
            {error, Reason, State#{audit => maps:get(audit, State) ++ [Rec]}}
    end.

invariant(State) ->
    exclusive(State) andalso head_only(State) andalso no_closed(State).

occupancy(State) ->
    maps:filter(
        fun(_Id, Aircraft) -> maps:get(phase, Aircraft) =:= occupying end,
        maps:get(aircraft, State)
    ).

issued(State) ->
    maps:get(log, State).

audit(State) ->
    maps:get(audit, State).

stale(State, Neighbor) ->
    maps:get(Neighbor, maps:get(stale, State), false).

decide(State, {assign, Aircraft, Runway, Intent}) ->
    case maps:is_key(Runway, runways(State)) of
        false ->
            {error, unknown_runway};
        true ->
            case phase(State, Aircraft) of
                out ->
                    case allows(State, Runway, Intent) of
                        false ->
                            {error, designation};
                        true ->
                            case over_aircraft_limit(State, Aircraft) of
                                true ->
                                    {error, envelope};
                                false ->
                                    {ok, enqueue(State, Aircraft, Runway, Intent)}
                            end
                    end;
                _ ->
                    {error, phase}
            end
    end;
decide(State, {hold_short, Aircraft}) ->
    case phase(State, Aircraft) of
        queued ->
            {ok, set_phase(State, Aircraft, hold)};
        _ ->
            {error, phase}
    end;
decide(State, {line_up, Aircraft}) ->
    enter_runway(State, Aircraft, departure);
decide(State, {land, Aircraft}) ->
    enter_runway(State, Aircraft, arrival);
decide(State, {takeoff, Aircraft}) ->
    leave_runway(State, Aircraft, departure, air, true);
decide(State, {go_around, Aircraft}) ->
    leave_runway(State, Aircraft, arrival, air, true);
decide(State, {vacate, Aircraft}) ->
    leave_runway(State, Aircraft, arrival, out, false);
decide(State, {handoff, Aircraft, Neighbor, Accept}) ->
    handoff(State, Aircraft, Neighbor, Accept);
decide(State, {link, Neighbor, Up}) ->
    {ok, set_link(State, Neighbor, Up)};
decide(_State, _Cmd) ->
    {error, unknown_command}.

enter_runway(State, Aircraft, Intent) ->
    case maps:is_key(Aircraft, maps:get(aircraft, State)) of
        false ->
            {error, unknown_aircraft};
        true ->
            enter_known(State, Aircraft, Intent)
    end.

enter_known(State, Aircraft, Intent) ->
    case {phase(State, Aircraft), intent(State, Aircraft)} of
        {Phase, Intent} when Phase =:= queued; Phase =:= hold ->
            Runway = runway(State, Aircraft),
            case
                is_head(State, Aircraft) andalso
                    allows(State, Runway, Intent) andalso
                    not occupied(State, Runway)
            of
                true ->
                    {ok, set_phase(State, Aircraft, occupying)};
                false ->
                    {error, separation}
            end;
        _ ->
            {error, phase}
    end.

leave_runway(State, Aircraft, Intent, NextPhase, KeepRunway) ->
    case maps:is_key(Aircraft, maps:get(aircraft, State)) of
        false ->
            {error, unknown_aircraft};
        true ->
            leave_known(State, Aircraft, Intent, NextPhase, KeepRunway)
    end.

leave_known(State, Aircraft, Intent, NextPhase, KeepRunway) ->
    case {phase(State, Aircraft), intent(State, Aircraft)} of
        {occupying, Intent} ->
            case is_head(State, Aircraft) andalso allows(State, runway(State, Aircraft), Intent) of
                true ->
                    Runway = runway(State, Aircraft),
                    Next = drop_head(State, Runway),
                    AircraftMap = maps:get(aircraft, Next),
                    Record = maps:get(Aircraft, AircraftMap),
                    Updated =
                        case KeepRunway of
                            true ->
                                Record#{phase => NextPhase};
                            false ->
                                Record#{phase => out, runway => none, intent => none}
                        end,
                    {ok, Next#{aircraft => AircraftMap#{Aircraft => Updated}}};
                false ->
                    {error, separation}
            end;
        _ ->
            {error, phase}
    end.

handoff(State, Aircraft, Neighbor, Accept) ->
    case maps:is_key(Aircraft, maps:get(aircraft, State)) of
        false ->
            {error, unknown_aircraft};
        true ->
            case maps:get(Neighbor, maps:get(links, State), false) of
                false ->
                    {error, link_down};
                true ->
                    case phase(State, Aircraft) of
                        occupying ->
                            {error, separation};
                        gone ->
                            {error, phase};
                        _ ->
                            case Accept of
                                true ->
                                    {ok, release(State, Aircraft)};
                                false ->
                                    {ok, State}
                            end
                    end
            end
    end.

enqueue(State, Aircraft, Runway, Intent) ->
    Record = #{phase => queued, runway => Runway, intent => Intent},
    Seq = maps:get(seq, State),
    Queue = maps:get(Runway, Seq, []),
    State#{
        aircraft => maps:put(Aircraft, Record, maps:get(aircraft, State)),
        seq => Seq#{Runway => Queue ++ [Aircraft]}
    }.

release(State, Aircraft) ->
    Runway = runway(State, Aircraft),
    Seq = maps:get(seq, State),
    NextSeq =
        case Runway of
            none ->
                Seq;
            _ ->
                Queue = maps:get(Runway, Seq, []),
                Seq#{Runway => lists:delete(Aircraft, Queue)}
        end,
    AircraftMap = maps:get(aircraft, State),
    Record = maps:get(Aircraft, AircraftMap),
    State#{
        aircraft => AircraftMap#{Aircraft => Record#{phase => gone, runway => none, intent => none}},
        seq => NextSeq
    }.

set_phase(State, Aircraft, Phase) ->
    AircraftMap = maps:get(aircraft, State),
    Record = maps:get(Aircraft, AircraftMap),
    State#{aircraft => AircraftMap#{Aircraft => Record#{phase => Phase}}}.

set_link(State, Neighbor, Up) ->
    Links = maps:get(links, State),
    Stale = maps:get(stale, State),
    State#{
        links => Links#{Neighbor => Up},
        stale => Stale#{Neighbor => not Up}
    }.

drop_head(State, Runway) ->
    Seq = maps:get(seq, State),
    [_Head | Rest] = maps:get(Runway, Seq),
    State#{seq => Seq#{Runway => Rest}}.

occupied(State, Runway) ->
    maps:fold(
        fun(_Id, Aircraft, Acc) ->
            case maps:get(phase, Aircraft) =:= occupying of
                true ->
                    Acc orelse conflicts(State, maps:get(runway, Aircraft), Runway);
                false ->
                    Acc
            end
        end,
        false,
        maps:get(aircraft, State)
    ).

conflicts(_State, Runway, Runway) ->
    true;
conflicts(State, Left, Right) ->
    lists:member(Right, intersects(State, Left)) orelse
        lists:member(Left, intersects(State, Right)) orelse
        (not independent(State, Left) andalso not independent(State, Right)).

exclusive(State) ->
    Occupying = maps:to_list(occupancy(State)),
    pairs_ok(State, Occupying).

pairs_ok(_State, []) ->
    true;
pairs_ok(State, [{Id, Aircraft} | Rest]) ->
    Runway = maps:get(runway, Aircraft),
    lists:all(
        fun({OtherId, Other}) ->
            OtherId =:= Id orelse
                not conflicts(State, Runway, maps:get(runway, Other))
        end,
        Rest
    ) andalso pairs_ok(State, Rest).

no_closed(State) ->
    maps:fold(
        fun(_Aircraft, Record, Acc) ->
            case maps:get(phase, Record) of
                occupying ->
                    Acc andalso designation(State, maps:get(runway, Record)) =/= closed;
                _ ->
                    Acc
            end
        end,
        true,
        maps:get(aircraft, State)
    ).

head_only(State) ->
    maps:fold(
        fun(Aircraft, Record, Acc) ->
            case maps:get(phase, Record) of
                occupying ->
                    Acc andalso is_head(State, Aircraft);
                _ ->
                    Acc
            end
        end,
        true,
        maps:get(aircraft, State)
    ).

is_head(State, Aircraft) ->
    case runway(State, Aircraft) of
        none ->
            false;
        Runway ->
            case maps:get(Runway, maps:get(seq, State), []) of
                [Aircraft | _] ->
                    true;
                _ ->
                    false
            end
    end.

allows(State, Runway, Intent) ->
    Designation = designation(State, Runway),
    Designation =/= closed andalso (Designation =:= both orelse Designation =:= Intent).

over_aircraft_limit(State, Aircraft) ->
    Already = maps:is_key(Aircraft, maps:get(aircraft, State)),
    Count = maps:size(
        maps:filter(
            fun(_Id, Record) -> maps:get(phase, Record) =/= gone end,
            maps:get(aircraft, State)
        )
    ),
    case Already of
        true ->
            false;
        false ->
            Count >= maps:get(max_aircraft, State)
    end.

phase(State, Aircraft) ->
    case maps:find(Aircraft, maps:get(aircraft, State)) of
        {ok, #{phase := Phase}} ->
            Phase;
        error ->
            out
    end.

intent(State, Aircraft) ->
    maps:get(intent, maps:get(Aircraft, maps:get(aircraft, State))).

runway(State, Aircraft) ->
    case maps:find(Aircraft, maps:get(aircraft, State)) of
        {ok, #{runway := Runway}} ->
            Runway;
        error ->
            none
    end.

runways(State) ->
    maps:get(runways, State).

designation(State, Runway) ->
    maps:get(designation, maps:get(Runway, runways(State))).

independent(State, Runway) ->
    maps:get(independent, maps:get(Runway, runways(State))).

intersects(State, Runway) ->
    maps:get(intersects, maps:get(Runway, runways(State)), []).

audit_rec(Decision, Cmd) ->
    #{
        decision => Decision,
        command => Cmd,
        uid => requirement_uid(Decision, Cmd),
        aircraft => command_aircraft(Cmd),
        runway => command_runway(Cmd)
    }.

requirement_uid(refused, _Cmd) ->
    <<"SRS013">>;
requirement_uid(issued, {assign, _, _, _}) ->
    <<"SRS008">>;
requirement_uid(issued, {hold_short, _}) ->
    <<"SRS012">>;
requirement_uid(issued, {line_up, _}) ->
    <<"SRS012">>;
requirement_uid(issued, {takeoff, _}) ->
    <<"SRS010">>;
requirement_uid(issued, {land, _}) ->
    <<"SRS011">>;
requirement_uid(issued, {go_around, _}) ->
    <<"SRS012">>;
requirement_uid(issued, {vacate, _}) ->
    <<"SRS009">>;
requirement_uid(issued, {handoff, _, _, _}) ->
    <<"SRS006">>;
requirement_uid(issued, {link, _, _}) ->
    <<"SRS007">>.

command_aircraft({assign, Aircraft, _, _}) ->
    Aircraft;
command_aircraft({hold_short, Aircraft}) ->
    Aircraft;
command_aircraft({line_up, Aircraft}) ->
    Aircraft;
command_aircraft({takeoff, Aircraft}) ->
    Aircraft;
command_aircraft({land, Aircraft}) ->
    Aircraft;
command_aircraft({go_around, Aircraft}) ->
    Aircraft;
command_aircraft({vacate, Aircraft}) ->
    Aircraft;
command_aircraft({handoff, Aircraft, _, _}) ->
    Aircraft;
command_aircraft(_) ->
    none.

command_runway({assign, _, Runway, _}) ->
    Runway;
command_runway(_) ->
    none.

%% Read-only projection for an attached front. Transitions do not call this.
picture(State) ->
    #{
        <<"aircraft">> => aircraft_rows(State),
        <<"queues">> => queue_rows(State),
        <<"links">> => link_rows(State),
        <<"issued">> => [entry(Rec) || Rec <- recent(maps:get(log, State))],
        <<"audit">> => [entry(Rec) || Rec <- recent(maps:get(audit, State))]
    }.

aircraft_rows(State) ->
    Rows = maps:fold(
        fun(Id, Record, Acc) ->
            [
                #{
                    <<"id">> => Id,
                    <<"phase">> => atom_to_binary(maps:get(phase, Record)),
                    <<"runway">> => maybe_id(maps:get(runway, Record)),
                    <<"intent">> => maybe_id(maps:get(intent, Record))
                }
                | Acc
            ]
        end,
        [],
        maps:get(aircraft, State)
    ),
    lists:sort(fun(Left, Right) -> maps:get(<<"id">>, Left) =< maps:get(<<"id">>, Right) end, Rows).

queue_rows(State) ->
    Rows = maps:fold(
        fun(Runway, Queue, Acc) ->
            [#{<<"runway">> => Runway, <<"aircraft">> => Queue} | Acc]
        end,
        [],
        maps:get(seq, State)
    ),
    lists:sort(
        fun(Left, Right) -> maps:get(<<"runway">>, Left) =< maps:get(<<"runway">>, Right) end,
        Rows
    ).

link_rows(State) ->
    Rows = maps:fold(
        fun(Icao, Up, Acc) ->
            [
                #{
                    <<"icao">> => Icao,
                    <<"up">> => Up =:= true,
                    <<"stale">> => maps:get(Icao, maps:get(stale, State), false) =:= true
                }
                | Acc
            ]
        end,
        [],
        maps:get(links, State)
    ),
    lists:sort(fun(Left, Right) -> maps:get(<<"icao">>, Left) =< maps:get(<<"icao">>, Right) end, Rows).

entry(Rec) ->
    View = #{
        <<"decision">> => atom_to_binary(maps:get(decision, Rec)),
        <<"uid">> => maps:get(uid, Rec),
        <<"aircraft">> => maybe_id(maps:get(aircraft, Rec)),
        <<"runway">> => maybe_id(maps:get(runway, Rec)),
        <<"command">> => command_view(maps:get(command, Rec))
    },
    case maps:find(reason, Rec) of
        {ok, Reason} when is_atom(Reason) ->
            View#{<<"reason">> => atom_to_binary(Reason)};
        _ ->
            View
    end.

maybe_id(none) ->
    null;
maybe_id(Value) when is_atom(Value) ->
    atom_to_binary(Value);
maybe_id(Value) when is_binary(Value) ->
    Value.

recent(List) ->
    lists:nthtail(max(0, length(List) - 40), List).

command_view({assign, Aircraft, Runway, Intent}) ->
    text_view(<<"assign">>, ["assign ", Aircraft, " ", Runway, " ", atom_to_binary(Intent)]);
command_view({hold_short, Aircraft}) ->
    text_view(<<"hold_short">>, ["hold short ", Aircraft]);
command_view({line_up, Aircraft}) ->
    text_view(<<"line_up">>, ["line up ", Aircraft]);
command_view({takeoff, Aircraft}) ->
    text_view(<<"takeoff">>, ["takeoff ", Aircraft]);
command_view({land, Aircraft}) ->
    text_view(<<"land">>, ["land ", Aircraft]);
command_view({go_around, Aircraft}) ->
    text_view(<<"go_around">>, ["go around ", Aircraft]);
command_view({vacate, Aircraft}) ->
    text_view(<<"vacate">>, ["vacate ", Aircraft]);
command_view({handoff, Aircraft, Neighbor, true}) ->
    text_view(<<"handoff">>, ["handoff ", Aircraft, " ", Neighbor, " accept"]);
command_view({handoff, Aircraft, Neighbor, false}) ->
    text_view(<<"handoff">>, ["handoff ", Aircraft, " ", Neighbor, " reject"]);
command_view({link, Neighbor, true}) ->
    text_view(<<"link">>, ["link ", Neighbor, " up"]);
command_view({link, Neighbor, false}) ->
    text_view(<<"link">>, ["link ", Neighbor, " down"]);
command_view(Other) ->
    text_view(<<"unknown">>, io_lib:format("~p", [Other])).

text_view(Kind, Pieces) ->
    #{<<"kind">> => Kind, <<"text">> => iolist_to_binary(Pieces)}.
