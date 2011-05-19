%%%-------------------------------------------------------------------
%%% File    : aggregator_connector.erl
%%% Author  : Ole Rixmann <rixmann.ole@googlemail.com>
%%% Description : 
%%%
%%% Created :  4 May 2011 by Ole Rixmann
%%%-------------------------------------------------------------------
-module(aggregator_connector).

-behaviour(gen_server).
-define(POLLTIME, 60000).


%% API
-export([start_link/1, stop/1, collapse/1, new_subscription/1, 
	 start_worker/1, stop_all_and_delete_mnesia/0, rebind_all/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("prisma_aggregator.hrl").

-record(state, 
	{subscription = #subscription{},
	 callbacks = ets:new(callbacks, []),
	 http_req_handler}).

%%====================================================================
%% API
%%====================================================================

new_subscription(Sub = #subscription{}) ->
    Id = get_id(Sub),
    F = fun() -> mnesia:read(?PST, Id) end,
    case mnesia:transaction(F) of
	{atomic, [Entry]} -> %reply("The Stream " ++ Id ++ " is already being polled.", Sub),
			     Entry;
	_ -> supervisor:start_child(?SUP, [Sub])
    end.

start_worker(Id) ->
    supervisor:start_child(?SUP, [Id]).

start_link(Subscription) ->
    gen_server:start_link(?MODULE, [Subscription], []).
    
stop(Id) ->
    case get_pid_from_id(Id) of
	not_found -> ok;
	Pid -> gen_server:cast(Pid, stop)
    end.

collapse(Id) ->
    Pid = get_pid_from_id(Id),
    ?INFO_MSG("Trying to collapse worker with pid: ~n~p", [Pid]),
    gen_server:cast(Pid, collapse).

stop_all_and_delete_mnesia() ->
    Ids = mnesia:dirty_all_keys(?PST),
    lists:map(fun(Id) -> stop(Id) end, Ids),
    {atomic, ok} = mnesia:delete_table(?PST),
    {atomic, ok} = mnesia:delete_table(?SPT).

rebind_all(To) ->
    Ids = mnesia:dirty_all_keys(?PST),
    lists:map(fun(Id) -> rebind(To, Id) end, Ids).

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([SubOrId]) ->
    Id = get_id_from_subscription_or_id(SubOrId),
    log("Worker ~p starting", [Id]),
    process_flag(trap_exit, true),
    F = fun() -> ok = mnesia:write(?SPT, #process_mapping{key = Id, pid = self()}, write),
		 case mnesia:read(?PST, Id) of
		     [] ->     if
				   Id =/= SubOrId -> ok = mnesia:write(?PST, SubOrId, write)
			       end,
			       SubOrId;
		     [Sub] -> Sub;
		     Err -> ?INFO_MSG("error reading prisma_subscription_table~n~p", [Err]),
			    error
		 end
	end, 
    {atomic, Subscription} = mnesia:transaction(F),
    callbacktimer(10, go_get_messages),
    Callbacks = ets:new(callbacks, []),
    {Host, Port} = get_host_and_port_from_url(Subscription#subscription.url),
    ibrowse:set_max_pipeline_size(Host, Port, 2),
    {ok, #state{subscription = Subscription,
		callbacks = Callbacks}}.

handle_call(_Request, _From, State) ->
    Reply = ignored,
    log("Ignored call~n~p", [{_Request, _From, State}]),
    {reply, Reply, State}.

handle_cast({rebind, To}, State = #state{subscription=Sub}) ->
    Nsub = Sub#subscription{accessor = To},
    ok = mnesia:dirty_write(?PST, Nsub),
    {noreply, State#state{subscription=Nsub}};

handle_cast(go_get_messages, State) ->
    Sub = State#state.subscription,
    case ibrowse:send_req(Sub#subscription.url, [], get, [], [{stream_to, self()}], ?POLLTIME - 2000) of
	{ibrowse_req_id, RequestId} ->
	    true = ets:insert(get_callbacks(State), {RequestId, {initial_get_stream, []}});
	{error, _Reason} ->
	    log("opening http connection failed on worker ~p for reason~n~p", [get_id(State), _Reason]),
	    callbacktimer(?POLLTIME, go_get_messages)
    end,
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(collapse, State) ->
    {stop, error, State};

handle_cast(_Msg, State) ->
    log("ignored cast~n~p", [{_Msg, State}]),
    {noreply, State}.

handle_info({ibrowse_async_headers, _ReqId, _, _}, State) ->
    {noreply, State};

handle_info({ibrowse_async_response, ReqId, Content}, State) ->
    case ets:lookup(get_callbacks(State), ReqId) of
	[{ReqId, {Hook, List}}] ->
    	    ets:insert(get_callbacks(State), {ReqId, {Hook, [Content | List]}});
	[] -> log("~p didn't find request id in callbacks for http-async-resp!!", [get_id(State)]); 
	Val -> log("ets-lookup really went wrong on worker ~p~n~p", [get_id(State), Val])

    end,
    {noreply, State};
   
	
handle_info({ibrowse_async_response_end, ReqId} , State) ->
    case ets:lookup(get_callbacks(State), ReqId) of
	[{_, {Hook, List}}] ->
	    Content = lists:flatten(lists:reverse(List)),
	    ets:delete(get_callbacks(State), ReqId),
	    handle_http_response(Hook, Content, State);
	[] -> 
	    log("~p didn't find req-id in callbacks for http-end", [get_id(State)]),
	    callbacktimer(?POLLTIME, go_get_messages),
	    {noreply, State};
	Val -> 
	    log("ets-lookup really went wrong on worker ~p~n~p", [get_id(State), Val]),
	    {noreply, State}
    end;

handle_info({'EXIT', _Reason, normal}, State) ->
    %log("on worker ~p, process stopped with Reason ~n~p", [get_id(State), Reason]),
    {noreply, State};

handle_info({Ref, {error, _}}, State) ->
    ets:delete(get_callbacks(State), Ref),
    {noreply, State};

handle_info(Info, State) ->
    log("ignored info: ~n~p", [{Info, State}]),
    {noreply, State}.


terminate(_Reason, State) ->
    F = fun() -> mnesia:delete(?SPT, get_id(State)) end, 
    mnesia:transaction(F),
    ?INFO_MSG("Worker stopping, id: ~p~n", [get_id(State)]),
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

get_pid_from_id(Id) ->
    F = fun() ->
		mnesia:read(?SPT, Id)
	end,
    try
	{atomic, [#process_mapping{pid=Pid}]} = mnesia:transaction(F),
	Pid
    catch
	_:_ -> not_found
    end.

get_attribute(El, Attr) ->
    get_attribute(El, Attr, Attr).
get_attribute(El, Attr, NewAttr) ->
    {NewAttr, xml:get_path_s(El, [{elem, atom_to_list(Attr)}, cdata])}.

parse_rss(Xml) ->
    try
	Channel = xml:get_path_s(Xml, [{elem, "channel"}]),
	{xmlelement, _, _, Rss09items} = Xml,
	{xmlelement, "channel", _, ChannelBody} = Channel,
	Items = [E || E = {xmlelement, "item", _, _} <- ChannelBody] ++
	    [E || E = {xmlelement, "item", _, _} <- Rss09items],
	Mapper = fun(Item) ->
			 [get_attribute(Item, title),
			  get_attribute(Item, pubDate),
			  get_attribute(Item, link),
			  get_attribute(Item, content)]
		 end,
	lists:map(Mapper, Items)
   catch
       _Err : _Reason -> {error, badxml}
   end.

parse_atom(Xml) ->
    try
	{xmlelement, _, _, Channel} = Xml,
	Items = [E || E = {xmlelement, "entry",_,_} <- Channel],
	Mapper = fun(Item) ->
			 [get_attribute(Item, title),
			  get_attribute(Item, link),
			  get_attribute(Item, id, key),
			  get_attribute(Item, summary),
			  get_attribute(Item, content),
			  get_attribute(Item, updated)]
		 end,
	Ret = lists:map(Mapper, Items),
%	log("atom parsed: ~n~p", [Ret]),
	Ret
    catch
	_Err :_Reason -> {error, badxml}
    end.


select_key(Streamentry) ->
    case proplists:get_value(key, Streamentry) of
	[] ->
	    case proplists:get_value(title, Streamentry) of
		[] -> case proplists:get_value(link, Streamentry) of
			  [] -> case proplists:get_value(content, Streamentry) of
				    [] -> no_key;
				    Val -> Val
				end;
			  Val -> Val
		      end;
		Val -> Val
	    end;
	Val -> Val
    end.
				    
get_id_from_subscription_or_id(#subscription{id = Id}) ->
    Id;
get_id_from_subscription_or_id(Id) ->
    Id.

handle_http_response(initial_get_stream, Body, State) -> 
    Sub = State#state.subscription,
    case xml_stream:parse_element(Body) of
	{error, {_, _Reason}} -> 
	    %log("Error while parsing xml in worker ~p: ~p", [get_id(State), Reason]),
	    %reply("Error, the stream " ++ get_id(State)  ++ " returns bad xml.", State),
	    callbacktimer(?POLLTIME, go_get_messages),
	    {noreply, State};
	Xml ->
	    try
		Content = case Sub#subscription.source_type of
			      "RSS" -> parse_rss(Xml);
			      "ATOM" -> parse_atom(Xml);
			      _ -> parse_rss(Xml)
			  end,
		NewContent = extract_new_messages(Content, Sub),
		NSub = if
			   length(NewContent) > 0 ->
			       Text = lists:flatten(lists:map(fun(Val) -> 
								      proplists:get_value(title, Val) ++ "\n"
							      end, 
							      NewContent)),
			       reply("Neue Nachrichten von " ++ get_id(State) ++ " ->\n" ++ Text, State),
			       EnrichedContent = lists:map(fun([H|T]) ->
								   [{subId, get_id(Sub)},
								    {feed, Sub#subscription.source_type},
								    {date, format_date()},
								    H | T]
							   end, NewContent),
			       ok = store_to_couch(EnrichedContent, State),
			       StoreSub = Sub#subscription{last_msg_key = merge_keys(Content, Sub#subscription.last_msg_key)},
			       ok = mnesia:dirty_write(StoreSub),
			       StoreSub;
			   true -> Sub
		       end,
		callbacktimer(?POLLTIME, go_get_messages),
		{noreply, State#state{subscription = NSub}}
	    catch
		_Arg : _Error -> %log("Worker ~p caught error while trying to interpret xml.~n~p : ~p", [get_id(Sub), Arg, Error]),
			     callbacktimer(?POLLTIME, go_get_messages),
			     {noreply, State}
	    end
    end;

handle_http_response({couch_doc_store_reply, _Doclist}, _Body, State) ->
    %log("Worker ~p stored to couchdb, resp-body: ~n~p", [get_id(State), _Body]),
    {noreply, State};

handle_http_response(_, {error, _Reason}, State) ->
    log("Worker ~p received an polling error: ~n~p", [get_id(State), _Reason]),
    callbacktimer(?POLLTIME, go_get_messages),
    {noreply,State}.

extract_new_messages(Content, #subscription{last_msg_key = KnownKeys}) ->
    F = fun(El) ->  fun(Key) -> 
			    Key =:= select_key(El)
		    end
	end,
    lists:takewhile(fun(El) -> 
			    not(lists:any(F(El), KnownKeys)) 
		    end, 
		    Content).

merge_keys(Items, OldKeys) ->
    merge_keys(Items, OldKeys, 3).
merge_keys(Items, OldKeys, N) ->
    lists:map(fun(Item) -> select_key(Item) end,
	      lists:sublist(lists:append(lists:sublist(Items, N), OldKeys),
			    N)).
		 

callbacktimer(Time, Callback) ->
    Caller = self(),
    F = fun() ->
		receive
		after Time ->
			gen_server:cast(Caller, Callback)
		end
	end,
    spawn(F).

get_id(#subscription{id = Id}) ->
    Id;
get_id(State) ->
    (State#state.subscription)#subscription.id.

get_callbacks(State) ->
    State#state.callbacks.

reply(Msg, #state{subscription = Sub}) ->
    reply(Msg, Sub);
reply(Msg, Sub) ->
    mod_prisma_aggregator:send_message(Sub#subscription.host,
				       Sub#subscription.accessor,
				       "chat",
				       Msg).
log(Msg, Vars) ->
    ?INFO_MSG(Msg, Vars).

rebind( To, Id) ->
    case get_pid_from_id(Id) of
	not_found ->
	    not_found;
	Pid -> gen_server:cast(Pid, {rebind, To})
    end.
    
store_to_couch(Doclist ,State) ->
    Pre = doclist_to_json(Doclist),
    Jstring = json_eep:term_to_json({[{<<"docs">>, Pre}]}), 
    {ibrowse_req_id, RequestId} = ibrowse:send_req("http://localhost:5984/prisma_docs/_bulk_docs", 
						   [{"Content-Type", "application/json"}], 
						   post, 
						   Jstring,
						   [{stream_to, self()}], 
						   2000),
    true = ets:insert(get_callbacks(State), {RequestId, {{couch_doc_store_reply, Doclist}, []}}),
    ok.

doclist_to_json(Doclist) ->
    lists:map(fun(Item) -> 
		      {lists:map(fun({K, V}) ->
					  Validv = case V of 
						       {} -> <<"">>;
						       _ -> list_to_binary(V)
						   end,
					  {list_to_binary(atom_to_list(K)), Validv} 
				  end,
				  Item)}
	      end, 
	      Doclist).

format_date() -> 
    {{Y, M, D}, {H, Min, S}} = erlang:localtime(), 
    F = fun(El) -> integer_to_list(El) end, 
    F(Y) ++ "-" ++ F(M) ++ "-" ++ F(D) ++ "-"++	F(H) ++ "-" ++ F(Min) ++ "-" ++ F(S).

get_host_and_port_from_url(Url) ->
    case re:run(Url, "http://(?<Server>[^/:]+)(?:.?(?<=:)(?<Port>[0-9]+).*|.*)", [{capture, ['Server', 'Port'], list}]) of
	{[], _} -> nomatch;
	{match, [Server, []]} -> {Server, 80};
	{match, [Server, Port]} -> {Server, list_to_integer(Port)};
	nomatch -> nomatch
    end.
