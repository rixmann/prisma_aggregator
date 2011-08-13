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
