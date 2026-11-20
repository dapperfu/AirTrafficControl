%%%-------------------------------------------------------------------
%%% Verifies: SRS003, SRS004, SRS015, SDD004
%%% @relation(SRS003, SRS004, SRS015, SDD004, scope=file)
%%%-------------------------------------------------------------------
-module(atc_cluster_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    single_computer/1,
    partition_keeps_one_authority/1,
    restart_replays_before_issuing/1,
    ra_follower_cannot_commit/1,
    monitor_restart_keeps_log/1,
    proper_campaign/1
]).

all() ->
    [
        single_computer,
        partition_keeps_one_authority,
        restart_replays_before_issuing,
        ra_follower_cannot_commit,
        monitor_restart_keeps_log,
        proper_campaign
    ].

init_per_suite(Config) ->
    Dir = "/tmp/atc-tower-ct",
    ok = filelib:ensure_dir(filename:join(Dir, "marker")),
    {ok, _} = ra:start([{data_dir, Dir}]),
    {ok, _} = application:ensure_all_started(atc_tower),
    Config.

end_per_suite(Config) ->
    application:stop(atc_tower),
    application:stop(ra),
    Config.

single_computer(_Config) ->
    State = atc_separation:new(#{runways => runways(), max_aircraft => 8}),
    View = atc_cluster:form(1, State),
    1 = atc_cluster:leader(View),
    {ok, _, Next} = atc_cluster:command(View, 1, {assign, <<"N1">>, <<"27">>, departure}),
    1 = length(atc_separation:issued(maps:get(state, Next))).

partition_keeps_one_authority(_Config) ->
    State = atc_separation:new(#{runways => runways(), max_aircraft => 8}),
    View = atc_cluster:form(3, State),
    {Left, Right} = atc_cluster:split(View, [1]),
    none = atc_cluster:leader(Left),
    2 = atc_cluster:leader(Right),
    {error, no_quorum, _} = atc_cluster:command(Left, 1, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, _, Committed} = atc_cluster:command(Right, 2, {assign, <<"N1">>, <<"27">>, departure}),
    1 = length(atc_separation:issued(maps:get(state, Committed))),
    Pair = atc_cluster:form(2, State),
    Down = atc_cluster:crash(Pair, 1),
    none = atc_cluster:leader(Down),
    {error, no_quorum, _} = atc_cluster:command(Down, 2, {assign, <<"N1">>, <<"27">>, departure}).

restart_replays_before_issuing(_Config) ->
    State = atc_separation:new(#{runways => runways(), max_aircraft => 8}),
    View = atc_cluster:form(3, State),
    {ok, _, Issued} = atc_cluster:command(View, 1, {assign, <<"N1">>, <<"27">>, departure}),
    Crashed = atc_cluster:crash(Issued, 1),
    2 = atc_cluster:leader(Crashed),
    {ok, _, After} = atc_cluster:command(Crashed, 2, {assign, <<"N2">>, <<"18">>, arrival}),
    2 = length(atc_separation:issued(maps:get(state, After))),
    {error, down, _} = atc_cluster:command(After, 1, {assign, <<"N3">>, <<"18">>, departure}),
    Restarted = atc_cluster:restart(After, 1),
    2 = atc_cluster:leader(Restarted),
    {error, catching_up, _} = atc_cluster:command(Restarted, 1, {assign, <<"N2">>, <<"18">>, arrival}),
    Ready = atc_cluster:finish_replay(Restarted, 1),
    Log = atc_separation:issued(maps:get(1, maps:get(replicas, Ready))),
    Log = atc_separation:issued(maps:get(state, Ready)).

ra_follower_cannot_commit(_Config) ->
    {ok, Service} = atc_service:open(service_config(3)),
    Ids = maps:get(ids, Service),
    {ok, _, Leader} = ra:members(hd(Ids)),
    [Follower | _] = [Id || Id <- Ids, Id =/= Leader],
    {error, {not_leader, Leader}} = atc_service:submit(
        Service, Follower, {assign, <<"N1">>, <<"27">>, departure}
    ),
    {ok, {ok, _Rec}, Leader} = atc_service:submit(
        Service, Leader, {assign, <<"N1">>, <<"27">>, departure}
    ),
    1 = length(atc_service:issued()),
    ok = atc_service:close(Service).

proper_campaign(_Config) ->
    true = prop_clearance:quickcheck().

monitor_restart_keeps_log(_Config) ->
    {ok, Service} = atc_service:open(service_config(1)),
    [Server] = maps:get(ids, Service),
    {ok, {ok, _}, Server} = atc_service:submit(
        Service, Server, {assign, <<"N1">>, <<"27">>, departure}
    ),
    1 = length(atc_monitor:issued()),
    Old = whereis(atc_monitor),
    exit(Old, kill),
    ok = wait_for_monitor(Old, 40),
    1 = length(atc_monitor:issued()),
    ok = atc_service:close(Service).

wait_for_monitor(_Old, 0) ->
    timeout;
wait_for_monitor(Old, N) ->
    case whereis(atc_monitor) of
        Pid when is_pid(Pid), Pid =/= Old ->
            case erlang:is_process_alive(Pid) of
                true ->
                    ok;
                false ->
                    timer:sleep(50),
                    wait_for_monitor(Old, N - 1)
            end;
        _ ->
            timer:sleep(50),
            wait_for_monitor(Old, N - 1)
    end.

service_config(Computers) ->
    {ok, Config} = atc_config:from_binary(io_lib:format(
        "[airport]\nicao = \"KTEST\"\nlatitude = 40.0\nlongitude = -75.0\n"
        "communications_distance_nm = 30.0\ncomputers = ~b\n"
        "max_runways = 4\nmax_aircraft = 8\nmax_neighbors = 1\n"
        "[[runway]]\nid = \"27\"\ndesignation = \"both\"\nindependent = true\nintersects = []\n"
        "[[runway]]\nid = \"18\"\ndesignation = \"both\"\nindependent = true\nintersects = []\n"
        "[[neighbor]]\nicao = \"KNEAR\"\nlatitude = 40.1\nlongitude = -75.0\n",
        [Computers]
    )),
    Config.

runways() ->
    #{
        <<"27">> => #{designation => both, independent => true, intersects => []},
        <<"18">> => #{designation => both, independent => true, intersects => []}
    }.
