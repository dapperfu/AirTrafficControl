%%%-------------------------------------------------------------------
%%% Attaches a line client to a running tower and walks a clearance.
%%%-------------------------------------------------------------------
-module(atc_front_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1, end_per_testcase/2]).
-export([picture_round_trip/1, attached_clearance/1, follows_leader/1]).

all() ->
    [picture_round_trip, attached_clearance, follows_leader].

init_per_suite(Config) ->
    Dir = "/tmp/atc-front-ct",
    ok = filelib:ensure_dir(filename:join(Dir, "marker")),
    ok = start_ra(Dir),
    {ok, _} = application:ensure_all_started(atc_tower),
    Config.

end_per_suite(Config) ->
    application:stop(atc_tower),
    application:stop(ra),
    Config.

end_per_testcase(_Name, Config) ->
    catch atc_front:stop(),
    case persistent_term:get(atc_service_current, undefined) of
        undefined ->
            ok;
        Service ->
            catch atc_service:close(Service),
            persistent_term:erase(atc_service_current)
    end,
    Config.

picture_round_trip(_Config) ->
    State = atc_separation:new(#{
        runways => #{
            <<"27">> => #{designation => both, independent => true, intersects => []}
        },
        links => #{<<"KNEAR">> => true},
        max_aircraft => 8
    }),
    {ok, First, _} = atc_separation:transition(State, {assign, <<"N1">>, <<"27">>, departure}),
    {ok, Second, _} = atc_separation:transition(First, {assign, <<"N2">>, <<"27">>, departure}),
    {error, separation, Refused} = atc_separation:transition(Second, {line_up, <<"N2">>}),
    {ok, Linked, _} = atc_separation:transition(Refused, {link, <<"KNEAR">>, false}),
    Picture = atc_separation:picture(Linked),
    Picture = json:decode(iolist_to_binary(json:encode(Picture))),
    [Refusal] = [
        Rec
     || Rec <- maps:get(<<"audit">>, Picture), maps:get(<<"decision">>, Rec) =:= <<"refused">>
    ],
    <<"separation">> = maps:get(<<"reason">>, Refusal),
    <<"line up N2">> = maps:get(<<"text">>, maps:get(<<"command">>, Refusal)),
    false = lists:any(
        fun(Rec) -> maps:get(<<"decision">>, Rec) =:= <<"refused">> end,
        maps:get(<<"issued">>, Picture)
    ),
    [Link] = maps:get(<<"links">>, Picture),
    false = maps:get(<<"up">>, Link),
    true = maps:get(<<"stale">>, Link).

attached_clearance(_Config) ->
    Path = "/tmp/atc-front-ktest.toml",
    ok = file:write_file(Path, sample_toml(1)),
    {ok, Text} = atc_tower_cli:listen(Path, 0),
    true = binary:match(Text, <<"airport KTEST ready on 1 computers">>) =/= nomatch,
    true = binary:match(Text, <<"front 127.0.0.1:">>) =/= nomatch,
    Socket = connect(atc_front:port()),
    Hello = recv(Socket),
    <<"hello">> = maps:get(<<"type">>, Hello),
    <<"KTEST">> = maps:get(<<"icao">>, Hello),
    8 = maps:get(<<"max_aircraft">>, Hello),
    <<"270 at 10">> = maps:get(<<"wind">>, Hello),
    true = maps:get(<<"selected">>, neighbor(Hello, <<"KNEAR">>)),
    false = maps:get(<<"selected">>, neighbor(Hello, <<"KFAR">>)),
    Arrival = runway(Hello, <<"09">>),
    <<"arrival">> = maps:get(<<"designation">>, Arrival),
    [<<"27">>] = maps:get(<<"intersects">>, Arrival),
    Empty = call(Socket, #{<<"op">> => <<"snapshot">>}),
    <<"snapshot">> = maps:get(<<"type">>, Empty),
    [] = maps:get(<<"aircraft">>, Empty),
    Designation = submit(Socket, assign(<<"N123AB">>, <<"09">>, <<"departure">>)),
    false = maps:get(<<"accepted">>, Designation),
    <<"designation">> = maps:get(<<"reason">>, Designation),
    Queued = submit(Socket, assign(<<"N123AB">>, <<"27">>, <<"departure">>)),
    true = maps:get(<<"accepted">>, Queued),
    <<"assign N123AB 27 departure">> = maps:get(<<"summary">>, Queued),
    <<"queued">> = phase(Queued, <<"N123AB">>),
    Held = submit(Socket, #{<<"kind">> => <<"hold_short">>, <<"aircraft">> => <<"N123AB">>}),
    <<"hold">> = phase(Held, <<"N123AB">>),
    _Second = submit(Socket, assign(<<"N2">>, <<"27">>, <<"departure">>)),
    Blocked = submit(Socket, #{<<"kind">> => <<"line_up">>, <<"aircraft">> => <<"N2">>}),
    false = maps:get(<<"accepted">>, Blocked),
    <<"separation">> = maps:get(<<"reason">>, Blocked),
    Lined = submit(Socket, #{<<"kind">> => <<"line_up">>, <<"aircraft">> => <<"N123AB">>}),
    <<"occupying">> = phase(Lined, <<"N123AB">>),
    Air = submit(Socket, #{<<"kind">> => <<"takeoff">>, <<"aircraft">> => <<"N123AB">>}),
    <<"air">> = phase(Air, <<"N123AB">>),
    SecondLined = submit(Socket, #{<<"kind">> => <<"line_up">>, <<"aircraft">> => <<"N2">>}),
    <<"occupying">> = phase(SecondLined, <<"N2">>),
    Down = submit(Socket, #{<<"kind">> => <<"link">>, <<"neighbor">> => <<"KNEAR">>, <<"up">> => false}),
    false = maps:get(<<"up">>, link(Down, <<"KNEAR">>)),
    true = maps:get(<<"stale">>, link(Down, <<"KNEAR">>)),
    HandoffDown = submit(Socket, handoff(<<"N123AB">>, <<"KNEAR">>, true)),
    false = maps:get(<<"accepted">>, HandoffDown),
    <<"link_down">> = maps:get(<<"reason">>, HandoffDown),
    _Up = submit(Socket, #{<<"kind">> => <<"link">>, <<"neighbor">> => <<"KNEAR">>, <<"up">> => true}),
    Released = submit(Socket, handoff(<<"N123AB">>, <<"KNEAR">>, true)),
    true = maps:get(<<"accepted">>, Released),
    <<"gone">> = phase(Released, <<"N123AB">>),
    ok = gen_tcp:send(Socket, <<"{\n">>),
    Bad = recv(Socket),
    <<"error">> = maps:get(<<"type">>, Bad),
    <<"bad_request">> = maps:get(<<"reason">>, Bad),
    Unknown = call(Socket, #{<<"op">> => <<"dance">>}),
    <<"bad_request">> = maps:get(<<"reason">>, Unknown),
    Fly = submit(Socket, #{<<"kind">> => <<"fly">>}),
    <<"error">> = maps:get(<<"type">>, Fly),
    <<"bad_command">> = maps:get(<<"reason">>, Fly),
    ok = gen_tcp:close(Socket).

follows_leader(_Config) ->
    {ok, Config} = atc_config:from_binary(sample_toml(3)),
    {ok, Service} = atc_service:open(Config),
    Ids = maps:get(ids, Service),
    {ok, _, Leader} = ra:members(hd(Ids)),
    [Follower | _] = [Id || Id <- Ids, Id =/= Leader],
    {error, {not_leader, Leader}} = atc_service:submit(
        Service, Follower, {assign, <<"N9">>, <<"27">>, departure}
    ),
    {ok, _} = atc_front:start_link(0, atc_front:meta(Config)),
    Socket = connect(atc_front:port()),
    <<"hello">> = maps:get(<<"type">>, recv(Socket)),
    Result = submit(Socket, assign(<<"N1">>, <<"27">>, <<"departure">>)),
    true = maps:get(<<"accepted">>, Result),
    1 = length(atc_service:issued()),
    ok = gen_tcp:close(Socket).

assign(Aircraft, Runway, Intent) ->
    #{
        <<"kind">> => <<"assign">>,
        <<"aircraft">> => Aircraft,
        <<"runway">> => Runway,
        <<"intent">> => Intent
    }.

handoff(Aircraft, Neighbor, Accept) ->
    #{
        <<"kind">> => <<"handoff">>,
        <<"aircraft">> => Aircraft,
        <<"neighbor">> => Neighbor,
        <<"accept">> => Accept
    }.

submit(Socket, Command) ->
    call(Socket, #{<<"op">> => <<"submit">>, <<"command">> => Command}).

call(Socket, Map) ->
    send(Socket, Map),
    recv(Socket).

send(Socket, Map) ->
    ok = gen_tcp:send(Socket, [json:encode(Map), $\n]).

recv(Socket) ->
    recv(Socket, <<>>).

recv(Socket, Acc) ->
    case binary:split(Acc, <<"\n">>) of
        [Line, _Rest] ->
            json:decode(string:trim(Line, both, "\r\n\t "));
        _ ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 3000),
            recv(Socket, <<Acc/binary, Data/binary>>)
    end.

phase(Result, Id) ->
    maps:get(<<"phase">>, aircraft(Result, Id)).

aircraft(Result, Id) ->
    Picture = maps:get(<<"snapshot">>, Result),
    [Row] = [Row || Row <- maps:get(<<"aircraft">>, Picture), maps:get(<<"id">>, Row) =:= Id],
    Row.

link(Result, Icao) ->
    Picture = maps:get(<<"snapshot">>, Result),
    [Row] = [Row || Row <- maps:get(<<"links">>, Picture), maps:get(<<"icao">>, Row) =:= Icao],
    Row.

neighbor(Hello, Icao) ->
    [Row] = [Row || Row <- maps:get(<<"neighbors">>, Hello), maps:get(<<"icao">>, Row) =:= Icao],
    Row.

runway(Hello, Id) ->
    [Row] = [Row || Row <- maps:get(<<"runways">>, Hello), maps:get(<<"id">>, Row) =:= Id],
    Row.

connect(Port) ->
    connect(Port, 20).

connect(_Port, 0) ->
    error(connect);
connect(Port, Left) ->
    case gen_tcp:connect({127, 0, 0, 1}, Port, [binary, {active, false}], 1000) of
        {ok, Socket} ->
            Socket;
        {error, _} ->
            timer:sleep(25),
            connect(Port, Left - 1)
    end.

start_ra(Dir) ->
    case ra:start([{data_dir, Dir}]) of
        {ok, _} ->
            ok;
        {error, {already_started, _}} ->
            ok
    end.

sample_toml(Computers) ->
    io_lib:format(
        "[airport]\n"
        "icao = \"KTEST\"\n"
        "latitude = 40.0\n"
        "longitude = -75.0\n"
        "communications_distance_nm = 30.0\n"
        "computers = ~b\n"
        "max_runways = 4\n"
        "max_aircraft = 8\n"
        "max_neighbors = 2\n"
        "wind = \"270 at 10\"\n"
        "[[runway]]\n"
        "id = \"27\"\n"
        "designation = \"both\"\n"
        "independent = true\n"
        "intersects = []\n"
        "[[runway]]\n"
        "id = \"09\"\n"
        "designation = \"arrival\"\n"
        "independent = true\n"
        "intersects = [\"27\"]\n"
        "[[neighbor]]\n"
        "icao = \"KNEAR\"\n"
        "latitude = 40.1\n"
        "longitude = -75.0\n"
        "[[neighbor]]\n"
        "icao = \"KFAR\"\n"
        "latitude = 42.0\n"
        "longitude = -75.0\n",
        [Computers]
    ).
