-module(atc_radio_phrase).

-export([port/1, decode/1, classify/2, interpret/2, reply/2]).

port(Mhz) when is_integer(Mhz) ->
    port(Mhz * 1.0);
port(Mhz) when is_float(Mhz) ->
    20000 + round((Mhz - 118.0) / 0.025).

decode(Packet) when is_binary(Packet) ->
    Lines = [
        string:trim(Line, both, "\r\t ")
     || Line <- binary:split(Packet, <<"\n">>, [global]), Line =/= <<>>, Line =/= <<"\r">>
    ],
    case Lines of
        [<<"clock ", Rest/binary>>] ->
            {clock, seconds(Rest)};
        [<<"track ", Rest/binary>>] ->
            {track, Rest};
        [Line1, Line2 | _] ->
            case binary:split(Line1, <<" ">>, [global, trim_all]) of
                [<<"flight">>, Uuid, Chapter, Callsign] ->
                    {flight, Uuid, Chapter, Callsign, Line2};
                _ ->
                    {error, datagram}
            end;
        _ ->
            {error, datagram}
    end;
decode(_Packet) ->
    {error, datagram}.

classify(Callsign, English) when is_binary(Callsign), is_binary(English) ->
    Tokens = tokens(English),
    Lower = [string:lowercase(Token) || Token <- Tokens],
    case command(Callsign, Tokens, Lower) of
        none ->
            scripted;
        Command ->
            {command, Command}
    end.

%% A routine request is not a clearance until the guard accepts the proposal.
interpret(Callsign, English) when is_binary(Callsign), is_binary(English) ->
    case classify(Callsign, English) of
        {command, Command} ->
            {command, Command};
        scripted ->
            routine_or_script(Callsign, English)
    end.

reply(scripted, English) ->
    scripted_reply(English);
reply(standby, _Package) ->
    <<"stand by">>;
reply(flight_data, Phrase) when is_binary(Phrase) ->
    Phrase;
reply({command, {takeoff, _}}, ok) ->
    <<"cleared for takeoff">>;
reply({command, {land, _}}, ok) ->
    <<"cleared to land">>;
reply({command, {hold_short, _}}, ok) ->
    <<"hold short">>;
reply({command, {line_up, _}}, ok) ->
    <<"line up and wait">>;
reply({command, {go_around, _}}, ok) ->
    <<"go around">>;
reply({command, {vacate, _}}, ok) ->
    <<"runway vacated">>;
reply({command, {handoff, _, Neighbor, _}}, ok) ->
    <<"contact ", Neighbor/binary>>;
reply({command, {assign, _, Runway, Intent}}, ok) ->
    <<"runway ", Runway/binary, " for ", (atom_to_binary(Intent))/binary>>;
reply({command, {link, Neighbor, true}}, ok) ->
    <<"link ", Neighbor/binary, " up">>;
reply({command, {link, Neighbor, false}}, ok) ->
    <<"link ", Neighbor/binary, " down">>;
reply({command, _}, {error, Reason}) ->
    <<"unable ", (reason_text(Reason))/binary>>;
reply(_Kind, _Arg) ->
    <<"roger">>.

seconds(Text) ->
    case string:to_integer(string:trim(Text)) of
        {Value, Rest} when Rest =:= <<>>; Rest =:= [] ->
            Value;
        _ ->
            0
    end.

tokens(English) ->
    [Token || Token <- binary:split(English, <<" ">>, [global, trim_all]), Token =/= <<>>].

command(Callsign, Tokens, Lower) ->
    case link_command(Tokens, Lower) of
        none ->
            case match(Lower) of
                hold_short ->
                    {hold_short, Callsign};
                line_up ->
                    {line_up, Callsign};
                takeoff ->
                    {takeoff, Callsign};
                land ->
                    {land, Callsign};
                go_around ->
                    {go_around, Callsign};
                vacate ->
                    {vacate, Callsign};
                other ->
                    case after_word(Tokens, <<"contact">>) of
                        none ->
                            case runway_intent(Tokens, Lower) of
                                none ->
                                    none;
                                {Runway, Intent} ->
                                    {assign, Callsign, Runway, Intent}
                            end;
                        Neighbor ->
                            {handoff, Callsign, Neighbor, true}
                    end
            end;
        Command ->
            Command
    end.

link_command(Tokens, [<<"link">>, _, <<"up">>]) ->
    [_, Neighbor, _] = Tokens,
    {link, clean(Neighbor), true};
link_command(Tokens, [<<"link">>, _, <<"down">>]) ->
    [_, Neighbor, _] = Tokens,
    {link, clean(Neighbor), false};
link_command(_Tokens, _Lower) ->
    none.

match(Lower) ->
    Checks = [
        {hold_short, [<<"hold">>, <<"short">>]},
        {line_up, [<<"line">>, <<"up">>, <<"and">>, <<"wait">>]},
        {takeoff, [<<"cleared">>, <<"for">>, <<"takeoff">>]},
        {land, [<<"cleared">>, <<"to">>, <<"land">>]},
        {go_around, [<<"go">>, <<"around">>]},
        {vacate, [<<"vacated">>]},
        {vacate, [<<"vacate">>]}
    ],
    case lists:dropwhile(fun({_Name, Phrase}) -> not contains(Lower, Phrase) end, Checks) of
        [{Name, _} | _] ->
            Name;
        [] ->
            other
    end.

runway_intent(Tokens, Lower) ->
    case runway(Tokens) of
        none ->
            none;
        Runway ->
            case {contains(Lower, [<<"for">>, <<"departure">>]), contains(Lower, [<<"for">>, <<"arrival">>])} of
                {true, _} ->
                    {Runway, departure};
                {_, true} ->
                    {Runway, arrival};
                _ ->
                    none
            end
    end.

runway(Tokens) ->
    runway(Tokens, [string:lowercase(Token) || Token <- Tokens]).

runway([_Word, Next | _], [<<"runway">> | _]) ->
    clean(string:uppercase(Next));
runway([_ | Tokens], [_ | Lower]) ->
    runway(Tokens, Lower);
runway(_, _) ->
    none.

after_word(Tokens, Word) ->
    after_word(Tokens, [string:lowercase(Token) || Token <- Tokens], Word).

after_word([_Word, Next | _], [Word | _], Word) ->
    clean(Next);
after_word([_ | Tokens], [_ | Lower], Word) ->
    after_word(Tokens, Lower, Word);
after_word(_, _, _) ->
    none.

contains([Head | Tail], [Head | Rest] = Phrase) ->
    case lists:prefix(Rest, Tail) of
        true ->
            true;
        false ->
            contains(Tail, Phrase)
    end;
contains([_ | Tail], Phrase) ->
    contains(Tail, Phrase);
contains([], _Phrase) ->
    false.

clean(Token) ->
    << <<Byte>> || <<Byte>> <= Token, Byte =/= $,, Byte =/= $. >>.

scripted_reply(English) ->
    scripted_from([string:lowercase(Token) || Token <- tokens(English)]).

scripted_from(Lower) ->
    case {
        lists:member(<<"ifr">>, Lower) orelse lists:member(<<"clearance">>, Lower),
        lists:member(<<"taxi">>, Lower),
        lists:member(<<"climb">>, Lower),
        lists:member(<<"descend">>, Lower) orelse lists:member(<<"descent">>, Lower),
        lists:member(<<"approach">>, Lower)
    } of
        {true, _, _, _, _} ->
            <<"stand by">>;
        {_, true, _, _, _} ->
            <<"stand by">>;
        {_, _, true, _, _} ->
            <<"climb and maintain">>;
        {_, _, _, true, _} ->
            <<"descend and maintain">>;
        {_, _, _, _, true} ->
            <<"stand by">>;
        _ ->
            <<"roger">>
    end.

routine_or_script(Callsign, English) ->
    Tokens = tokens(English),
    Lower = [string:lowercase(Token) || Token <- Tokens],
    case lists:member(<<"mayday">>, Lower) orelse lists:member(<<"pan">>, Lower) of
        true ->
            {routine, {emergency, Callsign}};
        false ->
            case lists:member(<<"taxi">>, Lower) of
                true ->
                    {routine, {taxi, Callsign}};
                false ->
                    case ifr_destination(Tokens, Lower) of
                        none ->
                            scripted;
                        Dest ->
                            {routine, {ifr, Callsign, Dest}}
                    end
            end
    end.

ifr_destination(Tokens, Lower) ->
    case lists:member(<<"ifr">>, Lower) orelse lists:member(<<"clearance">>, Lower) of
        false ->
            none;
        true ->
            case after_word(Tokens, <<"to">>) of
                none -> <<"unknown">>;
                Dest -> Dest
            end
    end.

reason_text(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
reason_text(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
