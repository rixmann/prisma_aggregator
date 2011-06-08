-module(mod_prisma_aggregator).

-behavior(gen_mod).

-include("prisma_aggregator.hrl").
-include("jlib.hrl").

-define(CONNECTOR, aggregator_connector).
-define(CFG, aggregator_config).

-compile(export_all).

-export([start/2, stop/1, send_message/4]).

%% gen_mod implementation
start(Host, Opts) ->
    ets:new(?CFG, [named_table, protected, set, {keypos, 1}]),
    ets:insert(?CFG,{host, Host}),
    ibrowse:start(),
    setup_mnesia(),
    
    RandomGeneratorSpec = {?RAND,
    			   {?RAND, start_link, []},
    			   permanent,
    			   1000,
    			   worker,
    			   [?RAND]},
    {ok, _} = supervisor:start_child(ejabberd_sup, RandomGeneratorSpec),
    ConnectorSupSpec = {?SUP,
			{?SUP, start_link, [Host, Opts]},
			permanent,
			1000,
			supervisor,
			[?MODULE, aggregator_connector, ?SUP]},
    supervisor:start_child(ejabberd_sup, ConnectorSupSpec),
    ?INFO_MSG("mod_prisma_aggregator starting!, module: ~p~n", [?MODULE]),
    F = fun() -> mnesia:all_keys(?PST) end,
    {atomic, Entries} = mnesia:transaction(F),
    lists:map(fun(El) ->
		      aggregator_connector:start_worker(El)
	      end, Entries),
    log("read PST~n~p", [Entries]),
    MyHost = gen_mod:get_opt_host(Host, Opts, "aggregator.@HOST@"),
    ejabberd_router:register_route(MyHost, {apply, ?MODULE, route}),
    
   ok.

stop(_Host) ->
    supervisor:terminate_child(ejabberd_sup, ?SUP),
    supervisor:delete_child(ejabberd_sup, ?SUP),
    supervisor:terminate_child(ejabberd_sup, ?RAND),
    supervisor:delete_child(ejabberd_sup, ?RAND),
    ibrowse:stop(),
    {atomic, ok} = mnesia:delete_table(?SPT),
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
	F when (F =:= "subscribeAll") or 
	       (F =:= "subscribe") or
	       (F =:= "unsubscribe") or
	       (F =:= "updateSubscription") -> 
	    case json_eep:json_to_term(Body) of
		{error, _Reason} -> ?INFO_MSG("received unhandled xmpp message:~n~p~nparsing error:~n~p", [Body, _Reason]);
		Json -> handle_json_msg(Json, From, F)
	    end;
	_ ->  ?INFO_MSG("Received unhandled iq~n~p -> ~p~n~p", [From, To, Packet])
    end;

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


%% internal functions



setup_mnesia() ->
    setup_mnesia(?SPT, fun() -> mnesia:create_table(?SPT, [{attributes, record_info(fields, process_mapping)}]) end),
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

handle_json_msg([H|T], _From, Type) ->
    lists:map(fun(El) -> handle_json_msg(El, _From, Type) end,
	      [H|T]);
handle_json_msg(Proplist, _From, Type) ->
    case json_get_value(<<"class">>, Proplist) of
	undefined -> log("received xmpp-json-message that has no class attribute~n~p", [Proplist]);
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
	    ?CONNECTOR:new_subscription(#subscription{id = binary_to_list(SubscriptionId), 
						      url = Url, 
						      source_type = binary_to_list(SourceType), 
						      accessor = jlib:string_to_jid(binary_to_list(Accessor)),
						      host = jlib:string_to_jid("aggregator." ++ get_host())}),
	    ok;
	_ -> not_handled	    
    end.

json_get_value([H|T], JsonObj) ->
    json_get_value(T,json_get_value(H, JsonObj));
json_get_value([],JsonObj) -> JsonObj;
json_get_value(Key, {JsonObj}) ->
    proplists:get_value(Key, JsonObj).

get_host() ->
    [{host, Ret}] = ets:lookup(?CFG, host),
    Ret.
