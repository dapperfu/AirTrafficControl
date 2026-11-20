-module(atc_radio_log).

-export([append/3]).

append(Directory, Chapter, Fields) ->
    Uuid = maps:get(flight, Fields),
    Name = chapter_name(Chapter),
    Path = filename:join([Directory, binary_to_list(Uuid), Name ++ ".jsonl"]),
    ok = filelib:ensure_dir(Path),
    file:write_file(Path, [encode(Fields), "\n"], [append]).

chapter_name(<<"departure">>) ->
    "departure";
chapter_name(<<"enroute">>) ->
    "enroute";
chapter_name(<<"arrival">>) ->
    "arrival";
chapter_name(_) ->
    "unknown".

encode(Fields) ->
    [
        "{\"sim_time\":",
        integer_to_binary(maps:get(sim_time, Fields)),
        ",\"airport\":",
        quote(maps:get(airport, Fields)),
        ",\"facility\":",
        quote(maps:get(facility, Fields)),
        ",\"frequency_mhz\":",
        quote(maps:get(frequency_mhz, Fields)),
        ",\"port\":",
        integer_to_binary(maps:get(port, Fields)),
        ",\"direction\":",
        quote(maps:get(direction, Fields)),
        ",\"flight\":",
        quote(maps:get(flight, Fields)),
        ",\"chapter\":",
        quote(maps:get(chapter, Fields)),
        ",\"callsign\":",
        quote(maps:get(callsign, Fields)),
        ",\"line1\":",
        quote(maps:get(line1, Fields)),
        ",\"line2\":",
        quote(maps:get(line2, Fields)),
        "}"
    ].

quote(Text) ->
    [$", escape(to_binary(Text)), $"].

to_binary(Text) when is_binary(Text) ->
    Text;
to_binary(Text) when is_list(Text) ->
    unicode:characters_to_binary(Text);
to_binary(Text) when is_atom(Text) ->
    atom_to_binary(Text).

escape(Text) ->
    <<
        <<(escape_byte(Byte))/binary>>
     || <<Byte>> <= Text
    >>.

escape_byte($\\) ->
    <<"\\\\">>;
escape_byte($") ->
    <<"\\\"">>;
escape_byte($\n) ->
    <<"\\n">>;
escape_byte($\r) ->
    <<"\\r">>;
escape_byte(Byte) ->
    <<Byte>>.
