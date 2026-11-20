%%%-------------------------------------------------------------------
%%% @doc Cab memory: frequencies, strips, weather gate, vehicles, and release.
%%% The controller chooses the runway configuration. Weather only gates issuance.
%%% Implements: SRS023
%%% @relation(SRS023, scope=file)
%%%-------------------------------------------------------------------
-module(atc_cab).

-export([
    frequencies/0,
    frequency_rows/0,
    weather_open/0,
    weather_gate/1,
    weather_view/1,
    ifr/3,
    ifr_phrase/1,
    handoff_command/2,
    release_command/2,
    check_readback/3
]).

%% Implements: SRS023
%% @relation(SRS023, scope=line)
frequencies() ->
    #{
        clearance_delivery => #{mhz => 121.7, name => <<"clearance delivery">>},
        ground => #{mhz => 121.9, name => <<"ground">>},
        local => #{mhz => 118.7, name => <<"local">>},
        flight_data => #{mhz => 126.6, name => <<"flight data">>}
    }.

frequency_rows() ->
    maps:fold(
        fun(Position, #{mhz := Mhz, name := Name}, Acc) ->
            [
                #{
                    <<"position">> => atom_to_binary(Position),
                    <<"mhz">> => Mhz,
                    <<"name">> => Name
                }
                | Acc
            ]
        end,
        [],
        frequencies()
    ).

%% Implements: SRS023
%% @relation(SRS023, scope=line)
weather_open() ->
    #{
        routine => true,
        ceiling_ft => 10000,
        visibility_sm => 10,
        wind => <<"270 at 10">>,
        altimeter => <<"2992">>,
        atis => <<"A">>,
        shear => false,
        braking => <<"good">>
    }.

%% Implements: SRS023
%% @relation(SRS023, scope=line)
weather_gate(Weather) ->
    maps:get(routine, Weather, true) =:= true andalso
        maps:get(shear, Weather, false) =:= false andalso
        maps:get(visibility_sm, Weather, 10) >= 3 andalso
        maps:get(ceiling_ft, Weather, 10000) >= 1000.

weather_view(Weather) ->
    #{
        <<"routine">> => weather_gate(Weather),
        <<"ceiling_ft">> => maps:get(ceiling_ft, Weather, 0),
        <<"visibility_sm">> => maps:get(visibility_sm, Weather, 0),
        <<"atis">> => maps:get(atis, Weather, <<"A">>),
        <<"wind">> => maps:get(wind, Weather, <<>>)
    }.

%% Implements: SRS023
%% @relation(SRS023, scope=line)
ifr(Aircraft, Route, Nav) when is_binary(Route), is_list(Nav) ->
    case lists:member(Route, Nav) of
        true ->
            {ok, #{
                aircraft => Aircraft,
                route => Route,
                plan => Route,
                atis => <<"A">>,
                readback => false
            }};
        false ->
            {error, unknown_route}
    end.

ifr_phrase(#{route := Route}) ->
    <<"cleared via ", Route/binary>>.

%% Implements: SRS023
%% @relation(SRS023, scope=line)
handoff_command(Aircraft, Neighbor) ->
    {handoff, Aircraft, Neighbor, true}.

%% Implements: SRS023
%% @relation(SRS023, scope=line)
release_command(Aircraft, Runway) ->
    {assign, Aircraft, Runway, arrival}.

check_readback(Strip, Clearance, Readback) ->
    Strip#{readback => atc_pattern:readback_ok(Clearance, Readback)}.
