-module(atc_radio_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([phrase/1, sfo_departure/1]).

all() ->
    [phrase, sfo_departure].

init_per_suite(Config) ->
    DataDir = "/tmp/atc-radio-ct",
    ok = filelib:ensure_dir(filename:join(DataDir, "marker")),
    case ra:start([{data_dir, DataDir}]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end,
    {ok, _} = application:ensure_all_started(atc_radio),
    Config.

end_per_suite(_Config) ->
    application:stop(atc_radio),
    catch ra:stop(),
    ok.

phrase(_Config) ->
    20000 = atc_radio_phrase:port(118.0),
    20100 = atc_radio_phrase:port(120.5),
    {command, {takeoff, <<"N123">>}} =
        atc_radio_phrase:classify(<<"N123">>, <<"cleared for takeoff">>),
    {command, {assign, <<"N123">>, <<"28R">>, departure}} =
        atc_radio_phrase:classify(<<"N123">>, <<"runway 28R for departure">>),
    {command, {land, <<"N123">>}} =
        atc_radio_phrase:classify(<<"N123">>, <<"cleared to land">>),
    {command, {handoff, <<"N123">>, <<"Center">>, true}} =
        atc_radio_phrase:classify(<<"N123">>, <<"contact Center">>),
    {command, {link, <<"Center">>, true}} =
        atc_radio_phrase:classify(<<"N123">>, <<"link Center up">>),
    scripted =
        atc_radio_phrase:classify(<<"N123">>, <<"request IFR clearance to Chicago">>),
    <<"cleared as filed">> =
        atc_radio_phrase:reply(scripted, <<"request IFR clearance to Chicago">>),
    <<"climb and maintain">> =
        atc_radio_phrase:reply(scripted, <<"climb and maintain flight level three five zero">>),
    ok.

sfo_departure(_Config) ->
    LogDir = "/tmp/atc-radio-ct-log",
    ok = filelib:ensure_dir(filename:join(LogDir, "marker")),
    {ok, Pid} = atc_radio_server:start_link(#{
        icao => <<"KSFO">>,
        bind => "127.0.0.1",
        config => example_config(),
        log_dir => LogDir,
        mode => tower,
        freqs => "120.5|San Francisco Tower|TWR"
    }),
    Port = atc_radio_phrase:port(120.5),
    {ok, Socket} = gen_udp:open(0, [binary, {active, false}]),
    Uuid = <<"11111111-2222-4333-8444-555555555555">>,
    ok = gen_udp:send(Socket, {127, 0, 0, 1}, Port, <<"clock 42\n">>),
    exchange(Socket, Port, Uuid, <<"runway 27 for departure">>),
    exchange(Socket, Port, Uuid, <<"hold short">>),
    exchange(Socket, Port, Uuid, <<"line up and wait">>),
    Reply = exchange(Socket, Port, Uuid, <<"cleared for takeoff">>),
    true = binary:match(Reply, <<"cleared for takeoff">>) =/= nomatch,
    {ok, Text} = file:read_file(
        filename:join([LogDir, binary_to_list(Uuid), "departure.jsonl"])
    ),
    true = binary:match(Text, Uuid) =/= nomatch,
    true = binary:match(Text, <<"\"sim_time\":42">>) =/= nomatch,
    true = binary:match(Text, <<"cleared for takeoff">>) =/= nomatch,
    true = lists:any(
        fun(#{command := Command}) -> Command =:= {takeoff, <<"N123">>} end,
        atc_service:issued()
    ),
    ok = gen_udp:close(Socket),
    ok = atc_radio_server:stop(Pid).

exchange(Socket, Port, Uuid, English) ->
    Packet = <<"flight ", Uuid/binary, " departure N123\n", English/binary, "\n">>,
    ok = gen_udp:send(Socket, {127, 0, 0, 1}, Port, Packet),
    {ok, {_Host, _Port, Reply}} = gen_udp:recv(Socket, 0, 5000),
    Reply.

example_config() ->
    Root = filename:dirname(
        filename:dirname(filename:dirname(filename:dirname(code:lib_dir(atc_tower))))
    ),
    filename:join(Root, "config/example-airport.toml").
