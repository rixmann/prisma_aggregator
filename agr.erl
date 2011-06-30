-module(agr).

-include("prisma_aggregator.hrl").

-export([get_host/0]).

get_host() ->
    [{host, Ret}] = ets:lookup(?CFG, host),
    Ret.
