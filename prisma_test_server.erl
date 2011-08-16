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
	 start_test/5,
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
    gen_server:cast(?MODULE, {message_received, Message}).

error_received(Error, From) ->
    gen_server:cast(?MODULE, {error_received, {Error, From}}).

overload_received() ->
    gen_server:cast(?MODULE, overload).

start_test(Aggregator, Server, Params, Startport, PCount) ->
    gen_server:cast(?MODULE, {run_test, {Aggregator, Server, Params, Startport, PCount}, 0}).

start_overload_and_recover(From, To, Rate) ->
    {Walltime, _} = statistics(wall_clock),
    gen_server:cast(?MODULE, {run_test, {overload, {{From, To}, Walltime, 0, Rate}}}).

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


handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
%% Function: handle_cast(Msg, State) -> {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, State}
%% Description: Handling cast messages
%%--------------------------------------------------------------------
handle_cast({run_test, {Aggregator, Server, Params, Startport, PCount}, Count}, State) ->
    Subs = [mod_prisma_aggregator_tester:create_json_subscription("http://" ++ Server ++ ":" ++ integer_to_list(Startport + (I div PCount)) ++ "/" ++ Params, 
								  jlib:jid_to_string(mod_prisma_aggregator_tester:get_sender()), 
								  "ATOM", 
								  "test_hohes_1-" ++ integer_to_list(I)) 
	    || I <- lists:seq(Count, Count + 1000)],
    agr:callbacktimer(120000, {run_test, {Aggregator, Server, Params, Startport, PCount}, Count + 1000}),
    mod_prisma_aggregator_tester:send_bulk_subscriptions(jlib:string_to_jid(Aggregator), Subs),
    ?INFO_MSG("Test: ~p Neue Nachrichten werden verschickt ~p", [Params, Count + 1000]),
    {noreply, State#state{test=continuous}};

handle_cast({message_received, _Message}, State) ->
    {noreply, State#state{message_count = State#state.message_count + 1}};

handle_cast({error_received, {Error, From}}, State) ->
    {[{<<"class">>,<<"de.prisma.datamodel.message.ErrorMessage">>},
      {<<"subscriptionID">>, SubId}, _, _]} = Error,
    try
	mod_prisma_aggregator_tester:send_iq(mod_prisma_aggregator_tester:get_sender(),
				      jlib:string_to_jid(From),
				      "unsubscribe",
				      json_eep:term_to_json(binary_to_list(SubId)))
    catch
	_ : _ -> fail %wegen binary to list
    end,
    {noreply, State#state{error_count = State#state.error_count + 1}};

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast(overload, State) ->
    ?INFO_MSG("In overload", []),
    {noreply, State#state{test= recover}};

handle_cast({run_test, {overload,  {{From, To}, _StartTime, Count, _Rate, Dev}}}, #state{test=recover} = State) ->
    ?INFO_MSG("In run recover", []),
    file:close(Dev),
    lists:map(fun(Num) ->
		      mod_prisma_aggregator_tester:send_emigrate(From, To, "overload_and_recover-" ++ integer_to_list(Num))
	      end,
	      lists:seq(Count div 2, Count, 1)),
    {noreply, State};

handle_cast({run_test, {overload, {FromTo, StartTime, Count, Rate}}}, State) ->
    {ok, Dev} = file:open("/usr/lib/ejabberd/testfeeds.txt", read),
    gen_server:cast(?MODULE, {run_test, {overload, {FromTo, StartTime, Count, Rate, Dev}}}),
    {noreply, State};

handle_cast({run_test, {overload, {{From, To}, StartTime, Count, Rate, Dev}}}, State) ->
    {Walltime, _} = statistics(wall_clock),
    ExpectedMessages = ((Walltime - StartTime) div 1000) * Rate,
    MissingMessages = ExpectedMessages - Count,
    F = fun(Line, N) ->
		mod_prisma_aggregator_tester:subscription_from_line(Line, "aggregatortester." ++ agr:config_read(host), "overload_and_recover-" ++ integer_to_list(N))
	end,
    Subs = map_to_n_lines(Dev, Count, Count , ExpectedMessages, F, []),
    mod_prisma_aggregator_tester:send_bulk_subscriptions(jlib:string_to_jid(From), Subs),
    agr:callbacktimer(100, {run_test, {overload, {{From, To}, StartTime, Count + MissingMessages, Rate, Dev}}}),
    {noreply, State#state{test=overload}};

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

map_to_n_lines(_Device, _Start , N, N, _F, Acc) ->
    Acc;

map_to_n_lines(Device, Start, Count, N, F, Acc) ->
    case io:get_line(Device, "") of
        eof  -> Acc;
        Line -> 
	    if 
		Count >= Start ->
		    map_to_n_lines(Device, Start, Count + 1, N, F, [F(Line, Count)| Acc]);
		true ->
		    map_to_n_lines(Device, Start, Count + 1, N, F, Acc)
	    end
    end.
