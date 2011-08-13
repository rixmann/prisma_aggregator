%%%-------------------------------------------------------------------
%%% File    : prisma_test_server.erl
%%% Author  : Gu Lagong <ole@kiiiiste>
%%% Description : 
%%%
%%% Created :  1 Aug 2011 by Gu Lagong <ole@kiiiiste>
%%%-------------------------------------------------------------------
-module(prisma_test_server).

-behaviour(gen_server).

-include("prisma_aggregator.hrl").
-include("jlib.hrl").

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([message_received/1,
	 error_received/2,
	 start_test/2,
	 stop_test/0,
	 overload_received/0,
	 start_overload_and_recover/3]).

-record(state, {test, 
		error_count, 
		message_count,
		device,
		walltime_init}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start_link() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

message_received(Message) ->
    gen_server:call(?MODULE, {message_received, Message}).

error_received(Error, From) ->
    gen_server:call(?MODULE, {error_received, {Error, From}}).

overload_received() ->
    gen_server:call(?MODULE, overload).

start_test(Aggregator, Test) ->
    gen_server:call(?MODULE, {run_test, {Test, {Aggregator, 0}}}).

start_overload_and_recover(From, To, Rate) ->
    {Walltime, _} = statistics(wall_clock),
    gen_server:call(?MODULE, {run_test, {overload, {{From, To}, Walltime, 0, Rate}}}).

stop_test() ->
    gen_server:call(?MODULE, stop).


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
    ok = file:delete("/var/log/ejabberd/teststats.dat"),
    {ok, Device} = file:open("/var/log/ejabberd/teststats.dat", write),
    {Walltime1970, _} = statistics(wall_clock),
    agr:callbacktimer(10, collect_stats),
    {ok, #state{error_count = 0, 
		message_count = 0,
		walltime_init = Walltime1970,
		device = Device}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------

handle_call({recover, {{From, To}, _StartTime, Count, _Rate}}, _From, State) ->
    lists:map(fun(Num) ->
		      mod_prisma_aggregator_tester:send_emigrate(From, To, "overload_and_recover-" ++ integer_to_list(Num))
	      end,
	     lists:seq(Count div 2, Count, 1)),
    {reply, ok, State};

handle_call(overload, _From, State) ->
    {reply, ok, State#state{test= recover}};

handle_call({run_test, {overload, Params}}, _From, #state{test=recover} = State) ->
    timer(1,{run_test, {recover, Params}}),
    {reply, ok, State};

handle_call({run_test, {overload, {FromTo, StartTime, Count, Rate}}}, _From, State) ->
    {Walltime, _} = statistics(wall_clock),
    ExpectedMessages = ((Walltime - StartTime) div 1000) * Rate,
    MissingMessages = ExpectedMessages - Count,
    spawn(fun() ->
		  mod_prisma_aggregator_tester:send_subscriptions_bulk_file(Count, MissingMessages, "aggregatortester." ++ agr:config_read(host), "overload_and_recover")
	  end),
    _Timer = timer(1, {run_test, {overload, {FromTo, StartTime, Count + MissingMessages, Rate}}}),
    {reply, ok, State#state{test=overload}};

handle_call({run_test, {Test, {Aggregator, Count}}}, _From, State) ->
    Subs = [mod_prisma_aggregator_tester:create_json_subscription("http://127.0.0.1:8000/index.yaws" ++ Test, 
								  jlib:jid_to_string(mod_prisma_aggregator_tester:get_sender()), 
								  "ATOM", 
								  "test_hohes_1-" ++ integer_to_list(I)) 
	    || I <- lists:seq(Count, Count + 1000)],
    mod_prisma_aggregator_tester:send_iq(mod_prisma_aggregator_tester:get_sender(), 
					 jlib:string_to_jid(Aggregator),
					 "subscribeBulk",
					 json_eep:term_to_json(Subs)),
    timer(120000, {run_test, {Test, {Aggregator, Count + 1000}}}),
    ?INFO_MSG("Test: ~p Neue Nachrichten werden verschickt ~p", [Test, Count + 1000]),
    {reply, ok, State#state{test=continuous}};

handle_call({message_received, _Message}, _From, State) ->
    {reply, ok, State#state{message_count = State#state.message_count + 1}};

handle_call({error_received, {Error, From}}, _From, State) ->
    {[{<<"class">>,<<"de.prisma.datamodel.message.ErrorMessage">>},
      {<<"subscriptionID">>, SubId}, _, _]} = Error,
    try
	mod_prisma_aggregator:send_iq(mod_prisma_aggregator_tester:get_sender(),
				      jlib:string_to_jid(From),
				      "unsubscribe",
				      json_eep:term_to_json(binary_to_list(SubId)))
    catch
	_ : _ -> fail %wegen binary to list
    end,
    {reply, ok, State#state{error_count = State#state.error_count + 1}};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast(collect_stats, State = #state{device = Dev,
					  walltime_init = Walltime_init,
					  message_count = MCount,
					  error_count = ECount}) ->
    {Walltime1970, _} = statistics(wall_clock),
    io:format(Dev,                                    %add a line to teststats.dat
	      "~-15w ~-15w ~-15w~n",
	      [trunc((Walltime1970 - Walltime_init) div 100),
	       MCount,
	       ECount]),
    agr:callbacktimer(1000, collect_stats),
    {noreply, State};
					  
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
terminate(_Reason, _State) ->
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

timer(Time, Params)-> 
    timer:apply_after(Time, gen_server, call, [?MODULE, Params]).
