-module(atc_radio_cli).

-export([main/1]).

main([Icao, Bind, Config, LogDir, Mode, Freqs]) ->
    ok = prepare(list_to_atom(Mode), Icao),
    {ok, _} = application:ensure_all_started(atc_radio),
    case
        atc_radio_server:start_link(#{
            icao => list_to_binary(Icao),
            bind => Bind,
            config => Config,
            log_dir => LogDir,
            mode => list_to_atom(Mode),
            freqs => Freqs
        })
    of
        {ok, _Pid} ->
            ok;
        {error, Reason} ->
            ok = filelib:ensure_dir(filename:join(LogDir, "marker")),
            file:write_file(
                filename:join(LogDir, Icao ++ ".error"),
                io_lib:format("~p~n", [Reason])
            ),
            halt(1)
    end;
main(_Args) ->
    io:format("usage: ICAO BIND CONFIG LOGDIR tower|enroute FREQS~n"),
    halt(1).

prepare(tower, Icao) ->
    DataDir = filename:join("/tmp", Icao ++ "-radio-" ++ os:getpid()),
    ok = filelib:ensure_dir(filename:join(DataDir, "marker")),
    case ra:start([{data_dir, DataDir}]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end;
prepare(enroute, _Icao) ->
    ok.
