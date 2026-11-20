%%%-------------------------------------------------------------------
%%% @doc Classic wake categories and same-runway time gaps.
%%% Implements: SRS018
%%% @relation(SRS018, scope=file)
%%%-------------------------------------------------------------------
-module(atc_wake).

-export([category/1, gap_s/3, occupy_s/1]).

%% Implements: SRS018
%% @relation(SRS018, scope=line)
category(heavy) -> heavy;
category(<<"heavy">>) -> heavy;
category(<<"HEAVY">>) -> heavy;
category(b757) -> b757;
category(<<"b757">>) -> b757;
category(<<"B757">>) -> b757;
category(large) -> large;
category(<<"large">>) -> large;
category(<<"LARGE">>) -> large;
category(small) -> small;
category(<<"small">>) -> small;
category(<<"SMALL">>) -> small;
category(_) -> small.

%% Seconds a follower waits after the leader's runway-free time.
%% Implements: SRS018
%% @relation(SRS018, scope=line)
gap_s(heavy, small, _) -> 180;
gap_s(heavy, large, _) -> 120;
gap_s(heavy, b757, _) -> 120;
gap_s(heavy, heavy, _) -> 90;
gap_s(b757, small, _) -> 180;
gap_s(b757, large, _) -> 120;
gap_s(b757, b757, _) -> 90;
gap_s(b757, heavy, _) -> 90;
gap_s(large, small, _) -> 90;
gap_s(large, _, _) -> 60;
gap_s(small, _, _) -> 60;
gap_s(_, _, _) -> 60.

%% Implements: SRS018
%% @relation(SRS018, scope=line)
occupy_s(departure) -> 60;
occupy_s(arrival) -> 50;
occupy_s(_) -> 60.
