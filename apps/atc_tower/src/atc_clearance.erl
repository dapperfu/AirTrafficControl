%%%-------------------------------------------------------------------
%%% @doc Clearance requests. Phrase text is attached only after the guard accepts.
%%% Implements: SRS008
%%% Implements: SRS009
%%% Implements: SRS010
%%% Implements: SRS011
%%% Implements: SRS012
%%% @relation(SRS008, SRS009, SRS010, SRS011, SRS012, scope=file)
%%%-------------------------------------------------------------------
-module(atc_clearance).

-export([request/2]).

%% Implements: SRS008
%% Implements: SRS010
%% Implements: SRS011
%% Implements: SRS012
%% @relation(SRS008, SRS010, SRS011, SRS012, scope=line)
request(State, Cmd) ->
    case atc_separation:transition(State, Cmd) of
        {ok, Next, Rec} ->
            {ok, Next, Rec#{text => atc_phraseology:render(Cmd, Next)}};
        {error, Reason, Next} ->
            {error, Reason, Next}
    end.
