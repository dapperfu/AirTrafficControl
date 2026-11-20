%%%-------------------------------------------------------------------
%%% Verifies: SRS001, SRS002, SRS005, SRS014
%%% @relation(SRS001, SRS002, SRS005, SRS014, scope=file)
%%%-------------------------------------------------------------------
-module(atc_config_SUITE).

-export([all/0, example_airport/1, invalid_toml_does_not_control/1, envelope/1, neighbors/1]).

all() ->
    [example_airport, invalid_toml_does_not_control, envelope, neighbors].

example_airport(_Config) ->
    {ok, Config} = atc_config:load(example_path()),
    <<"KEXAMPLE">> = maps:get(icao, Config),
    1 = maps:get(computers, Config),
    both = maps:get(designation, maps:get(<<"27">>, maps:get(runways, Config))),
    arrival = maps:get(designation, maps:get(<<"09">>, maps:get(runways, Config))),
    [Near] = atc_neighbors:selected(Config),
    <<"KNEAR">> = maps:get(icao, Near),
    true = atc_neighbors:distance_nm(Config, Near) < 30.

invalid_toml_does_not_control(_Config) ->
    {error, {invalid_toml, _}} = atc_config:from_binary(""),
    {error, {invalid_toml, _}} = atc_config:from_binary("this is not toml"),
    {error, {invalid_toml, <<"designation">>}} = atc_config:from_binary(runway_without_designation()),
    {error, {invalid_toml, _}} = atc_config:from_binary(
        "[airport]\nicao = \"K\"\nlatitude = 1\nlongitude = 1\n"
        "communications_distance_nm = 10\ncomputers = 0\n"
        "max_runways = 4\nmax_aircraft = 8\nmax_neighbors = 2\n"
    ),
    {error, {invalid_designation, <<"sideways">>}} = atc_config:from_binary(airport_with_runway("sideways")).

envelope(_Config) ->
    {error, envelope} = atc_config:from_binary(wide_airport()),
    {error, {invalid_toml, _}} = atc_config:load("/tmp/atc-missing-airport.toml").

neighbors(_Config) ->
    {ok, Config} = atc_config:load(example_path()),
    Far = #{icao => <<"KFAR">>, latitude => 42.0, longitude => -75.0},
    false = atc_neighbors:within(Config, Far).

example_path() ->
    filename:join(project_root(), "config/example-airport.toml").

project_root() ->
    filename:join([code:lib_dir(atc_tower), "..", "..", "..", ".."]).

runway_without_designation() ->
    [
        "[airport]\nicao = \"K\"\nlatitude = 1.0\nlongitude = 1.0\n",
        "communications_distance_nm = 10.0\ncomputers = 1\n",
        "max_runways = 4\nmax_aircraft = 8\nmax_neighbors = 2\n",
        "[[runway]]\nid = \"27\"\nindependent = true\nintersects = []\n"
    ].

airport_with_runway(Designation) ->
    [
        "[airport]\nicao = \"K\"\nlatitude = 1.0\nlongitude = 1.0\n",
        "communications_distance_nm = 10.0\ncomputers = 1\n",
        "max_runways = 4\nmax_aircraft = 8\nmax_neighbors = 2\n",
        "[[runway]]\nid = \"27\"\ndesignation = \"",
        Designation,
        "\"\nindependent = true\nintersects = []\n"
    ].

wide_airport() ->
    [
        "[airport]\nicao = \"K\"\nlatitude = 1.0\nlongitude = 1.0\n",
        "communications_distance_nm = 10.0\ncomputers = 1\n",
        "max_runways = 5\nmax_aircraft = 8\nmax_neighbors = 2\n"
    ].
