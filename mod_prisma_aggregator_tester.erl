-module(mod_prisma_aggregator_tester).

-behavior(gen_mod).

-include("prisma_aggregator.hrl").
-include("jlib.hrl").
-define(TCFG, aggregator_tester_config).

-export([map_to_n_lines/3]).
-export([start/2, stop/1, route/3]).

%% gen_mod implementation
start(Host, Opts) ->
    MyHost = gen_mod:get_opt_host(Host, Opts, "aggregatortester.@HOST@"),
    ets:new(?TCFG, [named_table, protected, set, {keypos, 1}]),
    ets:insert(?TCFG,{host, Host}),
    Aggregator = proplists:get_value(aggregator, Opts),
    ets:insert(?TCFG, {aggregator, jlib:string_to_jid(Aggregator)}),
    ejabberd_router:register_route(MyHost, {apply, ?MODULE, route}),
   ok.

stop(_Host) ->
    ?INFO_MSG("mod_prisma_aggregator_tester stopped", []),
    ets:delete(?TCFG),
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

route(From, To, {xmlelement, "message", _, _} = Packet) ->
    case xml:get_tag_attr_s("type", Packet) of "chat" ->
	    case xml:get_subtag_cdata(Packet, "body") of
		"" -> ok;
		"stop_all_and_delete_mnesia" -> ok;
		"rebind_all" -> ok;
		"n_new_subs " ++ Params ->
		    {match, [Id, Accessor, Url, Feed, Count]} = re:run(Params, "(?<Id>.+) (?<Accessor>.+) (?<Url>.+) (?<Feed>.+) (?<Count>.+)", [{capture,['Id', 'Accessor', 'Url', 'Feed', 'Count'], list}]),
		    lists:map(fun(IdNum) -> 
				      send_message(To, 
						   jlib:string_to_jid("aggregator." ++ get_host()),
						   "chat",
						   create_json_subscription(Url, Accessor, Feed, Id ++ "-" ++ integer_to_list(IdNum)))
			      end,
			      lists:seq(1, list_to_integer(Count))),
		    ok;
		"subs_from_file " ++ Params ->
		    {match, [Count, Accessor, Batchname]} = re:run(Params, "(?<Count>.+) (?<Accessor>.+) (?<Batchname>.+)", [{capture, ['Count', 'Accessor', 'Batchname'], list}]),
		    send_subscriptions_file(list_to_integer(Count), Accessor, Batchname),
		    ok;
		"subs_from_file_bulk " ++ Params ->
		    {match, [Count, Accessor, Batchname]} = re:run(Params, "(?<Count>.+) (?<Accessor>.+) (?<Batchname>.+)", [{capture, ['Count', 'Accessor', 'Batchname'], list}]),
		    send_subscriptions_bulk_file(list_to_integer(Count), Accessor, Batchname),
		    ok;
		"unsubscribe_bulk " ++ Params ->
		    {match, [Name, Start, Stop]} = re:run(Params, "(?<Name>.+) (?<Start>.+) (?<Stop>.+)",
							  [{capture, ['Name', 'Start', 'Stop'], list}]),
		    send_unsubscribe_bulk(Name, Start, Stop),
		    ok;
		"update_subscription " ++ Params ->
		    {match, [Url, Accessor, Feed, Name]} = re:run(Params, "(?<Url>.+) (?<Accessor>.+) (?<Feed>.+) (?<Name>.+)", [{capture, ['Url', 'Accessor', 'Feed', 'Name'], list}]),
		    send_update_subscription(Url, Accessor, Feed, Name);
		"emigrate " ++ Params ->
		    {match, [Source, Destination, Id]} = re:run(Params, "(?<From>.+) (?<To>.+) (?<Id>.+)", [{capture, ['From', 'To', 'Id'], list}]),
		    send_emigrate(Source, Destination, Id);
		"test_hohes_1 " ++ Aggregator ->
		    GenSubs = fun(Start, Count) ->
				      [create_json_subscription("http://127.0.0.1:8000/index.yaws", 
								jlib:jid_to_string(get_sender()), 
								"ATOM", 
								"test_hohes_1-" ++ integer_to_list(I)) 
				       || I <- lists:seq(Start, Count)]
			      end,
		    SendSubs = fun(Start, Count) ->
				       send_iq(get_sender(), 
					       jlib:string_to_jid(Aggregator),
					       "subscribeBulk",
					       json_eep:term_to_json(GenSubs(Start,Count)))
			       end,
		    SendSubs(1,1000),
		    timer:sleep(120000),
		    SendSubs(1001,2000),
		    timer:sleep(120000),
		    SendSubs(2001,3000),
		    timer:sleep(120000),
		    SendSubs(3001,4000),
		    timer:sleep(120000),
		    SendSubs(4001,5000),
		    timer:sleep(120000),
		    SendSubs(5001,6000),
		    timer:sleep(120000),
		    SendSubs(6001,7000),
		    timer:sleep(120000),
		    SendSubs(7001,8000),
		    timer:sleep(120000),
		    SendSubs(8001,9000),
		    timer:sleep(120000),
		    SendSubs(9001,10000),
		    timer:sleep(120000),
		    SendSubs(10001,11000),
		    timer:sleep(120000),
		    SendSubs(11001,12000),
		    timer:sleep(120000),
		    SendSubs(12001,13000)
	    end;
	"PrismaMessage" ->
	    JSON = try
		       json_eep:json_to_term(xml:get_subtag_cdata(Packet, "body"))
		   catch
		       _:_ -> parsing_failure
		   end,
	    case JSON of
		{[{<<"class">>,<<"de.prisma.datamodel.message.ErrorMessage">>},
		  {<<"subscriptionID">>, SubId},
		  {<<"errorType">>, _Type},
		  {<<"errorDescription">>, _Desc}]} ->
		    try
			send_iq(get_sender(),
				From,
				"unsubscribe",
				json_eep:term_to_json(binary_to_list(SubId)))
		    catch
			_ : _ -> fail %wegen binary to list
		    end;
	
		{[{<<"class">>,<<"de.prisma.datamodel.message.Message">>},
		  {<<"id">>,null},
		  {<<"messageID">>,null},
		  {<<"messageParts">>,
		   [{[{<<"class">>,<<"de.prisma.datamodel.message.MessagePart">>},
		      {<<"content">>,
		       _Content},
		      {<<"contentType">>,<<"text">>},
		      {<<"encoding">>,null},
		      {<<"id">>,null}]}]},
		  {<<"priority">>,null},
		  {<<"publicationDate">>,null},
		  {<<"receivingDate">>, _ReceivingDate},
		  {<<"recipient">>,null},
		  {<<"sender">>,null},
		  {<<"subscriptionID">>,_SubId},
		  {<<"title">>,null}]} -> 
		    ok;
		_ -> 
		    ok
		
	    end
    end,
    ok;

route(_,_,Packet) -> 
    ?INFO_MSG("received unhandled packet:~n~p~n", [Packet]),
    ok.


%% HELPER FUNCTIONS

%strip_bom([239,187,191|C]) -> C;
%strip_bom(C) -> C.

send_presence(From, To, "") ->
    ejabberd_router:route(From, To, {xmlelement, "presence", [], []});

send_presence(From, To, TypeStr) ->
    ejabberd_router:route(From, To, {xmlelement, "presence", [{"type", TypeStr}], []}).

send_message(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "message",
           [{"type", TypeStr},
        {"from", jlib:jid_to_string(From)},
        {"to", jlib:jid_to_string(To)}],
           [{xmlelement, "body", [],
         [{xmlcdata, BodyStr}]}]},
    ejabberd_router:route(From, To, XmlBody).

send_iq(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "iq",
	       [{"type", TypeStr},
		{"from", jlib:jid_to_string(From)},
		{"to", jlib:jid_to_string(To)}],
	       [{xmlelement, "query", [],
		 [{xmlcdata, BodyStr}]}]},
    ejabberd_router:route(From, To, XmlBody).


get_host() ->
    [{host, Ret}] = ets:lookup(?TCFG, host),
    Ret.


create_json_subscription(Url, Accessor, SourceType, Id) ->
    {[{<<"class">>,<<"de.prisma.datamodel.subscription.Subscription">>},
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
      {<<"subscriptionID">>, list_to_binary(Id)}]}.

send_subscriptions_file(Count, Accessor, Batchname) ->
    {ok, Device} = file:open("/usr/lib/ejabberd/testfeeds.txt", read),
    F = fun(Line, N) ->
		URI = lists:sublist(Line, 1, length(Line) -1),
		Feed = case re:run(URI, ".*((?<Atom>atom)|(?<Rss>rss)).*", [{capture, ['Atom', 'Rss'], list}]) of
			   {match, ["atom", _]} -> "ATOM";
			   _ -> "RSS"
		       end,
		send_iq(get_sender(), 
			get_aggregator(),
			"subscribe",
			json_eep:term_to_json(create_json_subscription(URI, Accessor, Feed, Batchname ++ "-" ++ integer_to_list(N))))
	end,
    spawn(?MODULE, map_to_n_lines, [Device, Count, F]).

send_subscriptions_bulk_file(Count, Accessor, Batchname) ->
    {ok, Device} = file:open("/usr/lib/ejabberd/testfeeds.txt", read),
    F = fun(Line, N) ->
		URI = lists:sublist(Line, 1, length(Line) -1),
		Feed = case re:run(URI, ".*((?<Atom>atom)|(?<Rss>rss)).*", [{capture, ['Atom', 'Rss'], list}]) of
			   {match, ["atom", _]} -> "ATOM";
			   _ -> "RSS"
		       end,
		create_json_subscription(URI, Accessor, Feed, Batchname ++ "-" ++ integer_to_list(N))
	end,
    SubList = map_to_n_lines(Device, Count, F),
    send_iq(get_sender(), 
	    get_aggregator(),
	    "subscribeBulk",
	    json_eep:term_to_json(SubList)).

map_to_n_lines(Device, N, F) ->
    map_to_n_lines(Device, 1, N, F, []).

map_to_n_lines(Device, N, N, _F, Acc) ->
    file:close(Device),
    Acc;
map_to_n_lines(Device, Count, N, F, Acc) ->
    case io:get_line(Device, "") of
        eof  -> file:close(Device), 
		Acc;
        Line -> map_to_n_lines(Device, Count + 1, N, F, [F(Line, Count)| Acc])
    end.

get_aggregator() ->
    [{aggregator, Ret}] = ets:lookup(?TCFG, aggregator),
    Ret.

send_unsubscribe_bulk(Name, Start, Stop) ->
    SubList = lists:map(fun(El) ->
				Name ++ "-" ++ integer_to_list(El + list_to_integer(Start))
			end,
			lists:seq(0, list_to_integer(Stop) - list_to_integer(Start))),
    send_iq(get_sender(),
	    get_aggregator(),
	    "unsubscribeBulk",
	    json_eep:term_to_json(SubList)).

send_update_subscription(Url, Accessor, Feed, Name) ->
    send_iq(get_sender(), 
	    get_aggregator(),
	    "updateSubscription",
	    json_eep:term_to_json(create_json_subscription(Url, Accessor, Feed, Name))).

send_emigrate(From, To, Id) ->
    send_iq(get_sender(),
	    jlib:string_to_jid(From),
	    "emigrate",
	    json_eep:term_to_json([To, Id])).

get_sender() ->
    jlib:string_to_jid("aggregatortester." ++ get_host()).
    
