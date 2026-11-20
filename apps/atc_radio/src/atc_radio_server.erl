-module(atc_radio_server).

-behaviour(gen_server).

-export([start_link/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

start_link(Options) ->
    gen_server:start_link(?MODULE, Options, []).

stop(Pid) ->
    gen_server:call(Pid, stop).

init(Options) ->
    Icao = maps:get(icao, Options),
    Mode = maps:get(mode, Options),
    {ok, Address} = inet:parse_address(maps:get(bind, Options)),
    Services = parse_freqs(maps:get(freqs, Options)),
    Sockets = bind_services(Address, Services),
    {Tower, World} = open_tower(Mode, maps:get(config, Options)),
    LogDir = maps:get(log_dir, Options),
    ok = filelib:ensure_dir(filename:join(LogDir, "marker")),
    Schedulers = erlang:system_info(schedulers_online),
    Ready = filename:join(LogDir, binary_to_list(Icao) ++ ".ready"),
    ok = file:write_file(Ready, integer_to_binary(Schedulers)),
    io:format("radio ~s ready schedulers ~b~n", [Icao, Schedulers]),
    {ok, #{
        icao => Icao,
        mode => Mode,
        sockets => Sockets,
        service => Tower,
        world => World,
        log_dir => LogDir,
        clock => 0
    }}.

handle_call(stop, _From, State) ->
    close_all(State),
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({udp, Socket, Host, RemotePort, Packet}, State) ->
    {noreply, handle_packet(Socket, Host, RemotePort, Packet, State)};
handle_info(_Message, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    close_all(State),
    ok.

handle_packet(Socket, Host, RemotePort, Packet, State) ->
    case atc_radio_phrase:decode(Packet) of
        {clock, Time} ->
            State#{clock => Time};
        {track, Rest} ->
            note_track(State, Rest);
        {flight, Uuid, Chapter, Callsign, English} ->
            case safe_flight(Uuid, Callsign) of
                false ->
                    State;
                true ->
                    exchange(Socket, Host, RemotePort, Uuid, Chapter, Callsign, English, State)
            end;
        {error, _} ->
            State
    end.

exchange(Socket, Host, RemotePort, Uuid, Chapter, Callsign, English, State) ->
    #{port := Port, services := Services} = socket_meta(Socket, State),
    {Mhz, Facility} = facility(English, Services),
    Line1 = <<"flight ", Uuid/binary, " ", Chapter/binary, " ", Callsign/binary>>,
    log_line(State, Uuid, Chapter, Callsign, Mhz, Port, Facility, <<"in">>, Line1, English),
    {ReplyKind, ReplyArg, Next} = decide(State, Callsign, English),
    Reply = atc_radio_phrase:reply(ReplyKind, ReplyArg),
    Out = <<Line1/binary, "\n", Reply/binary, "\n">>,
    gen_udp:send(Socket, Host, RemotePort, Out),
    log_line(Next, Uuid, Chapter, Callsign, Mhz, Port, Facility, <<"out">>, Line1, Reply),
    publish_world(Next).

decide(#{mode := enroute} = State, _Callsign, English) ->
    {scripted, English, State};
decide(#{mode := tower} = State, Callsign, English) ->
    case atc_radio_phrase:interpret(Callsign, English) of
        scripted ->
            {scripted, English, State};
        {command, Command} ->
            consider(State, Command);
        {routine, Request} ->
            consider(State, Request)
    end.

%% The guard is the only writer. A proposal that is not safe becomes an exception.
consider(#{service := Service, world := World} = State, Request) when is_map(World) ->
    Sep = current_sep(),
    case atc_policy:propose(Sep, World, Request) of
        {issue, Command} ->
            commit_proposal(State, Service, World, Command);
        {refuse, Command, _Reason} ->
            commit_proposal(State, Service, World, Command);
        {defer, Package} ->
            {standby, Package, State#{world => atc_world:push_exception(World, Package)}};
        {cab, Strip} ->
            Phrase = atc_cab:ifr_phrase(Strip),
            {flight_data, Phrase, State#{world => atc_world:put_strip(World, Strip)}}
    end;
consider(State, _Request) ->
    {scripted, <<"roger">>, State}.

commit_proposal(State, Service, World, Command) ->
    case submit(Service, Command) of
        {ok, _Rec} ->
            Sep = current_sep(),
            {{command, Command}, ok, State#{world => atc_world:note_issued(World, Sep, Command)}};
        {error, Reason} ->
            Package = atc_exception:package(
                atc_policy:aircraft_of(Command),
                Reason,
                Command,
                [],
                maps:get(last_clearance, World, none)
            ),
            {{command, Command}, {error, Reason}, State#{world => atc_world:push_exception(World, Package)}}
    end.

current_sep() ->
    case atc_service:state() of
        {ok, Sep} -> Sep;
        _ -> atc_separation:new(#{})
    end.

publish_world(#{world := World} = State) when is_map(World) ->
    persistent_term:put(atc_world_overlay, atc_world:picture(World)),
    State;
publish_world(State) ->
    State.

note_track(#{world := World} = State, Rest) when is_map(World) ->
    case track_fields(Rest) of
        error ->
            State;
        Track ->
            publish_world(State#{world => atc_world:publish_track(World, Track)})
    end;
note_track(State, _Rest) ->
    State.

track_fields(Rest) ->
    Parts = binary:split(Rest, <<" ">>, [global, trim_all]),
    case Parts of
        [Id, Time, X, Y, Alt, Vx, Vy, Wake, Runway] ->
            #{
                id => Id,
                time_s => number_text(Time),
                x_ft => number_text(X),
                y_ft => number_text(Y),
                alt_ft => number_text(Alt),
                vx_fps => number_text(Vx),
                vy_fps => number_text(Vy),
                wake => Wake,
                runway => Runway
            };
        _ ->
            error
    end.

number_text(Text) ->
    case string:to_float(binary_to_list(Text)) of
        {Value, _} when is_float(Value) -> Value;
        {error, no_float} ->
            case string:to_integer(binary_to_list(Text)) of
                {Value, _} when is_integer(Value) -> Value;
                _ -> 0
            end
    end.

submit(Service, Command) ->
    #{ids := [First | _]} = Service,
    submit_to(Service, First, Command, 3).

submit_to(_Service, _Server, _Command, 0) ->
    {error, not_leader};
submit_to(Service, Server, Command, Left) ->
    case atc_service:submit(Service, Server, Command) of
        {error, {not_leader, Leader}} ->
            submit_to(Service, Leader, Command, Left - 1);
        {ok, {ok, Record}, _Leader} ->
            {ok, Record};
        {ok, {error, Reason}, _Leader} ->
            {error, Reason};
        {error, Reason} ->
            {error, Reason}
    end.

log_line(State, Uuid, Chapter, Callsign, Mhz, Port, Facility, Direction, Line1, Line2) ->
    atc_radio_log:append(maps:get(log_dir, State), Chapter, #{
        sim_time => maps:get(clock, State),
        airport => maps:get(icao, State),
        facility => Facility,
        frequency_mhz => mhz_text(Mhz),
        port => Port,
        direction => Direction,
        flight => Uuid,
        chapter => Chapter,
        callsign => Callsign,
        line1 => Line1,
        line2 => Line2
    }).

open_tower(enroute, _Config) ->
    {none, none};
open_tower(tower, Config) ->
    {ok, Loaded} = atc_config:load(Config),
    {ok, Service} = atc_service:open(Loaded),
    World = atc_world:new(#{runways => maps:get(runways, Loaded)}),
    persistent_term:put(atc_world_overlay, atc_world:picture(World)),
    {Service, World}.

parse_freqs(Text) when is_list(Text) ->
    parse_freqs(list_to_binary(Text));
parse_freqs(Text) when is_binary(Text) ->
    [
        parse_freq(Part)
     || Part <- binary:split(Text, <<";">>, [global]), Part =/= <<>>
    ].

parse_freq(Part) ->
    case binary:split(Part, <<"|">>, [global]) of
        [Mhz, Name, Type] ->
            {number(Mhz), Name, Type};
        [Mhz, Name] ->
            {number(Mhz), Name, <<"TWR">>}
    end.

number(Text) ->
    case string:to_float(binary_to_list(Text)) of
        {Value, _Rest} when is_float(Value) ->
            Value;
        {error, no_float} ->
            case string:to_integer(binary_to_list(Text)) of
                {Value, _Rest} when is_integer(Value) ->
                    Value * 1.0;
                _ ->
                    118.0
            end
    end.

bind_services(Address, Services) ->
    Grouped = lists:foldl(
        fun({Mhz, Name, Type}, Acc) ->
            Port = atc_radio_phrase:port(Mhz),
            maps:update_with(
                Port,
                fun(List) -> [{Mhz, Name, Type} | List] end,
                [{Mhz, Name, Type}],
                Acc
            )
        end,
        #{},
        Services
    ),
    maps:fold(
        fun(Port, Group, Acc) ->
            {ok, Socket} = gen_udp:open(Port, [binary, {active, true}, {ip, Address}]),
            Acc#{Socket => #{port => Port, services => lists:reverse(Group)}}
        end,
        #{},
        Grouped
    ).

socket_meta(Socket, State) ->
    maps:get(Socket, maps:get(sockets, State)).

facility(English, [{Mhz, Name, _Type} | _] = Services) ->
    Lower = string:lowercase(English),
    case
        lists:search(
            fun({_Mhz, ServiceName, _Kind}) ->
                string:find(Lower, string:lowercase(ServiceName)) =/= nomatch
            end,
            Services
        )
    of
        {value, {FoundMhz, FoundName, _}} ->
            {FoundMhz, FoundName};
        false ->
            {Mhz, Name}
    end.

close_all(State) ->
    maps:foreach(fun(Socket, _Meta) -> gen_udp:close(Socket) end, maps:get(sockets, State, #{})),
    case maps:get(service, State, none) of
        none ->
            ok;
        Service ->
            atc_service:close(Service)
    end.

safe_flight(Uuid, Callsign) ->
    safe(Uuid, 80, true) andalso safe(Callsign, 16, false).

safe(Text, Max, Hex) ->
    Size = byte_size(Text),
    Size > 0 andalso Size =< Max andalso
        lists:all(
            fun(Byte) ->
                (Byte >= $0 andalso Byte =< $9) orelse
                    (Byte >= $A andalso Byte =< $Z) orelse
                    (Byte >= $a andalso Byte =< $z) orelse
                    (Hex andalso Byte =:= $-)
            end,
            binary_to_list(Text)
        ).

mhz_text(Mhz) when is_integer(Mhz) ->
    mhz_text(Mhz * 1.0);
mhz_text(Mhz) when is_float(Mhz) ->
    iolist_to_binary(io_lib:format("~.3f", [Mhz])).
