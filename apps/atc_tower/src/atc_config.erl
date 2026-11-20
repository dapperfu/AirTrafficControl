%%%-------------------------------------------------------------------
%%% @doc Load one airport TOML file and refuse a file that cannot control traffic.
%%% Implements: SRS001
%%% Implements: SRS002
%%% @relation(SRS001, SRS002, scope=file)
%%%-------------------------------------------------------------------
-module(atc_config).

-export([load/1, from_binary/1]).

%% Implements: SRS001
%% @relation(SRS001, scope=line)
load(Path) ->
    case tomerl:read_file(Path) of
        {ok, Map} ->
            normalize(Map);
        {error, Reason} ->
            {error, {invalid_toml, Reason}}
    end.

%% Implements: SRS001
%% @relation(SRS001, scope=line)
from_binary(Bytes) ->
    case tomerl:parse(Bytes) of
        {ok, Map} ->
            normalize(Map);
        {error, Reason} ->
            {error, {invalid_toml, Reason}}
    end.

normalize(Map) ->
    try
        Airport =
            case tomerl:get(Map, [<<"airport">>]) of
                {ok, Section} when is_map(Section) ->
                    Section;
                _ ->
                    throw({invalid_toml, <<"airport">>})
            end,
        RunwayRows = optional_list(Map, <<"runway">>),
        NeighborRows = optional_list(Map, <<"neighbor">>),
        {ok, Runways} = runways(RunwayRows),
        {ok, Neighbors} = neighbors(NeighborRows),
        Config = #{
            icao => required_binary(Airport, <<"icao">>),
            latitude => required_number(Airport, <<"latitude">>),
            longitude => required_number(Airport, <<"longitude">>),
            communications_distance_nm => required_number(
                Airport, <<"communications_distance_nm">>
            ),
            computers => required_positive_integer(Airport, <<"computers">>),
            max_runways => required_positive_integer(Airport, <<"max_runways">>),
            max_aircraft => required_positive_integer(Airport, <<"max_aircraft">>),
            max_neighbors => required_non_negative_integer(Airport, <<"max_neighbors">>),
            wind => optional_binary(Airport, <<"wind">>),
            runways => Runways,
            neighbors => Neighbors
        },
        case atc_bounds:check(Config) of
            ok ->
                {ok, Config};
            {error, envelope} ->
                {error, envelope}
        end
    catch
        throw:Reason ->
            {error, Reason}
    end.

optional_list(Map, Key) ->
    case tomerl:get(Map, [Key]) of
        {ok, List} when is_list(List) ->
            List;
        {error, not_found} ->
            [];
        _ ->
            throw({invalid_toml, Key})
    end.

runways(Rows) ->
    {ok,
        lists:foldl(
            fun(Row, Acc) ->
                Id = required_binary(Row, <<"id">>),
                case maps:is_key(Id, Acc) of
                    true ->
                        throw({duplicate_runway, Id});
                    false ->
                        Acc#{
                            Id => #{
                                designation => designation(required_binary(Row, <<"designation">>)),
                                independent => required_bool(Row, <<"independent">>),
                                intersects => binary_list(Row, <<"intersects">>)
                            }
                        }
                end
            end,
            #{},
            Rows
        )}.

neighbors(Rows) ->
    {ok,
        [
            #{
                icao => required_binary(Row, <<"icao">>),
                latitude => required_number(Row, <<"latitude">>),
                longitude => required_number(Row, <<"longitude">>)
            }
         || Row <- Rows
        ]}.

designation(<<"arrival">>) ->
    arrival;
designation(<<"departure">>) ->
    departure;
designation(<<"both">>) ->
    both;
designation(<<"closed">>) ->
    closed;
designation(Other) ->
    throw({invalid_designation, Other}).

binary_list(Row, Key) ->
    case maps:get(Key, Row, []) of
        List when is_list(List) ->
            lists:map(
                fun(Item) when is_binary(Item) ->
                    Item;
                (Item) ->
                    throw({invalid_toml, Item})
                end,
                List
            );
        _ ->
            throw({invalid_toml, Key})
    end.

required_binary(Map, Key) ->
    case maps:get(Key, Map, missing) of
        Value when is_binary(Value), Value =/= <<>> ->
            Value;
        _ ->
            throw({invalid_toml, Key})
    end.

optional_binary(Map, Key) ->
    case maps:get(Key, Map, undefined) of
        undefined ->
            undefined;
        Value when is_binary(Value), Value =/= <<>> ->
            Value;
        _ ->
            throw({invalid_toml, Key})
    end.

required_number(Map, Key) ->
    case maps:get(Key, Map, missing) of
        Value when is_number(Value) ->
            Value;
        _ ->
            throw({invalid_toml, Key})
    end.

required_bool(Map, Key) ->
    case maps:get(Key, Map, missing) of
        Value when is_boolean(Value) ->
            Value;
        _ ->
            throw({invalid_toml, Key})
    end.

required_positive_integer(Map, Key) ->
    case maps:get(Key, Map, missing) of
        Value when is_integer(Value), Value > 0 ->
            Value;
        _ ->
            throw({invalid_toml, Key})
    end.

required_non_negative_integer(Map, Key) ->
    case maps:get(Key, Map, missing) of
        Value when is_integer(Value), Value >= 0 ->
            Value;
        _ ->
            throw({invalid_toml, Key})
    end.
