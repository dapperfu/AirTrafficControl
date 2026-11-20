%%%-------------------------------------------------------------------
%%% @doc Open one Ra group and accept a command only from its current leader.
%%% Implements: SRS003
%%% Implements: SRS004
%%% Implements: SRS015
%%% Implements: SDD004
%%% @relation(SRS003, SRS004, SRS015, SDD004, scope=file)
%%%-------------------------------------------------------------------
-module(atc_service).

-export([open/1, submit/3, issued/0, picture/0, state/0, close/1]).

%% Implements: SRS003
%% @relation(SRS003, scope=line)
open(Config) ->
    Token = integer_to_list(erlang:unique_integer([positive])),
    Computers = maps:get(computers, Config),
    Ids = [
        {list_to_atom("atc_" ++ Token ++ "_" ++ integer_to_list(Index)), node()}
     || Index <- lists:seq(1, Computers)
    ],
    Name = list_to_atom("atc_log_" ++ Token),
    Machine = {module, atc_ra_machine, #{sep => separation(Config)}},
    case ra:start_cluster(default, Name, Machine, Ids) of
        {ok, Started, _NotStarted} ->
            Service = #{name => Name, ids => Started},
            persistent_term:put(atc_service_current, Service),
            {ok, Service};
        {error, cluster_not_formed} = Error ->
            Error
    end.

%% Implements: SRS004
%% Implements: SDD004
%% @relation(SRS004, SDD004, scope=line)
submit(_Service, ServerId, Command) ->
    case ra:members(ServerId) of
        {ok, _Members, Leader} when Leader =:= ServerId ->
            ra:process_command(ServerId, Command);
        {ok, _Members, Leader} ->
            {error, {not_leader, Leader}};
        Other ->
            Other
    end.

%% Implements: SRS015
%% @relation(SRS015, scope=line)
issued() ->
    case persistent_term:get(atc_service_current, undefined) of
        undefined ->
            [];
        #{ids := [ServerId | _]} ->
            case ra:local_query(ServerId, fun atc_separation:issued/1) of
                {ok, {_Index, Log}, _Leader} ->
                    Log;
                _ ->
                    []
            end
    end.

%% Read the separation state. Callers use it to propose. They do not write it.
state() ->
    case persistent_term:get(atc_service_current, undefined) of
        undefined ->
            {error, closed};
        #{ids := [ServerId | _]} ->
            case ra:local_query(ServerId, fun(Sep) -> Sep end) of
                {ok, {_Index, Sep}, _Leader} when is_map(Sep) ->
                    {ok, Sep};
                Other ->
                    {error, Other}
            end
    end.

%% The attached front reads this view. It prefers the current leader.
picture() ->
    case persistent_term:get(atc_service_current, undefined) of
        undefined ->
            {error, closed};
        #{ids := Ids} ->
            read_picture(leader_first(Ids))
    end.

leader_first([ServerId | _] = Ids) ->
    case ra:members(ServerId) of
        {ok, _Members, Leader} ->
            [Leader | Ids];
        _ ->
            Ids
    end;
leader_first([]) ->
    [].

read_picture([]) ->
    {error, no_picture};
read_picture([ServerId | Rest]) ->
    case ra:local_query(ServerId, fun atc_separation:picture/1) of
        {ok, {_Index, Picture}, _} when is_map(Picture) ->
            {ok, Picture};
        _ ->
            read_picture(Rest)
    end.

close(#{ids := Ids}) ->
    lists:foreach(fun(Id) -> ra:force_delete_server(default, Id) end, Ids),
    ok.

separation(Config) ->
    Links = maps:from_list([
        {maps:get(icao, Neighbor), true}
     || Neighbor <- atc_neighbors:selected(Config)
    ]),
    atc_separation:new(#{
        runways => maps:get(runways, Config),
        links => Links,
        wind => maps:get(wind, Config),
        max_aircraft => maps:get(max_aircraft, Config)
    }).
