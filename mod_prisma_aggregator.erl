-module(mod_prisma_aggregator).

-behavior(gen_mod).

-include("prisma_aggregator.hrl").
-include("jlib.hrl").

-define(CONNECTOR, aggregator_connector).

-compile(export_all).

-export([start/2, stop/1, send_message/4]).

%% gen_mod implementation
start(Host, Opts) ->
    ?INFO_MSG("mod_prisma_aggregator starting!, options:~n~p", [Opts]),
    ets:new(?SPT, [named_table, public, set, {keypos, 1}]),
    agr:config_put(host, Host),
    agr:config_put(aggregator, "aggregator." ++ Host),
    ReadAndStoreConf = fun(Key, Default) ->
			       case proplists:get_value(Key, Opts, none) of
				   none -> agr:config_put(Key, Default);
				   Val -> agr:config_put(Key, Val)
			       end
		       end,
    ReadAndStoreConf(accessor, none),
    ReadAndStoreConf(coordinator, none),
    ReadAndStoreConf(overload_treshhold_runque, 500),
    ReadAndStoreConf(overload_treshhold_window, 20000),
    ReadAndStoreConf(polling_interval, 60000),
    ReadAndStoreConf(polling_timeout, 30000),
    ReadAndStoreConf(polling_retry_time_after_failure, never),
    ReadAndStoreConf(collect_stats, true),
    ReadAndStoreConf(ibrowse_max_pipeline_size, 1),
    ReadAndStoreConf(ibrowse_max_sessions, 1),
    ibrowse:start(),
    ibrowse:set_max_pipeline_size("localhost", "5984", 1),
    ibrowse:set_max_sessions("localhost", "5984", 10),
    setup_mnesia(),
    RandomGeneratorSpec = {?RAND,
    			   {?RAND, start_link, []},
    			   permanent,
    			   1000,
    			   worker,
    			   [?RAND]},
    {ok, _} = supervisor:start_child(ejabberd_sup, RandomGeneratorSpec),
    StatServSpec = {prisma_statistics_server,
    			   {prisma_statistics_server, start_link, []},
    			   permanent,
    			   1000,
    			   worker,
    			   [prisma_statistics_server, agr]},
    {ok, _} = supervisor:start_child(ejabberd_sup, StatServSpec),
    ConnectorSupSpec = {?SUP,
			{?SUP, start_link, [Host, Opts]},
			permanent,
			1000,
			supervisor,
			[?MODULE, aggregator_connector, ?SUP]},
    supervisor:start_child(ejabberd_sup, ConnectorSupSpec),
    F = fun() -> mnesia:all_keys(?PST) end,
    {atomic, Entries} = mnesia:transaction(F),
    log("read PST~n~p", [Entries]),
    spawn(fun() -> lists:map(fun(El) ->
				     aggregator_connector:start_worker(El),
				     case proplists:get_value(slow_startup, Opts) of
					 true -> timer:sleep(10);
					 _ -> ok
				     end
			     end, 
			     Entries)
	  end),
    MyHost = gen_mod:get_opt_host(Host, Opts, "aggregator.@HOST@"),
    ejabberd_router:register_route(MyHost, {apply, ?MODULE, route}),
    ok.

stop(_Host) ->
    supervisor:terminate_child(ejabberd_sup, ?SUP),
    supervisor:delete_child(ejabberd_sup, ?SUP),
    supervisor:terminate_child(ejabberd_sup, ?RAND),
    supervisor:delete_child(ejabberd_sup, ?RAND),
    supervisor:terminate_child(ejabberd_sup, prisma_statistics_server),
    supervisor:delete_child(ejabberd_sup, prisma_statistics_server),
    ibrowse:stop(),
    true = ets:delete(?SPT),
    inets:stop(httpc, ?INETS),
    inets:stop(),
    ?INFO_MSG("mod_prisma_aggregator stopped", []),
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
    case xml:get_subtag_cdata(Packet, "body") of
	"" -> ok;
	"stop " ++ Id -> ?CONNECTOR:stop(Id),
			 ok;
	"collapse " ++ Id -> ?CONNECTOR:collapse(Id),
			 ok;
	"stop_all_and_delete_mnesia" -> ?CONNECTOR:stop_all_and_delete_mnesia(),
					ok;
	"rebind_all" -> ?CONNECTOR:rebind_all(To),
			ok;
	"new_subscription " ++ Params ->
	    {match, [Url, Id, Feed]} = re:run(Params, "(?<Id>.+) (?<Url>.+) (?<Feed>.+)", [{capture,['Url', 'Id', 'Feed'], list}]),
	    ?CONNECTOR:new_subscription(From, To, #subscription{id = Id, url = Url, source_type = Feed}),
	    ok
    end,
    ok;

route(From, To, {xmlelement, "iq", _, _} = Packet) ->
    Body = strip_bom(xml:get_subtag_cdata(Packet, "query")),
    case xml:get_tag_attr_s("type", Packet) of
	F when (F =:= "subscribeBulk") or 
	       (F =:= "subscribe") or
	       (F =:= "unsubscribe") or
	       (F =:= "unsubscribeBulk") or
	       (F =:= "updateSubscription") or 
	       (F =:= "updateSubscriptionBulk") or
	       (F =:= "immigrate") or
	       (F =:= "emigrate")-> 
	    case json_eep:json_to_term(Body) of
		{error, _Reason} -> ?INFO_MSG("received unhandled xmpp message:~n~p~nparsing error:~n~p", [Body, _Reason]);
		Json when (F =:= "subscribeBulk") -> handle_json_bulk(Json, From, "subscribe");
		Json when (F =:= "unsubscribeBulk") -> handle_json_bulk(Json, From, "unsubscribe");
		Json when (F =:= "updateSubscriptionBulk")-> handle_json_bulk(Json, From, "updateSubscription");
		Json -> handle_json_msg(Json, From, F)
	    end;
	_ ->  ?INFO_MSG("Received unhandled iq~n~p -> ~p~n~p", [From, To, Packet])
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
		{"from", From},
		{"to", To}],
	       [{xmlelement, "body", [],
		 [{xmlcdata, BodyStr}]}]},
    ejabberd_router:route(jlib:string_to_jid(From), jlib:string_to_jid(To), XmlBody).


send_iq(From, To, TypeStr, BodyStr) ->
    XmlBody = {xmlelement, "iq",
	       [{"type", TypeStr},
		{"from", From},
		{"to", To}],
	       [{xmlelement, "query", [],
		 [{xmlcdata, BodyStr}]}]},
    ejabberd_router:route(jlib:string_to_jid(From), jlib:string_to_jid(To), XmlBody).

%% internal functions



setup_mnesia() ->
%    setup_mnesia(?SPT, fun() -> mnesia:create_table(?SPT, [{attributes, record_info(fields, process_mapping)}]) end),
    setup_mnesia(?PST, fun() ->mnesia:create_table(?PST, [{attributes, record_info(fields, subscription)},
							  {disc_copies, [node()]}]) end).

setup_mnesia(Name, Fun) ->
    try 
	Info = mnesia:table_info(Name, all),
	?INFO_MSG("Table ~p seems to exist:~n~p~n", [Name, Info])
    catch _:{aborted, {no_exists, _, _}} -> 
	    ?INFO_MSG("In setup_mnesia, catch", []),
	    Fun();
	  Type : Error -> ?INFO_MSG("In setup_mnesia, caught unknown msg:~n~p ->~n~p~n", [Type, Error])
    end.

log(Msg, Vars) ->
    ?INFO_MSG(Msg, Vars).

handle_json_bulk(Liste, _From, Type) when is_list(Liste) ->
    lists:map(fun(El) -> 
		      handle_json_msg(El, _From, Type) end,
	      Liste).

handle_json_msg([<<"subscription">>| T], From, "immigrate") ->
    Sub = list_to_tuple([subscription | T]),
    ?CONNECTOR:immigrate(Sub#subscription{host =  "aggregator." ++ agr:config_read(host)}, From);

handle_json_msg([To, Id], _From, "emigrate") ->
    ?CONNECTOR:emigrate(To, Id);

handle_json_msg(Id, _From, "unsubscribe") ->
    ?CONNECTOR:unsubscribe(Id);

handle_json_msg(Sub, _From, "updateSubscription") ->
    case parse_subscription(Sub) of
	wrong_class -> not_handled;
	invalid -> not_handled;
	Proplist ->
	    GV = fun(Key) -> proplists:get_value(Key, Proplist) end,
	    ?CONNECTOR:update_subscription(#subscription{id = binary_to_list(GV(subId)), 
						      url = GV(url), 
						      source_type = binary_to_list(GV(sourceType)), 
						      accessor = binary_to_list(GV(accessor)),
						      host = "aggregator." ++ agr:config_read(host)}),	    
	    ok
    end;

handle_json_msg(Sub, _From, "subscribe") ->
    case parse_subscription(Sub) of
	wrong_class -> not_handled;
	invalid -> not_handled;
	Proplist ->
	    GV = fun(Key) -> proplists:get_value(Key, Proplist) end,
	    ?CONNECTOR:new_subscription(#subscription{id = binary_to_list(GV(subId)), 
						      url = GV(url), 
						      source_type = binary_to_list(GV(sourceType)), 
						      accessor = binary_to_list(GV(accessor)),
						      polltime = agr:config_read(polling_interval),
						      host = "aggregator." ++ agr:config_read(host)}),	    
	    ok
    end.

parse_subscription(Proplist) -> %ist keine proplist sondern json-objekt -> {Proplist}
    case json_get_value(<<"class">>, Proplist) of
	undefined -> wrong_class;
	<<"de.prisma.datamodel.subscription.Subscription">> ->
	    SubscriptionId = json_get_value(<<"subscriptionID">>, Proplist),
	    Accessor = json_get_value(<<"accessor">>, Proplist),
	    SourceSpec = json_get_value(<<"sourceSpecification">>, Proplist),
	    SourceType = json_get_value(<<"sourceType">>,  SourceSpec),
	    AccessParameters = json_get_value([<<"accessProtocol">>, <<"accessParameters">>], SourceSpec),
	    F = fun(El) ->
			case json_get_value(<<"parameterType">>, El) of
			    <<"feeduri">> -> 
				binary_to_list(json_get_value(<<"parameterValue">>, El));
			    _ -> ""
			end
		end,
	    Url = lists:flatten(lists:map(F, AccessParameters)),
	    [{subId, SubscriptionId},
	     {accessor, Accessor},
	     {sourceType, SourceType},
	     {url, Url}];
	_ -> invalid	    
    end.
  
json_get_value([H|T], JsonObj) ->
    json_get_value(T,json_get_value(H, JsonObj));
json_get_value([],JsonObj) -> JsonObj;
json_get_value(Key, {JsonObj}) ->
    proplists:get_value(Key, JsonObj).

