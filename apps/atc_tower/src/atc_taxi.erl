%%%-------------------------------------------------------------------
%%% @doc Synthetic surface: one runway, a parallel, and two connectors.
%%% Implements: SRS018
%%% @relation(SRS018, scope=file)
%%%-------------------------------------------------------------------
-module(atc_taxi).

-export([synthetic/1, on_runway/4, point/3, reciprocal/2]).

-define(LENGTH, 6000.0).
-define(HALF, 75.0).
-define(PITCH, 1500.0).
-define(OFFSET, 400.0).

%% Implements: SRS018
%% @relation(SRS018, scope=line)
synthetic(RunwayIds) ->
    Ids = lists:sort([Id || Id <- RunwayIds, is_binary(Id)]),
    Index = maps:from_list(lists:zip(Ids, lists:seq(0, length(Ids) - 1))),
    #{
        index => Index,
        length_ft => ?LENGTH,
        half_width_ft => ?HALF,
        nodes => lists:flatmap(fun(Id) -> surface_nodes(Id, maps:get(Id, Index)) end, Ids)
    }.

%% Implements: SRS018
%% @relation(SRS018, scope=line)
on_runway(Graph, Runway, X, Y) when is_number(X), is_number(Y) ->
    case maps:find(Runway, maps:get(index, Graph)) of
        {ok, Index} ->
            Center = Index * ?PITCH,
            X >= 0.0 andalso X =< ?LENGTH andalso abs(Y - Center) =< ?HALF;
        error ->
            false
    end;
on_runway(_Graph, _Runway, _X, _Y) ->
    false.

point(Graph, Runway, Along) ->
    Index = maps:get(Runway, maps:get(index, Graph)),
    {Along, Index * ?PITCH}.

reciprocal(Left, Right) when is_binary(Left), is_binary(Right) ->
    case {number(Left), number(Right)} of
        {A, B} when is_integer(A), is_integer(B) ->
            abs(A - B) =:= 18;
        _ ->
            false
    end;
reciprocal(_Left, _Right) ->
    false.

surface_nodes(Id, Index) ->
    Y = Index * ?PITCH,
    [
        #{id => <<Id/binary, "-runway">>, kind => runway, runway => Id, x_ft => 3000.0, y_ft => Y},
        #{
            id => <<Id/binary, "-parallel">>,
            kind => parallel,
            runway => Id,
            x_ft => 3000.0,
            y_ft => Y + ?OFFSET
        },
        #{
            id => <<Id/binary, "-connector-a">>,
            kind => connector,
            runway => Id,
            x_ft => 200.0,
            y_ft => Y + (?OFFSET / 2)
        },
        #{
            id => <<Id/binary, "-connector-b">>,
            kind => connector,
            runway => Id,
            x_ft => 5800.0,
            y_ft => Y + (?OFFSET / 2)
        }
    ].

number(Runway) ->
    case re:run(Runway, "^([0-9]{2})", [{capture, all_but_first, list}]) of
        {match, [Digits]} -> list_to_integer(Digits);
        _ -> none
    end.
