%%%-------------------------------------------------------------------
%%% @doc Tower application. Implements: SRS003
%%% @relation(SRS003, scope=file)
%%%-------------------------------------------------------------------
-module(atc_tower_app).

-behaviour(application).

-export([start/2, stop/1]).

%% Implements: SRS003
%% @relation(SRS003, scope=line)
start(_StartType, _StartArgs) ->
    atc_tower_sup:start_link().

stop(_State) ->
    ok.
