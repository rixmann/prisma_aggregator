-module(mod_prisma_aggregator_tester).

-behavior(gen_mod).

-include("prisma_aggregator.hrl").
-include("jlib.hrl").
-define(AGGREGATOR, "aggregator").
-define(CFG, aggregator_tester_config).

-export([map_to_n_lines/3]).
-export([start/2, stop/1, route/3]).

%% gen_mod implementation
start(Host, Opts) ->
    MyHost = gen_mod:get_opt_host(Host, Opts, "aggregatortester.@HOST@"),
    ets:new(?CFG, [named_table, protected, set, {keypos, 1}]),
    ets:insert(?CFG,{host, Host}),
    ejabberd_router:register_route(MyHost, {apply, ?MODULE, route}),
   ok.

stop(_Host) ->
    ?INFO_MSG("mod_prisma_aggregator_tester stopped", []),
    ets:delete(?CFG),
    ok.

%% interfacing fuctions

route(From, To, {xmlelement, "presence", _, _} = Packet) ->
    case xml:get_tag_attr_s("type", Packet) of
        "subscribe" ->
            send_presence(To, From, "subscribe");
        "subscribed" ->
            send_presence(To, From, "subscribed"),
            send_presence(To, From, "");
        "unsubscribe" ->
            send_presence(To, From, "unsubscribed"),
            send_presence(To, From, "unsubscribe");
        "unsubscribed" ->
            send_presence(To, From, "unsubscribed");
        "" ->
            send_presence(To, From, "");
        "unavailable" ->
            ok;
        "probe" ->
            send_presence(To, From, "");
        _Other ->
            ?INFO_MSG("Other kind of presence~n~p", [Packet])
    end,
    ok;

route(_From, To, {xmlelement, "message", _, _} = Packet) ->
    case xml:get_subtag_cdata(Packet, "body") of
	"" -> ok;
	"stop_all_and_delete_mnesia" -> ok;
	"rebind_all" -> ok;
	"n_new_subs " ++ Params ->
	    {match, [Id, Accessor, Url, Feed, Count]} = re:run(Params, "(?<Id>.+) (?<Accessor>.+) (?<Url>.+) (?<Feed>.+) (?<Count>.+)", [{capture,['Id', 'Accessor', 'Url', 'Feed', 'Count'], list}]),
	    lists:map(fun(IdNum) -> 
			      send_message(To, 
					   jlib:string_to_jid("aggregator.kiiiiste"),
					   "chat",
					   create_json_subscription(Url, Accessor, Feed, Id ++ "-" ++ integer_to_list(IdNum)))
		      end,
		      lists:seq(1, list_to_integer(Count))),
	    ok;
	"subs_from_file " ++ Params ->
	    {match, [Count, Accessor, Batchname]} = re:run(Params, "(?<Count>.+) (?<Accessor>.+) (?<Batchname>.+)", [{capture, ['Count', 'Accessor', 'Batchname'], list}]),
	    send_subscriptions(list_to_integer(Count), Accessor, Batchname),
	    ok
    end,
    ok;

route(_,_,Packet) -> 
    ?INFO_MSG("received unhandled packet:~n~p~n", [Packet]),
    ok.


%% HELPER FUNCTIONS

strip_bom([239,187,191|C]) -> C;
strip_bom(C) -> C.

send_presence(From, To, "") ->
    ejabberd_router:route(From, To, {xmlelement, "presence", [], []});

send_presence(From, To, TypeStr) ->
    ejabberd_router:route(From, To, {xmlelement, "presence", [{"type", TypeStr}], []}).

echo(From, To, Body) ->
    send_message(From, To, "chat", Body).

send_message(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "message",
           [{"type", TypeStr},
        {"from", jlib:jid_to_string(From)},
        {"to", jlib:jid_to_string(To)}],
           [{xmlelement, "body", [],
         [{xmlcdata, BodyStr}]}]},
    ejabberd_router:route(From, To, XmlBody).

get_host() ->
    [{host, Ret}] = ets:lookup(?CFG, host),
    Ret.

create_json_subscription(Url, Accessor, SourceType, Id) ->
    json_eep:term_to_json({[{<<"class">>,<<"de.prisma.datamodel.subscription.Subscription">>},
			    {<<"filterSpecification">>,null},
			    {<<"id">>,null},
			    {<<"accessor">>, list_to_binary(Accessor)},
			    {<<"sourceSpecification">>,
			     {[{<<"accessProtocol">>,
				{[{<<"accessParameters">>,
				   [{[{<<"class">>,
				       <<"de.prisma.datamodel.subscription.source.AccessParameter">>},
				      {<<"id">>,null},
				      {<<"parameterType">>,<<"feeduri">>},
				      {<<"parameterValue">>,list_to_binary(Url)}]}]},
				  {<<"authenticationData">>,null},
				  {<<"class">>,
				   <<"de.prisma.datamodel.subscription.source.AccessProtocol">>},
				  {<<"id">>,null},
				  {<<"protocolType">>,null}]}},
			       {<<"class">>,
				<<"de.prisma.datamodel.subscription.source.SourceSpecification">>},
			       {<<"id">>,null},
			       {<<"sourceType">>, list_to_binary(SourceType)}]}},
			    {<<"subscriptionID">>, list_to_binary(Id)}]}).

send_subscriptions(Count, Accessor, Batchname) ->
    {ok, Device} = file:open("/usr/lib/ejabberd/testfeeds.txt", read),
    F = fun(Line, N) ->
		URI = lists:sublist(Line, 1, length(Line) -2),
		Feed = case re:run(URI, ".*((?<Atom>atom)|(?<Rss>rss)).*", [{capture, ['Atom', 'Rss'], list}]) of
			   {match, ["atom", _]} -> "ATOM";
			   _ -> "RSS"
		       end,
		send_message(get_sender(), 
			     jlib:string_to_jid("aggregator.kiiiiste"),
			     "chat",
			     create_json_subscription(URI, Accessor, Feed, Batchname ++ "-" ++ integer_to_list(N)))
	end,
    spawn(?MODULE, map_to_n_lines, [Device, Count, F]).

map_to_n_lines(Device, 0, _F) ->
    Device;
map_to_n_lines(Device, N, F) ->
    case io:get_line(Device, "") of
        eof  -> file:close(Device), 
		file_ended;
        Line -> F(Line, N),
		map_to_n_lines(Device, N - 1, F)
    end.

get_sender() ->
    jlib:string_to_jid("aggregatortester." ++ get_host()).
