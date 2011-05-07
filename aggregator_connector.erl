%%%-------------------------------------------------------------------
%%% File    : aggregator_connector.erl
%%% Author  : Ole Rixmann <rixmann.ole@googlemail.com>
%%% Description : 
%%%
%%% Created :  4 May 2011 by Ole Rixmann
%%%-------------------------------------------------------------------
-module(aggregator_connector).

-behaviour(gen_server).

-include("prisma_aggregator.hrl").

%% API
-export([start_link/1, stop/1, new_subscription/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, 
	{subscription = #subscription{},
	 callbacks = ets:new(callbacks, [])}).

%%====================================================================
%% API
%%====================================================================

new_subscription(From, To, Sub = #subscription{}) ->
    supervisor:start_child(?SUP, [Sub#subscription{sender=From, receiver=To}]);
new_subscription(_From, _To, Id) ->
    supervisor:start_child(?SUP, [Id]).

start_link(Subscription) ->
    gen_server:start_link(?MODULE, [Subscription], []).
    
stop(Id) ->
    Pid = get_pid_from_id(Id),
    gen_server:cast(Pid, stop).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% init([SubOrId]) ->
%%     Id = get_id_from_subscription_or_id(SubOrId),
%%     process_flag(trap_exit, true),
%%     F = fun() -> mnesia:write(?SPT, #process_mapping{key = Id, pid = self()}, write),
%% 		 case Id of
%% 		     not_found -> mnesia:write(?PST, SubOrId),
%% 				  SubOrId;
%% 		     _ -> mnesia:read(?PST, Id)
%% 		 end, 
%%     Mnret = mnesia:transaction(F),
%%     ?INFO_MSG("connector for id ~p started!~nMnesia Write:~n~p~n", [Id, Mnret]),
%%     {ok, #state{id = Id}}.

init([SubOrId]) ->
    Id = get_id_from_subscription_or_id(SubOrId),
    process_flag(trap_exit, true),
    F = fun() -> ok = mnesia:write(?SPT, #process_mapping{key = Id, pid = self()}, write),
		 case mnesia:read(?PST, Id) of
		     [] ->     ?INFO_MSG("[] subscription: ~n~p", [SubOrId]),
			       ok = mnesia:write(?PST, SubOrId, write),
			       SubOrId;
		     [Sub] -> ?INFO_MSG("[Sub]", []),
			      Sub;
		     _ -> ?INFO_MSG("error", []),
			  error
		 end
	end, 
    ?INFO_MSG("transaction about to start", []),
    {atomic, Subscription} = mnesia:transaction(F),
    ?INFO_MSG("new process spawned, corresponding subscription is ~p", [Subscription]),
    {ok, RequestId} = http:request(get, {Subscription#subscription.url, []}, [], [{sync, false}]),
    Callbacks = ets:new(callbacks, []),
    true = ets:insert(Callbacks, {RequestId, initial_get_stream}),
    {ok, #state{subscription = Subscription,
		callbacks = Callbacks}}.

handle_call(_Request, _From, State) ->
    Reply = ignored,
    {reply, Reply, State}.

handle_cast({get_feed, From, To, Url}, State) ->
    {ok, {_, _Headers, Body}} = http:request(Url, ?INETS),
    Xml = xml_stream:parse_element(Body),
    Content = parse_rss(Xml),
    ?INFO_MSG("received xml stream, Url: ~n~p~nStream:~n~p~n", [Url, Content]),
    mod_prisma_aggregator:echo(To, From,  "feed abgerufen"),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({http, {RequestId, {_, _Headers, Body}}} , State) ->
    case ets:lookup(State#state.callbacks, RequestId) of
	[{_, initial_get_stream}] -> Xml = xml_stream:parse_element(Body),
				     Content = parse_rss(Xml),
				     Sub = State#state.subscription,
				     mod_prisma_aggregator:send_message(Sub#subscription.receiver,
								       Sub#subscription.sender,
								       "chat",
									lists:flatten(lists:map(fun(Val) -> proplists:get_value(title, Val) ++ "\n"
											       end, Content)))
    end,
    {noreply, State};

handle_info(_Info, State) ->
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
    {xmlelement, "channel", _, ChannelBody} = xml:get_path_s(Xml, [{elem, "channel"}]),
    Items = [E || E = {xmlelement, "item", _, _} <- ChannelBody],
    Mapper = fun(Item) ->
		     [{title, xml:get_path_s(Item, [{elem, "title"}, cdata])},
		      {key, xml:get_path_s(Item, [{elem, "pubDate"}, cdata])},
		      {link, xml:get_path_s(Item, [{elem, "link"}, cdata])},
		      {content, xml:get_path_s(Item, [{elem, "description"}, cdata])}]
	     end,
    lists:map(Mapper, Items).

get_id_from_subscription_or_id(#subscription{id = Id}) ->
    Id;
get_id_from_subscription_or_id(Id) ->
    Id.
