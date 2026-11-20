%%%-------------------------------------------------------------------
%%% @doc Radar, vertical, and classic wake minima from JO 7110.65BB.
%%% Implements: SRS026
%%% The checked text is Change 3, effective July 9, 2026, paragraphs
%%% 5-5-4 and 4-5-1. Notice N JO 7110.806 is not applied.
%%% Conditional sensor modes are not selected: fusion, STARS multi-sensor,
%%% an ERAM 3 NM area, MSSR out to 60 NM, MEARTS, and 2.5 NM on final.
%%% Wake letters A through I are not assigned. A B757 follower uses the
%%% large-follower number where 5-5-4 names Large.
%%% Directly behind means aft of the leader and within 2,500 feet of its track.
%%% @relation(SRS026, scope=file)
%%%-------------------------------------------------------------------
-module(atc_faa).

-export([radar_nm/3, vertical_ft/4, wake_nm/5, pair/2]).

-define(EARTH_NM, 3440.065).
-define(FT_PER_NM, 6076.12).
-define(TRACK_FT, 2500.0).

%% Implements: SRS026
%% @relation(SRS026, scope=line)
radar_nm(Domain, DistNm, AltFt) ->
    case AltFt >= 60000.0 of
        true ->
            10.0;
        false ->
            case Domain of
                terminal when DistNm < 40.0 ->
                    3.0;
                _ ->
                    5.0
            end
    end.

%% Implements: SRS026
%% @relation(SRS026, scope=line)
vertical_ft(AltA, AltB, RvsmA, RvsmB) ->
    case erlang:max(AltA, AltB) > 41000.0 of
        true ->
            2000.0;
        false ->
            case (in_rvsm(AltA) andalso not RvsmA) orelse (in_rvsm(AltB) andalso not RvsmB) of
                true ->
                    2000.0;
                false ->
                    1000.0
            end
    end.

%% Implements: SRS026
%% Wake miles for a named pair. Zero means 5-5-4 states no increase.
%% @relation(SRS026, scope=line)
wake_nm(super, Follower, _Approach, Alt, Tas) ->
    case low_slow(Alt, Tas) of
        true ->
            super_low_slow(follower_group(Follower));
        false ->
            5.0
    end;
wake_nm(heavy, heavy, _Approach, _Alt, _Tas) ->
    4.0;
wake_nm(heavy, small, true, _Alt, _Tas) ->
    6.0;
wake_nm(heavy, small, false, _Alt, _Tas) ->
    5.0;
wake_nm(heavy, large, _Approach, _Alt, _Tas) ->
    5.0;
wake_nm(heavy, b757, _Approach, _Alt, _Tas) ->
    5.0;
wake_nm(b757, small, _Approach, _Alt, _Tas) ->
    4.0;
wake_nm(large, small, true, _Alt, _Tas) ->
    4.0;
wake_nm(_Leader, _Follower, _Approach, _Alt, _Tas) ->
    0.0.

%% Implements: SRS026
%% A pair is separated by vertical OR by lateral, after wake is applied.
%% One foot and one thousandth of a mile absorb projection rounding.
%% @relation(SRS026, scope=line)
pair(A, B) ->
    Lateral = distance_nm(maps:get(lat, A), maps:get(lon, A), maps:get(lat, B), maps:get(lon, B)),
    Vertical = abs(maps:get(alt, A) - maps:get(alt, B)),
    NeedV = vertical_ft(maps:get(alt, A), maps:get(alt, B), maps:get(rvsm, A), maps:get(rvsm, B)),
    Wake = erlang:max(wake_of(A, B), wake_of(B, A)),
    NeedL = erlang:max(erlang:max(radar_of(A), radar_of(B)), Wake),
    #{
        separated => Vertical + 0.5 >= NeedV orelse Lateral + 0.001 >= NeedL,
        lateral_nm => Lateral,
        vertical_ft => Vertical,
        need_lateral_nm => NeedL,
        need_vertical_ft => NeedV,
        wake_nm => Wake
    }.

radar_of(Aircraft) ->
    radar_nm(maps:get(domain, Aircraft), antenna_nm(Aircraft), maps:get(alt, Aircraft)).

antenna_nm(Aircraft) ->
    case maps:is_key(antenna_lat, Aircraft) of
        true ->
            distance_nm(
                maps:get(lat, Aircraft),
                maps:get(lon, Aircraft),
                maps:get(antenna_lat, Aircraft),
                maps:get(antenna_lon, Aircraft)
            );
        false ->
            maps:get(antenna_nm, Aircraft, 0.0)
    end.

wake_of(Leader, Follower) ->
    case behind(Leader, Follower) of
        false ->
            0.0;
        true ->
            wake_nm(
                maps:get(wake, Leader),
                maps:get(wake, Follower),
                maps:get(approach, Leader) =:= true,
                maps:get(alt, Leader),
                maps:get(tas, Leader)
            )
    end.

behind(Leader, Follower) ->
    {Along, Cross} = along_cross(Leader, Follower),
    Window = window_ft(maps:get(wake, Leader), maps:get(wake, Follower)),
    Below = maps:get(alt, Leader) - maps:get(alt, Follower),
    Along < 0.0 andalso abs(Cross) * ?FT_PER_NM =< ?TRACK_FT andalso Below >= 0.0 andalso
        Below < Window.

window_ft(b757, small) ->
    500.0;
window_ft(_, _) ->
    1000.0.

along_cross(Leader, Follower) ->
    North = (maps:get(lat, Follower) - maps:get(lat, Leader)) * 60.0,
    East =
        (maps:get(lon, Follower) - maps:get(lon, Leader)) * 60.0 *
            math:cos(rad(maps:get(lat, Leader))),
    Heading = rad(maps:get(heading, Leader)),
    Along = East * math:sin(Heading) + North * math:cos(Heading),
    Cross = East * math:cos(Heading) - North * math:sin(Heading),
    {Along, Cross}.

in_rvsm(Alt) ->
    Alt >= 29000.0 andalso Alt =< 41000.0.

low_slow(Alt, Tas) ->
    Alt =< 24000.0 andalso Tas < 250.0.

super_low_slow(heavy) ->
    6.0;
super_low_slow(large) ->
    7.0;
super_low_slow(small) ->
    8.0;
super_low_slow(_) ->
    5.0.

follower_group(heavy) ->
    heavy;
follower_group(small) ->
    small;
follower_group(super) ->
    super;
follower_group(_) ->
    large.

distance_nm(Lat1, Lon1, Lat2, Lon2) ->
    DLat = rad(Lat2 - Lat1),
    DLon = rad(Lon2 - Lon1),
    A =
        math:sin(DLat / 2.0) * math:sin(DLat / 2.0) +
            math:cos(rad(Lat1)) * math:cos(rad(Lat2)) * math:sin(DLon / 2.0) * math:sin(DLon / 2.0),
    ?EARTH_NM * 2.0 * math:atan2(math:sqrt(A), math:sqrt(1.0 - A)).

rad(Degrees) ->
    Degrees * math:pi() / 180.0.
