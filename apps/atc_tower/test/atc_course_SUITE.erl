%%%-------------------------------------------------------------------
%%% Verifies: SRS026
%%% @relation(SRS026, scope=file)
%%%-------------------------------------------------------------------
-module(atc_course_SUITE).

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([
    vertical_and_radar_minima/1,
    wake_geometry_and_minima/1,
    projection_amends_a_closing_pair/1,
    separated_pair_is_maintained/1,
    existing_loss_is_not_issued/1
]).

all() ->
    [
        vertical_and_radar_minima,
        wake_geometry_and_minima,
        projection_amends_a_closing_pair,
        separated_pair_is_maintained,
        existing_loss_is_not_issued
    ].

init_per_suite(Config) ->
    application:load(atc_tower),
    Config.

end_per_suite(_Config) ->
    ok.

vertical_and_radar_minima(_Config) ->
    1000.0 = atc_faa:vertical_ft(10000.0, 11000.0, false, false),
    1000.0 = atc_faa:vertical_ft(35000.0, 36000.0, true, true),
    2000.0 = atc_faa:vertical_ft(35000.0, 36000.0, true, false),
    1000.0 = atc_faa:vertical_ft(28000.0, 29000.0, false, true),
    2000.0 = atc_faa:vertical_ft(28000.0, 30000.0, true, false),
    1000.0 = atc_faa:vertical_ft(40000.0, 41000.0, true, true),
    2000.0 = atc_faa:vertical_ft(41000.0, 43000.0, true, true),
    3.0 = atc_faa:radar_nm(terminal, 39.9, 10000.0),
    5.0 = atc_faa:radar_nm(terminal, 40.0, 10000.0),
    5.0 = atc_faa:radar_nm(enroute, 10.0, 59999.0),
    10.0 = atc_faa:radar_nm(enroute, 10.0, 60000.0),
    10.0 = atc_faa:radar_nm(terminal, 10.0, 60000.0).

wake_geometry_and_minima(_Config) ->
    4.0 = atc_faa:wake_nm(heavy, heavy, false, 10000.0, 400.0),
    5.0 = atc_faa:wake_nm(heavy, small, false, 10000.0, 400.0),
    6.0 = atc_faa:wake_nm(heavy, small, true, 3000.0, 140.0),
    5.0 = atc_faa:wake_nm(heavy, b757, false, 10000.0, 400.0),
    4.0 = atc_faa:wake_nm(b757, small, false, 8000.0, 220.0),
    +0.0 = atc_faa:wake_nm(b757, large, false, 8000.0, 220.0),
    4.0 = atc_faa:wake_nm(large, small, true, 3000.0, 140.0),
    +0.0 = atc_faa:wake_nm(large, small, false, 3000.0, 140.0),
    8.0 = atc_faa:wake_nm(super, small, false, 24000.0, 249.0),
    7.0 = atc_faa:wake_nm(super, b757, false, 20000.0, 200.0),
    6.0 = atc_faa:wake_nm(super, heavy, false, 24000.0, 200.0),
    5.0 = atc_faa:wake_nm(super, small, false, 24000.0, 250.0),
    5.0 = atc_faa:wake_nm(super, small, false, 24001.0, 200.0),
    Trail = atc_faa:pair(ship(heavy, 40.0, -100.0, 10000.0, 0.0, 400.0, terminal, false),
                         ship(heavy, 39.9667, -100.0, 10000.0, 0.0, 400.0, terminal, false)),
    false = maps:get(separated, Trail),
    true = maps:get(need_lateral_nm, Trail) >= 4.0,
    true = maps:get(lateral_nm, Trail) < 4.0,
    Level = atc_faa:pair(ship(heavy, 40.0, -100.0, 10000.0, 0.0, 400.0, terminal, false),
                         ship(heavy, 39.9667, -100.0, 9000.0, 0.0, 400.0, terminal, false)),
    true = maps:get(separated, Level),
    Abeam = atc_faa:pair(ship(heavy, 40.0, -100.0, 10000.0, 0.0, 400.0, terminal, false),
                         ship(heavy, 40.0, -99.9, 10000.0, 0.0, 400.0, terminal, false)),
    true = maps:get(separated, Abeam),
    3.0 = maps:get(need_lateral_nm, Abeam),
    +0.0 = maps:get(wake_nm, Abeam),
    Super = atc_faa:pair(ship(super, 40.0, -100.0, 20000.0, 0.0, 200.0, enroute, false),
                         ship(small, 39.9001, -100.0, 20000.0, 0.0, 200.0, enroute, false)),
    false = maps:get(separated, Super),
    8.0 = maps:get(need_lateral_nm, Super),
    Final = atc_faa:pair(ship(heavy, 40.0, -100.0, 3000.0, 0.0, 140.0, terminal, true),
                         ship(small, 39.913, -100.0, 3000.0, 0.0, 140.0, terminal, false)),
    false = maps:get(separated, Final),
    6.0 = maps:get(need_lateral_nm, Final).

projection_amends_a_closing_pair(_Config) ->
    Sep = atc_separation:new(#{}),
    East = flight(<<"N1">>, -100.0, 35000.0, -90.0, large),
    West = flight(<<"N2">>, -99.45, 35000.0, -110.0, large),
    {{ok, Plan}, After} = atc_policy:propose_course(Sep, East, [West], horizon()),
    Sep = After,
    [] = atc_separation:issued(After),
    amend = maps:get(action, Plan),
    <<"N1">> = maps:get(subject, Plan),
    Course = maps:get(course, Plan),
    true = maps:get(use_alt, Course),
    36000.0 = maps:get(assigned_alt_ft, Course),
    Loss = maps:get(first_loss, Plan),
    <<"N2">> = maps:get(other, Loss),
    true = maps:get(at_s, Loss) > 0.0,
    5.0 = maps:get(need_lateral_nm, Loss),
    1000.0 = maps:get(need_vertical_ft, Loss).

separated_pair_is_maintained(_Config) ->
    Sep = atc_separation:new(#{}),
    East = flight(<<"N1">>, -100.0, 35000.0, -90.0, large),
    West = flight(<<"N2">>, -99.45, 36000.0, -110.0, large),
    {{ok, Plan}, After} = atc_policy:propose_course(Sep, East, [West], horizon()),
    Sep = After,
    [] = atc_separation:issued(After),
    maintain = maps:get(action, Plan),
    none = maps:get(first_loss, Plan).

existing_loss_is_not_issued(_Config) ->
    Sep = atc_separation:new(#{}),
    East = flight(<<"N1">>, -100.0, 35000.0, -90.0, large),
    West = flight(<<"N2">>, -99.98, 35000.0, -110.0, large),
    {{conflict, Loss}, After} = atc_policy:propose_course(Sep, East, [West], horizon()),
    Sep = After,
    [] = atc_separation:issued(After),
    +0.0 = maps:get(at_s, Loss),
    <<"N2">> = maps:get(other, Loss).

horizon() ->
    #{dt_s => 5.0, horizon_s => 120.0}.

flight(Id, Lon, Alt, DestLon, Wake) ->
    #{
        id => Id,
        wake => Wake,
        rvsm => true,
        domain => enroute,
        approach => false,
        antenna_lat => 40.0,
        antenna_lon => -100.0,
        state => #{
            lat_deg => 40.0,
            lon_deg => Lon,
            alt_ft => Alt,
            heading_deg => 90.0,
            tas_kt => 450.0,
            vertical_fpm => 0.0,
            distance_nm => 0.0,
            distance_remaining_nm => 800.0,
            phase => 1
        },
        route => #{
            origin_lat => 40.0,
            origin_lon => Lon,
            origin_alt_ft => Alt,
            dest_lat => 40.0,
            dest_lon => DestLon,
            dest_alt_ft => 680.0,
            cruise_alt_ft => Alt,
            climb_fpm => 2000.0,
            descent_fpm => 1500.0,
            climb_tas_kt => 250.0,
            cruise_tas_kt => 450.0,
            descent_tas_kt => 280.0
        },
        course => #{
            guidance => track,
            heading_deg => 90.0,
            use_alt => false,
            assigned_alt_ft => Alt,
            use_tas => false,
            assigned_tas_kt => 0.0
        }
    }.

ship(Wake, Lat, Lon, Alt, Heading, Tas, Domain, Approach) ->
    #{
        lat => Lat,
        lon => Lon,
        alt => Alt,
        heading => Heading,
        tas => Tas,
        wake => Wake,
        rvsm => true,
        domain => Domain,
        approach => Approach,
        antenna_lat => 40.0,
        antenna_lon => -100.0
    }.
