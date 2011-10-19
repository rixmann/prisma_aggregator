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

-module(stream_simulator).

-export([start/0]).

start() ->
    application:set_env(yaws, embedded, true),
    Args = proplist_from_cmd_line_args(init:get_plain_arguments()),
    Fn = fun(Key) -> 
		 list_to_integer(proplists:get_value(Key, Args))
	 end,
    Start_port = Fn(start_port),
    Instances = Fn(instances),
    {StartTime, _} = statistics(wall_clock),
    Yaws_dir = proplists:get_value(yaws_dir, Args),
    yaws:start_embedded(Yaws_dir, []),
    Sconf = [[{port, Port_num}, 
	      {docroot, Yaws_dir},
	      {listen, {0,0,0,0}},
	      {opaque, {start_time, StartTime}}] || Port_num <- lists:seq(Start_port, Start_port + Instances)],
    {ok, SCList, GC, _ChildSpecs} =
	yaws_api:embedded_start_conf(Yaws_dir, Sconf),
						%    io:format("sclist: ~p", [SCList]),
    yaws_api:setconf(GC, SCList).

proplist_from_cmd_line_args([K, V | T]) ->
    [{list_to_atom(K),V} | proplist_from_cmd_line_args(T)];
proplist_from_cmd_line_args([]) -> [].
