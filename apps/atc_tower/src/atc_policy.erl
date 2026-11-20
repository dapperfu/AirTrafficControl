%%%-------------------------------------------------------------------
%%% @doc Propose a routine command. Only the separation guard may commit it.
%%% Implements: SRS019
%%% @relation(SRS019, scope=file)
%%%-------------------------------------------------------------------
-module(atc_policy).

-export([propose/3, aircraft_of/1]).

%% Implements: SRS019
%% @relation(SRS019, scope=line)
propose(Sep, World, Request) ->
    case normalize(Sep, World, Request) of
        {cab, {ifr, Aircraft, Route}} ->
            case atc_cab:ifr(Aircraft, Route, maps:get(nav, World, [])) of
                {ok, Strip} ->
                    {cab, Strip};
                {error, Reason} ->
                    {defer, pack(World, Aircraft, Reason, Request, [])}
            end;
        {defer, Reason, Command} ->
            {defer, pack(World, atc_probe:aircraft_of(Command), Reason, Command, [])};
        {ok, Command} ->
            case atc_probe:assess(Sep, World, Command) of
                safe ->
                    case atc_separation:transition(Sep, Command) of
                        {ok, _, _} ->
                            {issue, Command};
                        {error, Reason, _} ->
                            {refuse, Command, Reason}
                    end;
                {defer, Kind} ->
                    {defer, pack(World, atc_probe:aircraft_of(Command), Kind, Command, affected(Sep, World, Command))};
                {conflict, #{affected := Hits} = Hit} ->
                    Package = (pack(World, atc_probe:aircraft_of(Command), conflict, Command, Hits))#{
                        incursion => maps:get(incursion, Hit, false)
                    },
                    {defer, Package}
            end
    end.

aircraft_of(Command) ->
    atc_probe:aircraft_of(Command).

normalize(_Sep, _World, {assign, _, _, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {hold_short, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {line_up, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {takeoff, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {land, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {go_around, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {vacate, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {handoff, _, _, _} = Command) -> {ok, Command};
normalize(_Sep, _World, {link, _, _} = Command) -> {ok, Command};
normalize(Sep, World, {taxi, Aircraft}) -> {ok, taxi_command(Sep, World, Aircraft)};
normalize(_Sep, _World, {ready, Aircraft}) -> {ok, {line_up, Aircraft}};
normalize(_Sep, _World, {ifr, Aircraft, Route}) -> {cab, {ifr, Aircraft, Route}};
normalize(_Sep, _World, {emergency, Aircraft}) -> {defer, emergency, {emergency, Aircraft}};
normalize(_Sep, _World, Request) -> {defer, unknown_command, Request}.

taxi_command(Sep, World, Aircraft) ->
    case phase(Sep, Aircraft) of
        out ->
            {assign, Aircraft, choose_runway(World, Aircraft), choose_intent(World, Aircraft)};
        _ ->
            {hold_short, Aircraft}
    end.

choose_runway(World, Aircraft) ->
    case atc_probe:runway_of(empty_sep(World), World, {taxi, Aircraft}) of
        none -> first_runway(World);
        Runway -> Runway
    end.

choose_intent(World, Aircraft) ->
    case atc_tracks:find(maps:get(tracks, World), Aircraft) of
        #{intent := arrival} -> arrival;
        #{intent := departure} -> departure;
        _ -> departure
    end.

first_runway(World) ->
    Rows = maps:to_list(maps:get(runways, World)),
    Open = lists:sort([
        Id
     || {Id, Meta} <- Rows,
        maps:get(designation, Meta) =:= both orelse maps:get(designation, Meta) =:= departure
    ]),
    case Open of
        [Id | _] -> Id;
        [] -> element(1, hd(lists:sort(Rows)))
    end.

phase(Sep, Aircraft) ->
    case maps:find(Aircraft, maps:get(aircraft, Sep, #{})) of
        {ok, #{phase := Phase}} -> Phase;
        error -> out
    end.

empty_sep(World) ->
    #{aircraft => #{}, runways => maps:get(runways, World, #{})}.

affected(Sep, World, Command) ->
    Runway = atc_probe:runway_of(Sep, World, Command),
    Aircraft = atc_probe:aircraft_of(Command),
    Ids = maps:keys(maps:get(aircraft, Sep, #{})) ++
        [maps:get(id, Track) || Track <- atc_tracks:list(maps:get(tracks, World))],
    lists:usort([
        Id
     || Id <- Ids,
        Id =/= Aircraft,
        Id =/= none,
        shares(Sep, Runway, atc_probe:runway_of(Sep, World, {hold_short, Id}))
    ]).

shares(_Sep, none, _Other) -> false;
shares(Sep, Runway, Other) when Other =/= none ->
    atc_separation:runway_conflict(Sep, Runway, Other);
shares(_Sep, _Runway, _Other) ->
    false.

pack(World, Aircraft, Reason, Command, Affected) ->
    atc_exception:package(
        Aircraft, Reason, Command, Affected, maps:get(last_clearance, World, none)
    ).
