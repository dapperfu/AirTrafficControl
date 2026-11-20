%%%-------------------------------------------------------------------
%%% @doc Operational record of issued and refused clearances.
%%% Implements: SRS016
%%% @relation(SRS016, scope=file)
%%%-------------------------------------------------------------------
-module(atc_audit).

-export([entries/1, format/1]).

%% Implements: SRS016
%% @relation(SRS016, scope=line)
entries(State) ->
    atc_separation:audit(State).

%% Implements: SRS016
%% @relation(SRS016, scope=line)
format(#{decision := Decision, uid := Uid, command := Cmd, aircraft := Aircraft}) ->
    iolist_to_binary(
        io_lib:format("~s ~s ~s ~p", [Decision, Uid, Aircraft, Cmd])
    ).
