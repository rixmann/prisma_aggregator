-module(agr).

-include("prisma_aggregator.hrl").

-export([get_host/0, callbacktimer/2, callbacktimer/3,
	 format_date/0, get_timestamp/0,
	 get_polltime/0,
	 callbacktimer_callback_fn/2,
	 get_controller/0]).

get_host() ->
    [{host, Ret}] = ets:lookup(?CFG, host),
    Ret.

get_controller() ->
    [{controller, Ret}] = ets:lookup(?CFG, controller),
    Ret.

get_polltime() ->
    [{polltime, Pt}] = ets:lookup(?CFG, polltime),
    Pt.

callbacktimer(random, Callback, Offset) ->
    RandomCallbackTime = ?RAND:uniform([?POLLTIME]),
    callbacktimer(RandomCallbackTime + Offset, Callback).

callbacktimer(random, Callback) ->
    callbacktimer(random, Callback, 0);
callbacktimer(Time, Callback) ->
    Caller = self(),
    timer:apply_after(Time, agr, callbacktimer_callback_fn, [Caller, Callback]).

callbacktimer_callback_fn(Caller, Callback) ->
    gen_server:cast(Caller, Callback).

format_date() -> 
    {{Y, M, D}, {H, Min, S}} = erlang:localtime(), 
    F = fun(El) -> integer_to_list(El) end, 
    F(Y) ++ "-" ++ F(M) ++ "-" ++ F(D) ++ "-"++	F(H) ++ "-" ++ F(Min) ++ "-" ++ F(S).

get_timestamp() ->
        {Mega,Sec,Micro} = erlang:now(),
        (Mega*1000000+Sec)*1000000+Micro.
