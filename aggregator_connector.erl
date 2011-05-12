%%%-------------------------------------------------------------------
%%% File    : aggregator_connector.erl
%%% Author  : Ole Rixmann <rixmann.ole@googlemail.com>
%%% Description : 
%%%
%%% Created :  4 May 2011 by Ole Rixmann
%%%-------------------------------------------------------------------
-module(aggregator_connector).

-behaviour(gen_server).



%% API
-export([start_link/1, stop/1, collapse/1, new_subscription/3, 
	 start_worker/1, stop_all_and_delete_mnesia/0, rebind_all/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("prisma_aggregator.hrl").

-record(state, 
	{subscription = #subscription{},
	 callbacks = ets:new(callbacks, [])}).

%%====================================================================
%% API
%%====================================================================

new_subscription(From, To, Sub = #subscription{}) ->
    NewSub = Sub#subscription{sender=From, receiver=To},
    Id = get_id(NewSub),
    F = fun() -> mnesia:read(?PST, Id) end,
    case mnesia:transaction(F) of
	{atomic, [Entry]} -> reply("The Stream " ++ Id ++ " is already being polled.", NewSub),
			     Entry;
	_ -> supervisor:start_child(?SUP, [NewSub])
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

rebind_all(From, To) ->
    Ids = mnesia:dirty_all_keys(?PST),
    lists:map(fun(Id) -> rebind(From, To, Id) end, Ids).

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
    {ok, RequestId} = http:request(get, {Subscription#subscription.url, []}, [], [{sync, false}]),
    Callbacks = ets:new(callbacks, []),
    true = ets:insert(Callbacks, {RequestId, initial_get_stream}),
    {ok, #state{subscription = Subscription,
		callbacks = Callbacks}}.

handle_call(_Request, _From, State) ->
    Reply = ignored,
    log("Ignored call~n~p", [{_Request, _From, State}]),
    {reply, Reply, State}.

handle_cast({rebind, {From, To}}, State = #state{subscription=Sub}) ->
    Nsub = Sub#subscription{sender = From, receiver = To},
    %TODO rebind in die datenbank
    {noreply, State#state{subscription=Nsub}};

handle_cast(go_get_messages, State) ->
    Sub = State#state.subscription,
    {ok, RequestId} = http:request(get, {Sub#subscription.url, []}, [], [{sync, false}]),
    ets:insert(get_callbacks(State), {RequestId, initial_get_stream}),
    {noreply, State};

handle_cast({get_feed, From, To, Url}, State) ->
    {ok, {_, _Headers, Body}} = http:request(Url, ?INETS),
    Xml = xml_stream:parse_element(Body),
    Content = parse_rss(Xml),
    log("received xml stream, Url: ~n~p~nStream:~n~p~n", [Url, Content]),
    mod_prisma_aggregator:echo(To, From,  "feed abgerufen"),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(collapse, State) ->
    {stop, error, State};

handle_cast(_Msg, State) ->
    log("ignored cast~n~p", [{_Msg, State}]),
    {noreply, State}.

handle_info({http, {RequestId, Resp}} , State) ->
    [{_, Hook}] = ets:lookup(get_callbacks(State), RequestId),
    ets:delete(get_callbacks(State), RequestId),
    handle_http_response(Hook, Resp, State);

handle_info({'EXIT', _Reason, normal}, State) ->
    %log("on worker ~p, process stopped with Reason ~n~p", [get_id(State), Reason]),
    {noreply, State};

handle_info(Info, State) ->
    log("ignored message: ~n~p", [{Info, State}]),
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

parse_rss(Xml) ->
    try
%	log("Xml : ~n~p", [Xml]),
	Channel = xml:get_path_s(Xml, [{elem, "channel"}]),
	{xmlelement, _, _, Rss09items} = Xml,
%	log("Channel: ~n~p", [Channel]),
	{xmlelement, "channel", _, ChannelBody} = Channel,
	Items = [E || E = {xmlelement, "item", _, _} <- ChannelBody] ++
	    [E || E = {xmlelement, "item", _, _} <- Rss09items],
	Mapper = fun(Item) ->
			 [{title, xml:get_path_s(Item, [{elem, "title"}, cdata])},
			  {key, xml:get_path_s(Item, [{elem, "pubDate"}, cdata])},
			  {link, xml:get_path_s(Item, [{elem, "link"}, cdata])},
			  {content, xml:get_path_s(Item, [{elem, "description"}, cdata])}]
		 end,
	lists:map(Mapper, Items)
   catch
       _Err : _Reason -> {error, badxml}
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

handle_http_response(initial_get_stream, {_,_, Body}, State) -> 
    Sub = State#state.subscription,
    case xml_stream:parse_element(binary_to_list(Body)) of
	{error, {_, Reason}} -> 
	    log("Error while parsing xml in worker ~p: ~p", [get_id(State), Reason]),
	    %reply("Error, the stream " ++ get_id(State)  ++ " returns bad xml.", State),
	    callbacktimer(60000, go_get_messages),
	    {noreply, State};
	Xml ->
	    try
		Content = parse_rss(Xml),
		NewContent = extract_new_messages(Content, Sub),
		NSub = if
			   length(NewContent) > 0 ->
			       Text = lists:flatten(lists:map(fun(Val) -> 
								      proplists:get_value(title, Val) ++ "\n"
							      end, 
							      NewContent)),
			       reply("Neue Nachrichten von " ++ get_id(State) ++ " ->\n" ++ Text, State),
			       StoreSub = Sub#subscription{last_msg_key = merge_keys(Content, Sub#subscription.last_msg_key)},
			       mnesia:dirty_write(?PST, StoreSub),
			       StoreSub;
			   
			   true -> %log("Checked messages for ~p, no news.", [get_id(State)]),
				   Sub
		       end,
		callbacktimer(10000, go_get_messages),
		{noreply, State#state{subscription = NSub}}
	    catch
		_ : Error -> log("Caught error while trying to interpret xml.~n~p", [Error]),
			     callbacktimer(300000, go_get_messages),
			     {noreply, State}
	    end
    end;

handle_http_response(_, {error, _Reason}, State) ->
    log("Worker ~p received an polling error: ~n~p", [get_id(State), _Reason]),
    callbacktimer(600000, go_get_messages),
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
    mod_prisma_aggregator:send_message(Sub#subscription.receiver,
				       Sub#subscription.sender,
				       "chat",
				       Msg).
log(Msg, Vars) ->
    ?INFO_MSG(Msg, Vars).

rebind(From, To, Id) ->
    case get_pid_from_id(Id) of
	not_found ->
	    not_found;
	Pid -> gen_server:cast(Pid, {rebind, {From, To}})
    end.
    
