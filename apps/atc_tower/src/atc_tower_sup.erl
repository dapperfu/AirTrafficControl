%%%-------------------------------------------------------------------
%%% @doc Supervision tree for one airport computer.
%%% Implements: SDD001
%%% @relation(SDD001, scope=file)
%%%-------------------------------------------------------------------
-module(atc_tower_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

%% Implements: SDD001
%% @relation(SDD001, scope=line)
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% Implements: SDD001
%% @relation(SDD001, scope=line)
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 5,
        period => 10
    },
    ChildSpecs = [],
    {ok, {SupFlags, ChildSpecs}}.
