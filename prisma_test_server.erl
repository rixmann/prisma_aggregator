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
	 error_received/1,
	 start_test/2,
	 stop_test/0]).

-record(state, {test, error_count, message_count}).

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

error_received(Error) ->
    gen_server:call(?MODULE, {error_received, Error}).

start_test(Aggregator, Test) ->
    case Test of
	"1" -> gen_server:call(?MODULE, {run_test, {hohes_aufkommen, {Aggregator, 0}}})
    end.

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
    {ok, #state{error_count = 0, message_count = 0}}.

%%--------------------------------------------------------------------
%% Function: %% handle_call(Request, From, State) -> {reply, Reply, State} |
%%                                      {reply, Reply, State, Timeout} |
%%                                      {noreply, State} |
%%                                      {noreply, State, Timeout} |
%%                                      {stop, Reason, Reply, State} |
%%                                      {stop, Reason, State}
%% Description: Handling call messages
%%--------------------------------------------------------------------
handle_call({run_test, {Test, {Aggregator, Count}}}, _From, State) ->
    case Test of 
	hohes_aufkommen -> 
	    Subs = [mod_prisma_aggregator_tester:create_json_subscription("http://127.0.0.1:8000/index.yaws", 
					     jlib:jid_to_string(mod_prisma_aggregator_tester:get_sender()), 
					     "ATOM", 
					     "test_hohes_1-" ++ integer_to_list(I)) 
		    || I <- lists:seq(Count, Count + 1000)],
	    mod_prisma_aggregator_tester:send_iq(mod_prisma_aggregator_tester:get_sender(), 
						 jlib:string_to_jid(Aggregator),
						 "subscribeBulk",
						 json_eep:term_to_json(Subs)),
	    Timer = timer:apply_after(120000, gen_server, call, [?MODULE, {run_test, {hohes_aufkommen, {Aggregator, Count + 1000}}}]),
	    ?INFO_MSG("Test: Hohes Aufkommen, neue Nachrichten werden verschickt ~p~nTimer: ~p", [Count + 1000, Timer]),
	    {reply, ok, State}
    end;

handle_call({message_received, _Message}, _From, State) ->
    {reply, ok, State#state{message_count = State#state.message_count + 1}};
handle_call({error_received, _Error}, _From, State) ->
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
