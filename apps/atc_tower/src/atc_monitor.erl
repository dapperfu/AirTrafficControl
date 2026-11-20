%%%-------------------------------------------------------------------
%%% @doc Local process supervised beside the clearance log.
%%% The log lives in Ra, so restarting this process does not create a second authority.
%%% Implements: SDD001
%%% Implements: SRS015
%%% @relation(SDD001, SRS015, scope=file)
%%%-------------------------------------------------------------------
-module(atc_monitor).

-behaviour(gen_server).

-export([start_link/0, issued/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% Implements: SDD001
%% @relation(SDD001, scope=line)
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

issued() ->
    gen_server:call(?MODULE, issued).

init([]) ->
    {ok, #{}}.

%% Implements: SRS015
%% @relation(SRS015, scope=line)
handle_call(issued, _From, State) ->
    {reply, atc_service:issued(), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.
