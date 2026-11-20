%%%-------------------------------------------------------------------
%%% @doc Start one airport from its TOML file, or refuse to control traffic.
%%% Implements: SRS001
%%% Implements: SUM001
%%% @relation(SRS001, SUM001, scope=file)
%%%-------------------------------------------------------------------
-module(atc_tower_cli).

-export([main/1, run/1]).

%% Implements: SRS001
%% @relation(SRS001, scope=line)
main(Args) ->
    case run(Args) of
        {ok, Text} ->
            io:format("~s~n", [Text]);
        {error, Text} ->
            io:format("~s~n", [Text]),
            halt(1)
    end.

%% Implements: SUM001
%% @relation(SUM001, scope=line)
run([Path]) ->
    case atc_config:load(Path) of
        {ok, Config} ->
            DataDir = filename:join("/tmp", binary_to_list(maps:get(icao, Config)) ++ "-atc"),
            ok = filelib:ensure_dir(filename:join(DataDir, "marker")),
            {ok, _} = ra:start([{data_dir, DataDir}]),
            {ok, _} = application:ensure_all_started(atc_tower),
            case atc_service:open(Config) of
                {ok, _Service} ->
                    {ok,
                        iolist_to_binary(
                            io_lib:format(
                                "airport ~s ready on ~b computers",
                                [maps:get(icao, Config), maps:get(computers, Config)]
                            )
                        )};
                {error, Reason} ->
                    {error, iolist_to_binary(io_lib:format("configuration refused: ~p", [Reason]))}
            end;
        {error, Reason} ->
            {error, iolist_to_binary(io_lib:format("configuration refused: ~p", [Reason]))}
    end;
run(_Args) ->
    {error, <<"usage: atc_tower_cli CONFIG.toml">>}.
