%%%-------------------------------------------------------------------
%%% @doc Start one airport from its TOML file, or refuse to control traffic.
%%% Implements: SRS001
%%% Implements: SUM001
%%% @relation(SRS001, SUM001, scope=file)
%%%-------------------------------------------------------------------
-module(atc_tower_cli).

-export([main/1, run/1, listen/2]).

%% Implements: SRS001
%% @relation(SRS001, scope=line)
main(["serve" | Rest]) ->
    case listen_args(Rest) of
        {ok, Text} ->
            io:format("~s~n", [Text]),
            receive
                atc_front_stop ->
                    ok
            end;
        {error, Text} ->
            io:format("~s~n", [Text]),
            halt(1)
    end;
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
            open_loaded(Config);
        {error, Reason} ->
            refused(Reason)
    end;
run(_Args) ->
    {error, <<"usage: atc_tower_cli CONFIG.toml">>}.

%% Open the airport and bind 127.0.0.1 so a front can attach.
%% Port 0 asks the operating system for a free port.
listen(Path, Port) ->
    case parse_port(Port) of
        error ->
            {error, <<"usage: atc_tower_cli serve CONFIG.toml [PORT]">>};
        {ok, Number} ->
            case run([Path]) of
                {ok, Text} ->
                    open_front(Path, Text, Number);
                Error ->
                    Error
            end
    end.

listen_args([]) ->
    {error, <<"usage: atc_tower_cli serve CONFIG.toml [PORT]">>};
listen_args([Path]) ->
    listen(Path, 7878);
listen_args([Path, Port]) ->
    listen(Path, Port);
listen_args(_Rest) ->
    {error, <<"usage: atc_tower_cli serve CONFIG.toml [PORT]">>}.

open_loaded(Config) ->
    DataDir = filename:join("/tmp", binary_to_list(maps:get(icao, Config)) ++ "-atc"),
    ok = filelib:ensure_dir(filename:join(DataDir, "marker")),
    ok = start_ra(DataDir),
    {ok, _} = application:ensure_all_started(atc_tower),
    case atc_service:open(Config) of
        {ok, _Service} ->
            {ok, ready_text(Config)};
        {error, Reason} ->
            refused(Reason)
    end.

open_front(Path, Text, Port) ->
    case atc_config:load(Path) of
        {ok, Config} ->
            case atc_front:start_link(Port, atc_front:meta(Config)) of
                {ok, _Pid} ->
                    Actual = atc_front:port(),
                    {ok,
                        iolist_to_binary([
                            Text,
                            "\nfront 127.0.0.1:",
                            integer_to_binary(Actual)
                        ])};
                {error, Reason} ->
                    refused(Reason)
            end;
        {error, Reason} ->
            refused(Reason)
    end.

start_ra(DataDir) ->
    case ra:start([{data_dir, DataDir}]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end.

ready_text(Config) ->
    iolist_to_binary(
        io_lib:format(
            "airport ~s ready on ~b computers",
            [maps:get(icao, Config), maps:get(computers, Config)]
        )
    ).

refused(Reason) ->
    {error, iolist_to_binary(io_lib:format("configuration refused: ~p", [Reason]))}.

parse_port(Port) when is_integer(Port), Port >= 0, Port < 65536 ->
    {ok, Port};
parse_port(Port) when is_binary(Port) ->
    parse_port(binary_to_list(Port));
parse_port(Port) when is_list(Port) ->
    case string:to_integer(Port) of
        {Number, []} when Number >= 0, Number < 65536 ->
            {ok, Number};
        _ ->
            error
    end;
parse_port(_) ->
    error.
