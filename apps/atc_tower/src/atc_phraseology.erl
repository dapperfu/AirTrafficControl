%%%-------------------------------------------------------------------
%%% @doc Pilot clearance text. The wording paraphrases tower clearances.
%%% It does not copy phraseology tables.
%%% Implements: IRS001
%%% @relation(IRS001, scope=file)
%%%-------------------------------------------------------------------
-module(atc_phraseology).

-export([render/2]).

%% Implements: IRS001
%% @relation(IRS001, scope=line)
render({assign, Aircraft, Runway, Intent}, _State) ->
    format("~s, runway ~s, for ~s", [Aircraft, Runway, Intent]);
render({hold_short, Aircraft}, State) ->
    format("~s, runway ~s, hold short", [Aircraft, runway_of(State, Aircraft)]);
render({line_up, Aircraft}, State) ->
    format("~s, runway ~s, line up and wait", [Aircraft, runway_of(State, Aircraft)]);
render({takeoff, Aircraft}, State) ->
    Runway = runway_of(State, Aircraft),
    case maps:get(wind, State, undefined) of
        undefined ->
            format("~s, runway ~s, cleared for takeoff", [Aircraft, Runway]);
        Wind ->
            format("~s, runway ~s, wind ~s, cleared for takeoff", [Aircraft, Runway, Wind])
    end;
render({land, Aircraft}, State) ->
    format("~s, runway ~s, number ~b, cleared to land", [
        Aircraft, runway_of(State, Aircraft), sequence_number(State, Aircraft)
    ]);
render({go_around, Aircraft}, _State) ->
    format("~s, go around", [Aircraft]);
render({vacate, Aircraft}, State) ->
    format("~s, runway ~s, vacated", [Aircraft, runway_of(State, Aircraft)]);
render({handoff, Aircraft, Neighbor, _Accept}, _State) ->
    format("~s, contact ~s", [Aircraft, Neighbor]);
render(_Cmd, _State) ->
    <<>>.

format(Template, Args) ->
    iolist_to_binary(io_lib:format(Template, Args)).

runway_of(State, Aircraft) ->
    case maps:find(Aircraft, maps:get(aircraft, State)) of
        {ok, #{runway := Runway}} ->
            Runway;
        error ->
            none
    end.

sequence_number(State, Aircraft) ->
    Runway = runway_of(State, Aircraft),
    Queue = maps:get(Runway, maps:get(seq, State), []),
    index(Queue, Aircraft, 1).

index([Aircraft | _], Aircraft, N) ->
    N;
index([_ | Rest], Aircraft, N) ->
    index(Rest, Aircraft, N + 1);
index([], _Aircraft, _N) ->
    0.
