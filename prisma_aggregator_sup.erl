-module(prisma_aggregator_sup).

-behaviour(supervisor).



-compile(export_all).
-export([init/1]).

-define(CONNECTOR, aggregator_connector).

-include("prisma_aggregator.hrl").

%% supervisor implementation
init([_Host, _Opts]) ->
    Child_Spec = {?CONNECTOR, {?CONNECTOR, start_link, []},
		 transient, 5000, worker, [?CONNECTOR]},
    {ok, {{simple_one_for_one, 10, 100}, [Child_Spec]}}.

%% interface functions
start_link(Host, Opts) ->
    Erg = supervisor:start_link({local, ?MODULE}, ?MODULE, [Host, Opts]),
    ?INFO_MSG("supervisor started:~n~p~n", [Erg]),
    ok.
