%%%-------------------------------------------------------------------
%%% @doc Pure view of one airport group. This is the policy PropEr samples.
%%% Ra is the runtime log. Raft itself is an assumption.
%%% Implements: SRS003
%%% Implements: SRS004
%%% Implements: SRS015
%%% @relation(SRS003, SRS004, SRS015, scope=file)
%%%-------------------------------------------------------------------
-module(atc_cluster).

-export([
    form/2,
    command/3,
    crash/2,
    restart/2,
    finish_replay/2,
    split/2,
    leader/1,
    voters/1
]).

%% Implements: SRS003
%% @relation(SRS003, scope=line)
form(N, State) when is_integer(N), N > 0 ->
    Ids = lists:seq(1, N),
    View = #{
        n => N,
        alive => Ids,
        catching_up => [],
        state => State,
        replicas => maps:from_list([{Id, State} || Id <- Ids])
    },
    View#{leader => leader(View)}.

%% Implements: SRS004
%% @relation(SRS004, scope=line)
command(View, Caller, Cmd) ->
    case lists:member(Caller, maps:get(alive, View)) of
        false ->
            {error, down, View};
        true ->
            case lists:member(Caller, maps:get(catching_up, View)) of
                true ->
                    {error, catching_up, View};
                false ->
                    case leader(View) of
                        Caller ->
                            apply_command(View, Cmd);
                        none ->
                            {error, no_quorum, View};
                        Other ->
                            {error, {not_leader, Other}, View}
                    end
            end
    end.

%% Implements: SRS015
%% @relation(SRS015, scope=line)
crash(View, Id) ->
    Next = View#{
        alive => lists:delete(Id, maps:get(alive, View)),
        catching_up => lists:delete(Id, maps:get(catching_up, View))
    },
    Next#{leader => leader(Next)}.

%% Implements: SRS015
%% @relation(SRS015, scope=line)
restart(View, Id) ->
    case lists:member(Id, maps:get(alive, View)) of
        true ->
            View;
        false ->
            Next = View#{
                alive => lists:usort([Id | maps:get(alive, View)]),
                catching_up => lists:usort([Id | maps:get(catching_up, View)]),
                replicas => maps:put(Id, maps:get(state, View), maps:get(replicas, View))
            },
            Next#{leader => leader(Next)}
    end.

finish_replay(View, Id) ->
    Next = View#{catching_up => lists:delete(Id, maps:get(catching_up, View))},
    Next#{leader => leader(Next)}.

split(View, LeftIds) ->
    RightIds = lists:seq(1, maps:get(n, View)) -- LeftIds,
    {side(View, LeftIds), side(View, RightIds)}.

leader(View) ->
    case length(voters(View)) * 2 > maps:get(n, View) of
        false ->
            none;
        true ->
            hd(lists:sort(voters(View)))
    end.

voters(View) ->
    maps:get(alive, View) -- maps:get(catching_up, View).

apply_command(View, Cmd) ->
    case atc_separation:transition(maps:get(state, View), Cmd) of
        {ok, NextState, Rec} ->
            {ok, Rec, replicate(View, NextState)};
        {error, Reason, NextState} ->
            {error, Reason, replicate(View, NextState)}
    end.

replicate(View, NextState) ->
    Replicas = lists:foldl(
        fun(Id, Acc) ->
            Acc#{Id => NextState}
        end,
        maps:get(replicas, View),
        maps:get(alive, View)
    ),
    Next = View#{state => NextState, replicas => Replicas},
    Next#{leader => leader(Next)}.

side(View, Ids) ->
    Alive = [Id || Id <- maps:get(alive, View), lists:member(Id, Ids)],
    Next = View#{alive => Alive},
    Next#{leader => leader(Next)}.
