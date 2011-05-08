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
-export([start_link/1, stop/1, collapse/1, new_subscription/3, start_worker/1]).

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
    supervisor:start_child(?SUP, [Sub#subscription{sender=From, receiver=To}]).

start_worker(Id) ->
    supervisor:start_child(?SUP, [Id]).

start_link(Subscription) ->
    gen_server:start_link(?MODULE, [Subscription], []).
    
stop(Id) ->
    Pid = get_pid_from_id(Id),
    gen_server:cast(Pid, stop).

collapse(Id) ->
    Pid = get_pid_from_id(Id),
    ?INFO_MSG("Trying to collapse worker with pid: ~n~p", [Pid]),
    gen_server:cast(Pid, collapse).
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
    {reply, Reply, State}.

handle_cast(go_get_messages, State) ->
    Sub = State#state.subscription,
    {ok, RequestId} = http:request(get, {Sub#subscription.url, []}, [], [{sync, false}]),
    ets:insert(State#state.callbacks, {RequestId, initial_get_stream}),
    {noreply, State};

handle_cast({get_feed, From, To, Url}, State) ->
    {ok, {_, _Headers, Body}} = http:request(Url, ?INETS),
    Xml = xml_stream:parse_element(Body),
    Content = parse_rss(Xml),
    ?INFO_MSG("received xml stream, Url: ~n~p~nStream:~n~p~n", [Url, Content]),
    mod_prisma_aggregator:echo(To, From,  "feed abgerufen"),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(collapse, State) ->
    {stop, error, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({http, {RequestId, Resp}} , State) ->
    [{_, Hook}] = ets:lookup(State#state.callbacks, RequestId),
    ets:delete(State#state.callbacks, RequestId),
    handle_http_response(Hook, Resp, State);

handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};

handle_info(Info, State) ->
    ?INFO_MSG("received unhandled message: ~n~p", [Info]),
    {noreply, State}.


terminate(_Reason, State) ->
    F = fun() -> mnesia:delete(?SPT, (State#state.subscription)#subscription.id) end, 
    mnesia:transaction(F),
    ?INFO_MSG("Worker stopping, id: ~p~n", [(State#state.subscription)#subscription.id]),
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
	    log("Error at parsing xml: ~n~p", [Reason]),
	    reply("Error, the stream " ++ get_id(State)  ++ " returns bad xml.", State),
	    {stop, normal, State};
	Xml ->
	    try
		Content = parse_rss(Xml),
		NewContent = lists:takewhile(fun(El) -> Sub#subscription.last_msg_key =/= select_key(El) end, Content),
		NSub = if
			   length(NewContent) > 0 ->
			       Text = lists:flatten(lists:map(fun(Val) -> 
								      proplists:get_value(title, Val) ++ "\n"
							      end, 
							      NewContent)),
			       reply("Neue Nachrichten:\n" ++ Text, State),
			       [H | _] = Content,
			       StoreSub = Sub#subscription{last_msg_key = select_key(H)},
			       mnesia:dirty_write(?PST, StoreSub),
			       StoreSub;
			   
			   true -> log("Checked messages for ~p, no news.", [get_id(State)]),
				   Sub
		       end,
		callbacktimer(10000, go_get_messages),
		{noreply, State#state{subscription = NSub}}
	    catch
		_ : Error -> log("Caught error while trying to interpret xml, stopping worker.~n~p", [Error]),
			     reply("Error, invalid rss", State),
			     {stop, normal, State}
	    end
    end.

callbacktimer(Time, Callback) ->
    Caller = self(),
    F = fun() ->
		receive
		after Time ->
			gen_server:cast(Caller, Callback)
		end
	end,
    spawn(F).

get_id(State) ->
    (State#state.subscription)#subscription.id.

reply(Msg, State) ->
    Sub = State#state.subscription,
    mod_prisma_aggregator:send_message(Sub#subscription.receiver,
				       Sub#subscription.sender,
				       "chat",
				       Msg).
log(Msg, Vars) ->
    ?INFO_MSG(Msg, Vars).
