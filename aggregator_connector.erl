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
-export([start_link/1, stop/1, get_feed/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {id}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link(Id) ->
    gen_server:start_link(?MODULE, [Id], []).

stop(Id) ->
    Pid = get_pid_from_id(Id),
    gen_server:cast(Pid, stop).

get_feed(From, To, Id, Url) ->
    Pid = get_pid_from_id(Id),
    gen_server:cast(Pid, {get_feed, From, To, Url}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%%--------------------------------------------------------------------
%% Function: init(Args) -> {ok, State} |
%%                         {ok, State, Timeout} |
%%                         ignore               |
%%                         {stop, Reason}
%% Description: Initiates the server
%%--------------------------------------------------------------------
init([Id]) ->
    process_flag(trap_exit, true),
    F = fun() -> mnesia:write(?SPT, #process_mapping{key = Id, pid = self()}, write) end, 
    Mnret = mnesia:transaction(F),
    ?INFO_MSG("connector for id ~p started!~nMnesia Write:~n~p~n", [Id, Mnret]),
    {ok, #state{id=Id}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------


handle_call(_Request, _From, State) ->
    Reply = ignored,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({get_feed, From, To, Url}, State) ->
    {ok, {_, _Headers, Body}} = http:request(Url, ?INETS),
    %http:request("http://news.google.com/news?ned=us&topic=h&output=atom", ?INETS),
    ?INFO_MSG("received xml stream, Url: ~n~p~nStream:~n~p~n", [Url,xmerl_scan:string(Body)]),
    mod_prisma_aggregator:echo(To, From,  "feed abgerufen"),
    {noreply, State};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: handle_info(Info, State) -> {noreply, State} |
%%                                       {noreply, State, Timeout} |
%%                                       {stop, Reason, State}
%% Description: Handling all non call/cast messages
%%--------------------------------------------------------------------
handle_info(_Info, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% Function: terminate(Reason, State) -> void()
%% Description: This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any necessary
%% cleaning up. When it returns, the gen_server terminates with Reason.
%% The return value is ignored.
%%--------------------------------------------------------------------
terminate(_Reason, State) ->
    F = fun() -> mnesia:delete(?SPT, State#state.id) end, 
    mnesia:transaction(F),
    ?INFO_MSG("Worker stopping, id: ~p~n", [State#state.id]),
    ok.

%%--------------------------------------------------------------------
%% Func: code_change(OldVsn, State, Extra) -> {ok, NewState}
%% Description: Convert process state when code is changed
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

get_pid_from_id(Id) ->
    F = fun() ->
		mnesia:read(?SPT, Id)
	end,
    {atomic, [#process_mapping{pid=Pid}]} = mnesia:transaction(F),
    Pid.

