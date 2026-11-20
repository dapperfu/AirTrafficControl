%%%-------------------------------------------------------------------
%%% @doc Exception packages for cases that are not routine and proven safe.
%%% Implements: SRS020
%%% @relation(SRS020, scope=file)
%%%-------------------------------------------------------------------
-module(atc_exception).

-export([new/0, push/2, list/1, package/5]).

%% Implements: SRS020
%% @relation(SRS020, scope=line)
new() ->
    [].

%% Implements: SRS020
%% @relation(SRS020, scope=line)
push(Queue, Package) when is_list(Queue), is_map(Package) ->
    Queue ++ [Package].

list(Queue) when is_list(Queue) ->
    Queue.

%% Implements: SRS020
%% @relation(SRS020, scope=line)
package(Aircraft, Reason, Command, Affected, Last) ->
    #{
        reason => Reason,
        command => Command,
        aircraft => Aircraft,
        affected => Affected,
        last_clearance => Last,
        incursion => false,
        summary => summary(Aircraft, Reason)
    }.

summary(Aircraft, Reason) ->
    iolist_to_binary(io_lib:format("~s ~s", [text(Aircraft), text(Reason)])).

text(Value) when is_binary(Value) -> Value;
text(Value) when is_atom(Value) -> atom_to_binary(Value);
text(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
