%%%-------------------------------------------------------------------
%%% @doc Ra machine for one ordered clearance log.
%%% Implements: SRS004
%%% Implements: SDD002
%%% Implements: SDD004
%%% @relation(SRS004, SDD002, SDD004, scope=file)
%%%-------------------------------------------------------------------
-module(atc_ra_machine).

-behaviour(ra_machine).

-export([init/1, apply/3]).

%% Implements: SDD004
%% @relation(SDD004, scope=line)
init(#{sep := Separation}) ->
    Separation.

%% Implements: SDD002
%% Implements: SRS004
%% @relation(SDD002, SRS004, scope=line)
apply(_Meta, Command, State) ->
    case atc_separation:transition(State, Command) of
        {ok, Next, Rec} ->
            {Next, {ok, Rec}};
        {error, Reason, Next} ->
            {Next, {error, Reason}}
    end.
