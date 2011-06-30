-module(agr).

-include("prisma_aggregator.hrl").

-export([get_host/0, callbacktimer/2, callbacktimer/3,
	 format_date/0]).

get_host() ->
    [{host, Ret}] = ets:lookup(?CFG, host),
    Ret.

callbacktimer(random, Callback, Offset) ->
    RandomCallbackTime = ?RAND:uniform([?POLLTIME]),
    callbacktimer(RandomCallbackTime + Offset, Callback).

callbacktimer(random, Callback) ->
    callbacktimer(random, Callback, 0);
callbacktimer(Time, Callback) ->
    Caller = self(),
    F = fun() ->
		receive
		after Time ->
			gen_server:cast(Caller, Callback)
		end
	end,
    spawn(F).

format_date() -> 
    {{Y, M, D}, {H, Min, S}} = erlang:localtime(), 
    F = fun(El) -> integer_to_list(El) end, 
    F(Y) ++ "-" ++ F(M) ++ "-" ++ F(D) ++ "-"++	F(H) ++ "-" ++ F(Min) ++ "-" ++ F(S).
