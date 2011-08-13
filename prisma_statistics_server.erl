%%%-------------------------------------------------------------------
%%% File    : prisma_statistics_server.erl
%%% Author  : Ole Rixmann <ole@kiiiiste>
%%% Description : 
%%%
%%% Created : 30 Jun 2011 by Ole Rixmann <ole@kiiiiste>
%%%-------------------------------------------------------------------
-module(prisma_statistics_server).
-behaviour(gen_server).
-include("prisma_aggregator.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([signal_httpc_ok/0, signal_httpc_overload/0,
	subscription_add/0, subscription_remove/0,
	sub_proceeded/0]).

-record(state, {httpc_overload = false, 
		device, 
		timestamp_offset,
		runtime_offset,
		old_load = 0,
		subscription_count = 0,
		proceeded_subs,
		proceeded_subs_old,
		walltime_init,
		last_time_runque_under_treshhold,
		error_message_sent}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

signal_httpc_overload() ->
    gen_server:cast(?MODULE, httpc_overload).

signal_httpc_ok() ->
    gen_server:cast(?MODULE, httpc_ok).

sub_proceeded() ->
    gen_server:cast(?MODULE, sub_proceeded).

subscription_add() ->
    gen_server:cast(?MODULE, subscription_add).

subscription_remove() ->
    gen_server:cast(?MODULE, subscription_rem).

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
init([]) ->
    ok = file:delete("/var/log/ejabberd/runtimestats.dat"),
    {ok, Device} = file:open("/var/log/ejabberd/runtimestats.dat", write),
    agr:callbacktimer(10, collect_stats),
    {RuntimeStart, _} = statistics(runtime),
    {Walltime1970, _} = statistics(wall_clock),
    {ok, #state{device = Device, 
		subscription_count = 0,
		proceeded_subs = 0,
		proceeded_subs_old = 0,
		timestamp_offset = Walltime1970,
		runtime_offset = RuntimeStart,
		walltime_init = Walltime1970,
		last_time_runque_under_treshhold = Walltime1970,
		error_message_sent = false}}.

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
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(subscription_rem, State = #state{subscription_count = Count}) ->
    {noreply, State#state{subscription_count = Count - 1}};

handle_cast(subscription_add, State = #state{subscription_count = Count}) ->
    {noreply, State#state{subscription_count = Count + 1}};

handle_cast(httpc_overload, State = #state{}) ->
    {noreply, State#state{httpc_overload = true}};

handle_cast(httpc_ok, State = #state{}) ->
    {noreply, State#state{httpc_overload = false}};

handle_cast(sub_proceeded, State = #state{proceeded_subs = Psubs}) ->
    {noreply, State#state{proceeded_subs = Psubs + 1}};

handle_cast(collect_stats, State = #state{device = Dev, 
					  timestamp_offset = To,
					  runtime_offset = Rto,
					  httpc_overload = Httpc_overload,
					  subscription_count = SubCnt,
					  proceeded_subs = Psubs,
					  proceeded_subs_old = Psubs_old,
					  walltime_init = Walltime_init,
					  last_time_runque_under_treshhold = OldTreshholdTime,
					  error_message_sent = ErrorMessageSent}) ->
    {RuntimeStart, _} = statistics(runtime),
    {Walltime1970, _} = statistics(wall_clock),
    Runque = statistics(run_queue),
    Runtime = RuntimeStart - Rto,
    Walltime = Walltime1970 - To,
    RunqueTreshholdHit = (Runque > agr:config_read(overload_treshhold_runque)),
    {NewTreshholdTime, EMSentNew} = if RunqueTreshholdHit ->
					    Window = agr:config_read(overload_treshhold_window),
					    if ((Walltime1970 - OldTreshholdTime)  > Window) ->
						    if (not ErrorMessageSent) ->
							    mod_prisma_aggregator:send_message(agr:config_read(aggregator),
											  agr:config_read(coordinator),
											  "PrismaMessage",
											  json_eep:term_to_json("overloaded")),
							    {OldTreshholdTime, true};
						       true -> 
							    {OldTreshholdTime, true}
						    end;
					       true -> {OldTreshholdTime, false}
					    end;
				       true -> {Walltime1970, false}
				    end,
    
    
    Nload = trunc(100 * Runtime / Walltime),
    Psubs_sec = trunc(Psubs / (Walltime / 1000)),
    NPsubs = trunc(Psubs_old * 0.9 + Psubs_sec * 0.1),
    io:format(Dev,                                    %add a line to runtimestats.dat
	      "~-15w ~-15w ~-15w ~-15w ~-15w ~-15w ~-15w ~15w~n",
	      [trunc((Walltime1970 - Walltime_init) div 100),  %walltime in 10th of seconds
	       Runque,                 %processes ready to run	
	       Nload,                                 %precent cpu usage 100% ~ 1 core
	       if Httpc_overload -> 1;
		  true -> 0
	       end,
	       SubCnt div 100,
	       Psubs_sec,
	       try %speicherverbrauch, wird durch shell-aufruf geholt
		   list_to_integer(string:substr(os:cmd("ps -p " ++ os:getpid() ++ " -o vsz="), 2, length(os:cmd("ps -p " ++ os:getpid() ++ " -o vsz=")) -2)) div (1024 * 10)
	       catch
		   _:_ -> -1
	       end,
	      Walltime1970 - NewTreshholdTime]),
    agr:callbacktimer(1000, collect_stats),
    {noreply, State#state{proceeded_subs = 0,
			  proceeded_subs_old = NPsubs,
			  timestamp_offset = Walltime1970,
			  runtime_offset = RuntimeStart,
			  last_time_runque_under_treshhold = NewTreshholdTime,
			  error_message_sent = EMSentNew}};

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
terminate(_Reason, _State = #state{device = Dev}) ->
    file:close(Dev),
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

