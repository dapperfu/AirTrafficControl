-module(atc_radio_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_Type, _Args) ->
    atc_radio_sup:start_link().

stop(_State) ->
    ok.
