%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                            %%
%% Copyright 2011 Ole Rixmann.                                                %%
%%                                                                            %%
%% This file is part of PRISMA-Aggregator.                                    %%
%%                                                                            %%
%% PRISMA-Aggregator is free software: you can redistribute it and/or         %%
%% modify it under the terms of the GNU Affero General Public License         %%
%% as published by the Free Software Foundation, either version 3 of          %%
%% the License, or (at your option) any later version.                        %%
%%                                                                            %%
%% PRISMA-Aggregator is distributed in the hope that it will be useful,       %%
%% but WITHOUT ANY WARRANTY; without even the implied warranty of             %%
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.                       %%
%% See the GNU Affero General Public License for more details.                %%
%%                                                                            %%
%% You should have received a copy of the GNU Affero General Public License   %%
%% along with PRISMA-Aggregator.  If not, see <http://www.gnu.org/licenses/>. %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-module(agr).

-include("prisma_aggregator.hrl").

-export([get_host/0, callbacktimer/2, callbacktimer/3,
	 format_date/0, get_timestamp/0,
	 get_polltime/0,
	 callbacktimer_callback_fn/2,
	 get_coordinator/0,
	 config_put/2,
	 config_read/1]).

get_host() ->
    [{host, Ret}] = ets:lookup(?CFG, host),
    Ret.

get_coordinator() ->
    [{coordinator, Ret}] = ets:lookup(?CFG, coordinator),
    Ret.

get_polltime() ->
    [{polltime, Pt}] = ets:lookup(?CFG, polltime),
    Pt.

callbacktimer(random, Callback, Offset) ->
    RandomCallbackTime = ?RAND:uniform([config_read(polling_interval)]),
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

config_put(K, V) ->
    mochiglobal:put(K,V).

config_read(K) ->
    mochiglobal:get(K, none).
