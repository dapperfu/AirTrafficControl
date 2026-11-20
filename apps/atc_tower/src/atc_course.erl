%%%-------------------------------------------------------------------
%%% @doc Plan one airborne course from C physics projections.
%%% Implements: SRS026
%%% The plan amends only the subject. Altitude is tried first, then a
%%% heading, then a speed. The separation state is returned unchanged.
%%% @relation(SRS026, scope=file)
%%%-------------------------------------------------------------------
-module(atc_course).

-export([plan/4]).

%% Implements: SRS026
%% @relation(SRS026, scope=line)
plan(Sep, Subject, Others, Opts) when is_map(Subject), is_list(Others), is_map(Opts) ->
    Dt = maps:get(dt_s, Opts, 10.0),
    Horizon = maps:get(horizon_s, Opts, 300.0),
    case valid_time(Dt, Horizon) of
        false ->
            {{error, bad_time}, Sep};
        true ->
            Steps = steps(Dt, Horizon),
            Traffic = [
                Other
             || Other <- lists:sort(fun by_id/2, Others),
                maps:get(id, Other) =/= maps:get(id, Subject)
            ],
            case project_all(Traffic, Dt, Steps) of
                error ->
                    {{error, physics}, Sep};
                OtherSamples ->
                    decide(Sep, Subject, Traffic, OtherSamples, Dt, Steps)
            end
    end.

decide(Sep, Subject, Traffic, OtherSamples, Dt, Steps) ->
    case project_one(Subject, Dt, Steps) of
        error ->
            {{error, physics}, Sep};
        Samples ->
            case first_loss(Subject, Samples, Traffic, OtherSamples, Dt) of
                none ->
                    {{ok, plan_map(maintain, Subject, maps:get(course, Subject, #{}), none)}, Sep};
                Loss ->
                    case first_clear(Subject, Samples, Traffic, OtherSamples, Dt, Steps) of
                        none ->
                            {{conflict, Loss}, Sep};
                        Course ->
                            {{ok, plan_map(amend, Subject, Course, Loss)}, Sep}
                    end
            end
    end.

first_clear(Subject, Samples, Traffic, OtherSamples, Dt, Steps) ->
    Alt = maps:get(alt_ft, maps:get(state, Subject)),
    Cruise = maps:get(cruise_tas_kt, maps:get(route, Subject)),
    Seed = seed_heading(Samples, maps:get(state, Subject)),
    Base = maps:get(course, Subject, #{}),
    find_clear(
        Subject,
        courses(Base, Alt, Seed, Cruise),
        Traffic,
        OtherSamples,
        Dt,
        Steps
    ).

find_clear(_Subject, [], _Traffic, _OtherSamples, _Dt, _Steps) ->
    none;
find_clear(Subject, [Course | Rest], Traffic, OtherSamples, Dt, Steps) ->
    case clear(Subject, Course, Traffic, OtherSamples, Dt, Steps) of
        true ->
            Course;
        false ->
            find_clear(Subject, Rest, Traffic, OtherSamples, Dt, Steps)
    end.

clear(Subject, Course, Traffic, OtherSamples, Dt, Steps) ->
    case project_one(Subject#{course => Course}, Dt, Steps) of
        error ->
            false;
        Samples ->
            first_loss(Subject#{course => Course}, Samples, Traffic, OtherSamples, Dt) =:= none
    end.

courses(Base, Alt, Seed, Cruise) ->
    altitude_courses(Base, Alt) ++ heading_courses(Base, Seed) ++ speed_courses(Base, Cruise).

altitude_courses(Base, Alt) ->
    [
        Base#{guidance => track, use_alt => true, use_tas => false, assigned_alt_ft => Alt + Delta}
     || Delta <- [1000.0, -1000.0, 2000.0, -2000.0], Alt + Delta >= 500.0
    ].

heading_courses(Base, Seed) ->
    [
        Base#{
            guidance => heading,
            heading_deg => wrap(Seed + Offset),
            use_alt => false,
            use_tas => false
        }
     || Offset <- [10.0, -10.0, 20.0, -20.0, 30.0, -30.0, 45.0, -45.0]
    ].

speed_courses(Base, Cruise) ->
    [
        Base#{
            guidance => track,
            use_alt => false,
            use_tas => true,
            assigned_tas_kt => Cruise + Delta
        }
     || Delta <- [-20.0, -40.0, -60.0, 20.0],
        Cruise + Delta >= 100.0,
        Cruise + Delta =< Cruise + 0.1
    ].

first_loss(Subject, Samples, Traffic, OtherSamples, Dt) ->
    Opening = loss_against(Subject, point(maps:get(state, Subject)), Traffic, points0(Traffic), 0.0),
    loss_samples(Subject, Samples, Traffic, OtherSamples, Dt, 1, Opening).

loss_samples(_Subject, [], _Traffic, _OtherSamples, _Dt, _Index, Acc) ->
    Acc;
loss_samples(Subject, [Sample | Rest], Traffic, OtherSamples, Dt, Index, Acc) ->
    Hit = loss_against(Subject, point(Sample), Traffic, column(OtherSamples, Index), Index * Dt),
    loss_samples(Subject, Rest, Traffic, OtherSamples, Dt, Index + 1, earlier(Acc, Hit)).

loss_against(Subject, Point, Traffic, Points, T) ->
    lists:foldl(
        fun({Other, OtherPoint}, Acc) ->
            earlier(Acc, one_loss(Subject, Point, Other, OtherPoint, T))
        end,
        none,
        lists:zip(Traffic, Points)
    ).

one_loss(Subject, Point, Other, OtherPoint, T) ->
    Result = atc_faa:pair(view(Subject, Point), view(Other, OtherPoint)),
    case maps:get(separated, Result) of
        true ->
            none;
        false ->
            Result#{at_s => T * 1.0, other => maps:get(id, Other)}
    end.

view(Flight, {Lat, Lon, Alt, Heading, Tas}) ->
    Base = #{
        lat => float(Lat),
        lon => float(Lon),
        alt => float(Alt),
        heading => float(Heading),
        tas => float(Tas),
        wake => maps:get(wake, Flight, large),
        rvsm => maps:get(rvsm, Flight, true) =:= true,
        domain => maps:get(domain, Flight, enroute),
        approach => maps:get(approach, Flight, false) =:= true
    },
    case maps:is_key(antenna_lat, Flight) of
        true ->
            Base#{
                antenna_lat => maps:get(antenna_lat, Flight),
                antenna_lon => maps:get(antenna_lon, Flight)
            };
        false ->
            Base
    end.

point(Sample) ->
    {
        maps:get(lat_deg, Sample),
        maps:get(lon_deg, Sample),
        maps:get(alt_ft, Sample),
        maps:get(heading_deg, Sample, 0.0),
        maps:get(tas_kt, Sample, 0.0)
    }.

points0(Traffic) ->
    [point(maps:get(state, Flight)) || Flight <- Traffic].

column(OtherSamples, Index) ->
    [point(lists:nth(Index, Samples)) || Samples <- OtherSamples].

project_all(Flights, Dt, Steps) ->
    project_all(Flights, Dt, Steps, []).

project_all([], _Dt, _Steps, Acc) ->
    lists:reverse(Acc);
project_all([Flight | Rest], Dt, Steps, Acc) ->
    case project_one(Flight, Dt, Steps) of
        error ->
            error;
        Rows ->
            project_all(Rest, Dt, Steps, [Rows | Acc])
    end.

project_one(Flight, Dt, Steps) ->
    try
        atc_physics:project(
            maps:get(state, Flight),
            maps:get(route, Flight),
            maps:get(course, Flight, #{}),
            Dt,
            Steps
        )
    of
        {ok, Rows} when is_list(Rows), length(Rows) =:= Steps ->
            Rows;
        _ ->
            error
    catch
        error:badarg ->
            error
    end.

plan_map(Action, Subject, Course, Loss) ->
    #{
        action => Action,
        subject => maps:get(id, Subject),
        course => Course,
        first_loss => Loss
    }.

seed_heading([First | _], _State) ->
    maps:get(heading_deg, First);
seed_heading([], State) ->
    maps:get(heading_deg, State, 0.0).

earlier(none, Hit) ->
    Hit;
earlier(Hit, none) ->
    Hit;
earlier(#{at_s := Left} = Keep, #{at_s := Right}) when Left =< Right ->
    Keep;
earlier(_Keep, Hit) ->
    Hit.

by_id(Left, Right) ->
    maps:get(id, Left) =< maps:get(id, Right).

valid_time(Dt, Horizon)
    when is_number(Dt), is_number(Horizon), Dt > 0, Horizon > 0, Dt =< 120, Horizon =< 1800 ->
    true;
valid_time(_, _) ->
    false.

steps(Dt, Horizon) ->
    max(1, min(400, round(Horizon / Dt))).

wrap(Degrees) ->
    Wrapped = Degrees - 360.0 * math:floor(Degrees / 360.0),
    case Wrapped < 0.0 of
        true ->
            Wrapped + 360.0;
        false ->
            Wrapped
    end.
