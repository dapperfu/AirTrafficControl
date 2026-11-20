%%%-------------------------------------------------------------------
%%% @doc Local attach port for one running tower.
%%%
%%% Binds 127.0.0.1 and speaks one JSON object per line. The separation
%%% rules stay in Ra. This process only submits a command to the current
%%% leader and returns the picture that command left behind.
%%%
%%% A client reads a hello line, then sends {"op":"snapshot"} or
%%% {"op":"submit","command":{...}}. Command kinds are assign, hold_short,
%%% line_up, takeoff, land, go_around, vacate, handoff, and link.
%%% @end
%%%-------------------------------------------------------------------
-module(atc_front).

-behaviour(gen_server).

-export([start_link/2, stop/0, port/0, meta/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(PACKET, 65536).

start_link(Port, Meta) when is_map(Meta) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {Port, Meta}, []).

stop() ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        _Pid ->
            gen_server:stop(?MODULE)
    end.

port() ->
    gen_server:call(?MODULE, port).

%% Static airport description sent on every attach.
meta(Config) ->
    #{
        <<"icao">> => maps:get(icao, Config),
        <<"computers">> => maps:get(computers, Config),
        <<"max_aircraft">> => maps:get(max_aircraft, Config),
        <<"wind">> => wind_field(maps:get(wind, Config)),
        <<"runways">> => runway_rows(maps:get(runways, Config)),
        <<"neighbors">> => neighbor_rows(Config)
    }.

init({Port, Meta}) ->
    Options = [
        binary,
        {ip, {127, 0, 0, 1}},
        {active, false},
        {reuseaddr, true},
        {packet, raw}
    ],
    case gen_tcp:listen(Port, Options) of
        {ok, Listen} ->
            {ok, Actual} = inet:port(Listen),
            State = start_acceptor(#{listen => Listen, port => Actual, meta => Meta}),
            {ok, State};
        {error, Reason} ->
            {stop, Reason}
    end.

handle_call(port, _From, State) ->
    {reply, maps:get(port, State), State};
handle_call(_Request, _From, State) ->
    {reply, {error, unknown}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, normal}, #{acceptor_ref := Ref} = State) ->
    {noreply, State};
handle_info({'DOWN', Ref, process, _Pid, _Reason}, #{acceptor_ref := Ref} = State) ->
    {noreply, start_acceptor(State)};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #{listen := Listen, acceptor := Pid}) ->
    gen_tcp:close(Listen),
    exit(Pid, shutdown),
    ok.

code_change(_Old, State, _Extra) ->
    {ok, State}.

start_acceptor(State) ->
    Listen = maps:get(listen, State),
    Meta = maps:get(meta, State),
    Pid = spawn(fun() -> accept_loop(Listen, Meta) end),
    Ref = monitor(process, Pid),
    State#{acceptor => Pid, acceptor_ref => Ref}.

accept_loop(Listen, Meta) ->
    case gen_tcp:accept(Listen) of
        {ok, Socket} ->
            spawn(fun() -> session(Socket, Meta) end),
            accept_loop(Listen, Meta);
        {error, closed} ->
            ok;
        {error, _} ->
            timer:sleep(50),
            accept_loop(Listen, Meta)
    end.

session(Socket, Meta) ->
    case send_json(Socket, maps:put(<<"type">>, <<"hello">>, Meta)) of
        ok ->
            session_loop(Socket, <<>>);
        _ ->
            gen_tcp:close(Socket)
    end.

%% TCP segments do not follow JSON lines, so the buffer waits for newline.
session_loop(Socket, Buffer) ->
    case binary:split(Buffer, <<"\n">>) of
        [Line, Rest] ->
            case reply(Line) of
                noreply ->
                    session_loop(Socket, Rest);
                {reply, Map} ->
                    case send_json(Socket, Map) of
                        ok ->
                            session_loop(Socket, Rest);
                        _ ->
                            gen_tcp:close(Socket)
                    end
            end;
        _ ->
            case gen_tcp:recv(Socket, 0) of
                {ok, Data} ->
                    Next = <<Buffer/binary, Data/binary>>,
                    case byte_size(Next) > ?PACKET of
                        true ->
                            _ = send_json(Socket, error_map(<<"bad_request">>)),
                            gen_tcp:close(Socket);
                        false ->
                            session_loop(Socket, Next)
                    end;
                _ ->
                    gen_tcp:close(Socket)
            end
    end.

reply(Data) ->
    case string:trim(Data, both, "\r\n\t ") of
        <<>> ->
            noreply;
        Trimmed ->
            {reply, request(decode_json(Trimmed))}
    end.

decode_json(Bin) ->
    try json:decode(Bin) of
        Map when is_map(Map) ->
            {ok, Map};
        _ ->
            error
    catch
        _:_ ->
            error
    end.

request(error) ->
    error_map(<<"bad_request">>);
request({ok, #{<<"op">> := <<"snapshot">>}}) ->
    snapshot_map();
request({ok, #{<<"op">> := <<"submit">>, <<"command">> := Command}}) ->
    submit_map(Command);
request({ok, _}) ->
    error_map(<<"bad_request">>).

snapshot_map() ->
    case atc_service:picture() of
        {ok, Picture} ->
            Picture#{<<"type">> => <<"snapshot">>};
        {error, Reason} ->
            error_map(reason_bin(Reason))
    end.

submit_map(Command) ->
    case decode_command(Command) of
        error ->
            error_map(<<"bad_command">>);
        {ok, Decoded} ->
            commit_map(Decoded)
    end.

commit_map(Command) ->
    case commit(Command) of
        {ok, {ok, Rec}, _Leader} ->
            attach_snapshot(accepted_map(Command, Rec));
        {ok, {error, Reason}, _Leader} ->
            attach_snapshot(refused_map(Command, Reason));
        {error, Reason} ->
            error_map(reason_bin(Reason))
    end.

accepted_map(Command, Rec) ->
    #{
        <<"type">> => <<"result">>,
        <<"accepted">> => true,
        <<"summary">> => maps:get(<<"text">>, atc_separation:command_view(Command)),
        <<"uid">> => maps:get(uid, Rec)
    }.

refused_map(Command, Reason) ->
    #{
        <<"type">> => <<"result">>,
        <<"accepted">> => false,
        <<"summary">> => maps:get(<<"text">>, atc_separation:command_view(Command)),
        <<"reason">> => reason_bin(Reason)
    }.

attach_snapshot(Map) ->
    case atc_service:picture() of
        {ok, Picture} ->
            Map#{<<"snapshot">> => Picture};
        {error, Reason} ->
            Map#{<<"snapshot_error">> => reason_bin(Reason)}
    end.

commit(Command) ->
    case persistent_term:get(atc_service_current, undefined) of
        undefined ->
            {error, closed};
        Service ->
            follow_leader(Service, Command, 4)
    end.

follow_leader(_Service, _Command, 0) ->
    {error, no_leader};
follow_leader(#{ids := []}, _Command, _Left) ->
    {error, closed};
follow_leader(#{ids := [First | _]} = Service, Command, Left) ->
    Target =
        case ra:members(First) of
            {ok, _Members, Found} ->
                Found;
            _ ->
                First
        end,
    case atc_service:submit(Service, Target, Command) of
        {error, {not_leader, Elected}} ->
            case atc_service:submit(Service, Elected, Command) of
                {error, {not_leader, _}} when Left > 1 ->
                    follow_leader(Service, Command, Left - 1);
                Other ->
                    Other
            end;
        Other ->
            Other
    end.

decode_command(#{
    <<"kind">> := <<"assign">>,
    <<"aircraft">> := Aircraft,
    <<"runway">> := Runway,
    <<"intent">> := Intent
}) ->
    case {ident(Aircraft), ident(Runway), intent(Intent)} of
        {{ok, AircraftId}, {ok, RunwayId}, {ok, IntentAtom}} ->
            {ok, {assign, AircraftId, RunwayId, IntentAtom}};
        _ ->
            error
    end;
decode_command(#{<<"kind">> := <<"hold_short">>, <<"aircraft">> := Aircraft}) ->
    unary(hold_short, Aircraft);
decode_command(#{<<"kind">> := <<"line_up">>, <<"aircraft">> := Aircraft}) ->
    unary(line_up, Aircraft);
decode_command(#{<<"kind">> := <<"takeoff">>, <<"aircraft">> := Aircraft}) ->
    unary(takeoff, Aircraft);
decode_command(#{<<"kind">> := <<"land">>, <<"aircraft">> := Aircraft}) ->
    unary(land, Aircraft);
decode_command(#{<<"kind">> := <<"go_around">>, <<"aircraft">> := Aircraft}) ->
    unary(go_around, Aircraft);
decode_command(#{<<"kind">> := <<"vacate">>, <<"aircraft">> := Aircraft}) ->
    unary(vacate, Aircraft);
decode_command(#{
    <<"kind">> := <<"handoff">>,
    <<"aircraft">> := Aircraft,
    <<"neighbor">> := Neighbor,
    <<"accept">> := Accept
}) ->
    case {ident(Aircraft), ident(Neighbor), flag(Accept)} of
        {{ok, AircraftId}, {ok, NeighborId}, {ok, Bit}} ->
            {ok, {handoff, AircraftId, NeighborId, Bit}};
        _ ->
            error
    end;
decode_command(#{<<"kind">> := <<"link">>, <<"neighbor">> := Neighbor, <<"up">> := Up}) ->
    case {ident(Neighbor), flag(Up)} of
        {{ok, NeighborId}, {ok, Bit}} ->
            {ok, {link, NeighborId, Bit}};
        _ ->
            error
    end;
decode_command(_) ->
    error.

unary(Tag, Aircraft) ->
    case ident(Aircraft) of
        {ok, AircraftId} ->
            {ok, {Tag, AircraftId}};
        error ->
            error
    end.

ident(Bin) when is_binary(Bin), byte_size(Bin) > 0, byte_size(Bin) =< 16 ->
    case re:run(Bin, <<"^[A-Za-z0-9]+$">>) of
        {match, _} ->
            {ok, Bin};
        nomatch ->
            error
    end;
ident(_) ->
    error.

intent(<<"departure">>) ->
    {ok, departure};
intent(<<"arrival">>) ->
    {ok, arrival};
intent(_) ->
    error.

flag(true) ->
    {ok, true};
flag(false) ->
    {ok, false};
flag(_) ->
    error.

send_json(Socket, Map) ->
    gen_tcp:send(Socket, [iolist_to_binary(json:encode(Map)), $\n]).

error_map(Reason) when is_binary(Reason) ->
    #{<<"type">> => <<"error">>, <<"reason">> => Reason}.

reason_bin(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
reason_bin({not_leader, _}) ->
    <<"no_leader">>;
reason_bin({timeout, _}) ->
    <<"timeout">>;
reason_bin(Reason) ->
    list_to_binary(io_lib:format("~p", [Reason])).

wind_field(undefined) ->
    null;
wind_field(Value) when is_binary(Value) ->
    Value.

runway_rows(Runways) ->
    Rows = maps:fold(
        fun(Id, Info, Acc) ->
            [
                #{
                    <<"id">> => Id,
                    <<"designation">> => atom_to_binary(maps:get(designation, Info)),
                    <<"independent">> => maps:get(independent, Info),
                    <<"intersects">> => maps:get(intersects, Info)
                }
                | Acc
            ]
        end,
        [],
        Runways
    ),
    lists:sort(fun(Left, Right) -> maps:get(<<"id">>, Left) =< maps:get(<<"id">>, Right) end, Rows).

neighbor_rows(Config) ->
    Selected = maps:from_list([
        {maps:get(icao, Neighbor), true} || Neighbor <- atc_neighbors:selected(Config)
    ]),
    [
        #{
            <<"icao">> => maps:get(icao, Neighbor),
            <<"latitude">> => maps:get(latitude, Neighbor),
            <<"longitude">> => maps:get(longitude, Neighbor),
            <<"selected">> => maps:is_key(maps:get(icao, Neighbor), Selected)
        }
     || Neighbor <- maps:get(neighbors, Config)
    ].
