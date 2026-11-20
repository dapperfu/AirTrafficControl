%%%-------------------------------------------------------------------
%%% @doc Predictive picture beside the clearance log.
%%% Implements: SRS017
%%% Implements: SRS020
%%% @relation(SRS017, SRS020, scope=file)
%%%-------------------------------------------------------------------
-module(atc_world).

-export([
    new/1,
    publish_track/2,
    note_issued/3,
    push_exception/2,
    put_strip/2,
    set_weather/2,
    record_configuration/2,
    add_vehicle/2,
    add_emergency/2,
    add_nordo/2,
    picture/1
]).

%% Implements: SRS017
%% @relation(SRS017, scope=line)
new(Opts) ->
    Runways = maps:get(runways, Opts),
    #{
        runways => Runways,
        time_s => maps:get(time_s, Opts, 0),
        tracks => atc_tracks:new(),
        taxi => atc_taxi:synthetic(maps:keys(Runways)),
        weather => atc_cab:weather_open(),
        vehicles => [],
        emergencies => [],
        nordo => [],
        windows => #{},
        exceptions => atc_exception:new(),
        last_clearance => none,
        strips => #{},
        nav => maps:get(nav, Opts, []),
        configuration => none,
        radio_s => 0,
        losses => 0,
        incursions => 0
    }.

%% Implements: SRS017
%% @relation(SRS017, scope=line)
publish_track(World, Track) ->
    Tracks = atc_tracks:publish(maps:get(tracks, World), Track),
    World#{
        tracks => Tracks,
        time_s => maps:get(time_s, Track, maps:get(time_s, World))
    }.

note_issued(World, Sep, Command) ->
    Aircraft = atc_policy:aircraft_of(Command),
    World#{
        windows => occupy(World, Sep, Command, Aircraft),
        last_clearance => Command,
        radio_s => maps:get(radio_s, World) + 3
    }.

%% Implements: SRS020
%% @relation(SRS020, scope=line)
push_exception(World, Package) ->
    Reason = maps:get(reason, Package),
    World#{
        exceptions => atc_exception:push(maps:get(exceptions, World), Package),
        losses => maps:get(losses, World) + loss_inc(Reason),
        incursions => maps:get(incursions, World) + incursion_inc(Package),
        radio_s => maps:get(radio_s, World) + 2
    }.

put_strip(World, #{aircraft := Aircraft} = Strip) ->
    World#{strips => maps:put(Aircraft, Strip, maps:get(strips, World))}.

set_weather(World, Weather) ->
    World#{weather => Weather}.

record_configuration(World, Runway) ->
    World#{configuration => Runway}.

add_vehicle(World, Vehicle) ->
    World#{vehicles => [Vehicle | maps:get(vehicles, World)]}.

add_emergency(World, Aircraft) ->
    World#{emergencies => lists:usort([Aircraft | maps:get(emergencies, World)])}.

add_nordo(World, Aircraft) ->
    World#{nordo => lists:usort([Aircraft | maps:get(nordo, World)])}.

%% Implements: SRS020
%% @relation(SRS020, scope=line)
picture(World) ->
    #{
        <<"exceptions">> => [exception_row(Package) || Package <- atc_exception:list(maps:get(exceptions, World))],
        <<"weather">> => atc_cab:weather_view(maps:get(weather, World)),
        <<"vehicles">> => [vehicle_row(Vehicle) || Vehicle <- maps:get(vehicles, World)],
        <<"strips">> => strip_rows(maps:get(strips, World)),
        <<"frequencies">> => atc_cab:frequency_rows()
    }.

occupy(World, Sep, Command, Aircraft) ->
    Windows = maps:get(windows, World),
    case window(Sep, Command, Aircraft, wake_of(World, Aircraft), maps:get(time_s, World)) of
        none -> Windows;
        {Runway, Window} -> Windows#{Runway => Window}
    end.

window(Sep, {takeoff, Aircraft}, Aircraft, Wake, Time) ->
    case sep_runway(Sep, Aircraft) of
        none -> none;
        Runway -> {Runway, #{free_at => Time + atc_wake:occupy_s(departure), wake => Wake, id => Aircraft}}
    end;
window(Sep, {land, Aircraft}, Aircraft, Wake, Time) ->
    case sep_runway(Sep, Aircraft) of
        none -> none;
        Runway -> {Runway, #{free_at => Time + atc_wake:occupy_s(arrival), wake => Wake, id => Aircraft}}
    end;
window(_Sep, _Command, _Aircraft, _Wake, _Time) ->
    none.

wake_of(World, Aircraft) ->
    case atc_tracks:find(maps:get(tracks, World), Aircraft) of
        none -> small;
        Track -> maps:get(wake, Track, small)
    end.

sep_runway(Sep, Aircraft) ->
    case maps:find(Aircraft, maps:get(aircraft, Sep, #{})) of
        {ok, #{runway := Runway}} when Runway =/= none -> Runway;
        _ -> none
    end.

loss_inc(conflict) -> 1;
loss_inc(separation) -> 1;
loss_inc(_) -> 0.

incursion_inc(Package) ->
    case maps:get(incursion, Package, false) of
        true -> 1;
        false -> 0
    end.

exception_row(Package) ->
    #{
        <<"reason">> => text(maps:get(reason, Package)),
        <<"aircraft">> => maybe_id(maps:get(aircraft, Package, none)),
        <<"summary">> => maps:get(summary, Package, <<>>),
        <<"affected">> => [Id || Id <- maps:get(affected, Package, []), is_binary(Id)]
    }.

vehicle_row(Vehicle) ->
    #{
        <<"id">> => maps:get(id, Vehicle),
        <<"runway">> => maybe_id(maps:get(runway, Vehicle, none))
    }.

strip_rows(Strips) ->
    maps:fold(
        fun(Aircraft, Strip, Acc) ->
            [
                #{
                    <<"aircraft">> => Aircraft,
                    <<"plan">> => maps:get(plan, Strip, <<>>),
                    <<"atis">> => maps:get(atis, Strip, <<"A">>),
                    <<"readback">> => maps:get(readback, Strip, false) =:= true
                }
                | Acc
            ]
        end,
        [],
        Strips
    ).

maybe_id(none) -> null;
maybe_id(Value) when is_binary(Value) -> Value;
maybe_id(Value) when is_atom(Value) -> atom_to_binary(Value).

text(Value) when is_binary(Value) -> Value;
text(Value) when is_atom(Value) -> atom_to_binary(Value);
text(Value) -> iolist_to_binary(io_lib:format("~p", [Value])).
