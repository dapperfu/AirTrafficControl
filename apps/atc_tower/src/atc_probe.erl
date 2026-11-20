%%%-------------------------------------------------------------------
%%% @doc Predict surface and runway conflicts. This module does not issue.
%%% Implements: SRS018
%%% Implements: SRS025
%%% @relation(SRS018, SRS025, scope=file)
%%%-------------------------------------------------------------------
-module(atc_probe).

-export([assess/3, runway_of/3, aircraft_of/1]).

%% Implements: SRS018
%% @relation(SRS018, scope=line)
assess(Sep, World, Command) ->
    case defer_kind(Sep, World, Command) of
        none ->
            case conflicts(Sep, World, Command) of
                none -> safe;
                Hit -> {conflict, Hit}
            end;
        Kind ->
            {defer, Kind}
    end.

%% Implements: SRS018
%% @relation(SRS018, scope=line)
runway_of(_Sep, _World, {assign, _Aircraft, Runway, _Intent}) ->
    Runway;
runway_of(Sep, World, Command) ->
    Aircraft = aircraft_of(Command),
    case sep_runway(Sep, Aircraft) of
        none -> track_runway(World, Aircraft);
        Runway -> Runway
    end.

aircraft_of({assign, Aircraft, _, _}) -> Aircraft;
aircraft_of({hold_short, Aircraft}) -> Aircraft;
aircraft_of({line_up, Aircraft}) -> Aircraft;
aircraft_of({takeoff, Aircraft}) -> Aircraft;
aircraft_of({land, Aircraft}) -> Aircraft;
aircraft_of({go_around, Aircraft}) -> Aircraft;
aircraft_of({vacate, Aircraft}) -> Aircraft;
aircraft_of({handoff, Aircraft, _, _}) -> Aircraft;
aircraft_of({taxi, Aircraft}) -> Aircraft;
aircraft_of({ready, Aircraft}) -> Aircraft;
aircraft_of({ifr, Aircraft, _}) -> Aircraft;
aircraft_of({emergency, Aircraft}) -> Aircraft;
aircraft_of(_) -> none.

defer_kind(Sep, World, Command) ->
    Aircraft = aircraft_of(Command),
    Track = track(World, Aircraft),
    Runway = runway_of(Sep, World, Command),
    case flag(Track) of
        none ->
            case lists:member(Aircraft, maps:get(nordo, World, [])) of
                true ->
                    nordo;
                false ->
                    case detected_opposite(World, Runway, Aircraft) orelse
                        maps:get(opposite, Track, false) =:= true
                    of
                        true -> opposite;
                        false -> gate(Sep, World, Command, Aircraft, Runway)
                    end
            end;
        Kind ->
            Kind
    end.

flag(Track) ->
    case maps:get(lahso, Track, false) of
        true -> lahso;
        false ->
            case maps:get(visual, Track, false) of
                true -> visual;
                false ->
                    case maps:get(intersection, Track, false) of
                        true -> intersection;
                        false ->
                            case maps:get(deviation, Track, false) of
                                true -> deviation;
                                false -> none
                            end
                    end
            end
    end.

gate(Sep, World, Command, Aircraft, Runway) ->
    case routine_surface(Command) andalso not atc_cab:weather_gate(maps:get(weather, World)) of
        true ->
            weather;
        false ->
            case routine_surface(Command) andalso emergency(Sep, World, Aircraft, Runway) of
                true -> emergency;
                false -> none
            end
    end.

emergency(Sep, World, Aircraft, Runway) ->
    lists:any(
        fun(Id) ->
            Id =:= Aircraft orelse shares(Sep, Runway, id_runway(Sep, World, Id))
        end,
        maps:get(emergencies, World, [])
    ).

shares(_Sep, none, _Other) -> false;
shares(_Sep, _Runway, none) -> false;
shares(Sep, Runway, Other) ->
    atc_separation:runway_conflict(Sep, Runway, Other).

detected_opposite(World, Runway, Aircraft) ->
    Runway =/= none andalso
        lists:any(
            fun(Track) ->
                Other = maps:get(id, Track),
                OtherRunway = maps:get(runway, Track, none),
                Other =/= Aircraft andalso atc_taxi:reciprocal(Runway, OtherRunway)
            end,
            atc_tracks:list(maps:get(tracks, World))
        ).

conflicts(Sep, World, Command) ->
    Aircraft = aircraft_of(Command),
    Runway = runway_of(Sep, World, Command),
    Incursions = incursions(World, Runway, Aircraft, Command),
    Times = time_hits(World, Runway, Aircraft, Command),
    Arrivals = arrival_hits(World, Runway, Aircraft, Command),
    Affected = lists:usort(Incursions ++ Times ++ Arrivals),
    case Affected of
        [] -> none;
        _ -> #{affected => Affected, incursion => Incursions =/= []}
    end.

incursions(_World, none, _Aircraft, _Command) ->
    [];
incursions(World, Runway, Aircraft, Command) ->
    case needs_pavement(Command) of
        false ->
            [];
        true ->
            Graph = maps:get(taxi, World),
            Vehicles = [
                maps:get(id, Vehicle)
             || Vehicle <- maps:get(vehicles, World, []),
                maps:get(cleared, Vehicle, false) =/= true,
                atc_taxi:on_runway(
                    Graph, Runway, maps:get(x_ft, Vehicle, -1), maps:get(y_ft, Vehicle, -1)
                )
            ],
            Tracks = [
                maps:get(id, Track)
             || Track <- atc_tracks:list(maps:get(tracks, World)),
                maps:get(id, Track) =/= Aircraft,
                atc_taxi:on_runway(
                    Graph, Runway, maps:get(x_ft, Track, -1), maps:get(y_ft, Track, -1)
                )
            ],
            Vehicles ++ Tracks
    end.

time_hits(World, Runway, Aircraft, Command) ->
    case needs_pavement(Command) andalso Runway =/= none of
        false ->
            [];
        true ->
            case maps:get(Runway, maps:get(windows, World, #{}), none) of
                none ->
                    [];
                Window ->
                    case maps:get(id, Window) =:= Aircraft of
                        true ->
                            [];
                        false ->
                            Wake = follower_wake(World, Aircraft),
                            Use = use_time(World, Aircraft),
                            Free =
                                maps:get(free_at, Window) +
                                    atc_wake:gap_s(maps:get(wake, Window, small), Wake, kind(Command)),
                            case Use < Free of
                                true -> [maps:get(id, Window)];
                                false -> []
                            end
                    end
            end
    end.

arrival_hits(World, Runway, Aircraft, {takeoff, _}) when Runway =/= none ->
    [
        maps:get(id, Track)
     || Track <- atc_tracks:list(maps:get(tracks, World)),
        maps:get(id, Track) =/= Aircraft,
        maps:get(runway, Track, none) =:= Runway,
        maps:get(intent, Track, none) =:= arrival,
        maps:get(dist_ft, Track, 1000000) < 6000
    ];
arrival_hits(_World, _Runway, _Aircraft, _Command) ->
    [].

needs_pavement({line_up, _}) -> true;
needs_pavement({takeoff, _}) -> true;
needs_pavement({land, _}) -> true;
needs_pavement(_) -> false.

routine_surface({assign, _, _, _}) -> true;
routine_surface({hold_short, _}) -> true;
routine_surface({line_up, _}) -> true;
routine_surface({takeoff, _}) -> true;
routine_surface({land, _}) -> true;
routine_surface({vacate, _}) -> true;
routine_surface({taxi, _}) -> true;
routine_surface(_) -> false.

kind({land, _}) -> arrival;
kind(_) -> departure.

use_time(World, Aircraft) ->
    Now = maps:get(time_s, World, 0),
    case track(World, Aircraft) of
        #{dist_ft := Dist, vx_fps := Vx, vy_fps := Vy} when Dist > 0 ->
            Speed = math:sqrt(Vx * Vx + Vy * Vy),
            Now + (Dist / max(Speed, 1.0));
        _ ->
            Now
    end.

follower_wake(World, Aircraft) ->
    case track(World, Aircraft) of
        none -> small;
        Track -> maps:get(wake, Track, small)
    end.

track(_World, none) ->
    #{};
track(World, Aircraft) ->
    case atc_tracks:find(maps:get(tracks, World), Aircraft) of
        none -> #{};
        Track -> Track
    end.

track_runway(World, Aircraft) ->
    case track(World, Aircraft) of
        #{runway := Runway} -> Runway;
        _ -> none
    end.

id_runway(Sep, World, Id) ->
    case sep_runway(Sep, Id) of
        none -> track_runway(World, Id);
        Runway -> Runway
    end.

sep_runway(Sep, Aircraft) ->
    case maps:find(Aircraft, maps:get(aircraft, Sep, #{})) of
        {ok, #{runway := Runway}} -> Runway;
        _ -> none
    end.
