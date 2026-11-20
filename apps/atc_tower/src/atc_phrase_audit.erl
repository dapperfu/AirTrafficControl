%%%-------------------------------------------------------------------
%%% @doc Project phrase check. Order tables are not part of this grammar.
%%% Implements: SRS025
%%% @relation(SRS025, scope=file)
%%%-------------------------------------------------------------------
-module(atc_phrase_audit).

-export([routine/1]).

%% Implements: SRS025
%% @relation(SRS025, scope=line)
routine(Text) when is_binary(Text) ->
    Lower = string:lowercase(Text),
    case binary:match(Lower, <<"7110.65">>) of
        nomatch ->
            case lists:any(fun(Phrase) -> binary:match(Lower, Phrase) =/= nomatch end, phrases()) of
                true -> ok;
                false -> {error, not_routine}
            end;
        _ ->
            {error, pasted_order}
    end;
routine(_Text) ->
    {error, not_routine}.

phrases() ->
    [
        <<"hold short">>,
        <<"line up and wait">>,
        <<"cleared for takeoff">>,
        <<"cleared to land">>,
        <<"go around">>,
        <<"vacated">>,
        <<"contact">>,
        <<"traffic to follow">>,
        <<"stand by">>,
        <<"cleared via">>,
        <<"runway">>
    ].
