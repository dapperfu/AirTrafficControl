%%%-------------------------------------------------------------------
%%% @doc Closed-traffic and straight-in sequencing, calls, and readback.
%%% Implements: SRS022
%%% @relation(SRS022, scope=file)
%%%-------------------------------------------------------------------
-module(atc_pattern).

-export([demand/2, sequence/3, traffic_call/2, readback_ok/2, reinsert/2]).

%% Implements: SRS022
%% @relation(SRS022, scope=line)
demand(closed, Count) when is_integer(Count), Count >= 0 ->
    [
        #{
            id => iolist_to_binary(io_lib:format("N~3..0BGA", [Index])),
            kind => closed,
            wake => small,
            intent => arrival
        }
     || Index <- lists:seq(1, Count)
    ];
demand(straight_in, Count) when is_integer(Count), Count >= 0 ->
    [
        #{
            id => iolist_to_binary(io_lib:format("AAL~3..0B", [Index])),
            kind => ifr,
            wake => large,
            intent => arrival
        }
     || Index <- lists:seq(1, Count)
    ].

%% Implements: SRS022
%% @relation(SRS022, scope=line)
sequence(Rows, Interval, Now) when is_number(Interval), is_number(Now) ->
    lists:zipwith(
        fun(Index, Row) ->
            Row#{slot_s => Now + Index * Interval}
        end,
        lists:seq(0, length(Rows) - 1),
        Rows
    ).

%% Implements: SRS022
%% @relation(SRS022, scope=line)
traffic_call(Follower, Leader) ->
    iolist_to_binary([Follower, <<", traffic to follow, ">>, Leader]).

%% Implements: SRS022
%% @relation(SRS022, scope=line)
readback_ok(Clearance, Readback) when is_binary(Clearance), is_binary(Readback) ->
    Phrase = action_phrase(string:lowercase(Clearance)),
    binary:match(string:lowercase(Readback), Phrase) =/= nomatch.

%% Implements: SRS022
%% @relation(SRS022, scope=line)
reinsert(Order, Aircraft) when is_list(Order) ->
    lists:delete(Aircraft, Order) ++ [Aircraft].

action_phrase(Lower) ->
    Phrases = [
        <<"cleared to land">>,
        <<"cleared for takeoff">>,
        <<"line up and wait">>,
        <<"hold short">>,
        <<"go around">>
    ],
    case lists:dropwhile(fun(Phrase) -> binary:match(Lower, Phrase) =:= nomatch end, Phrases) of
        [Phrase | _] -> Phrase;
        [] -> Lower
    end.
