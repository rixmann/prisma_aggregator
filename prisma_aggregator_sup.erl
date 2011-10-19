%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                                                                            %%
%% Copyright 2011 Ole Rixmann.                                                %%
%%                                                                            %%
%% This file is part of PRISMA-Aggregator.                                    %%
%%                                                                            %%
%% PRISMA-Aggregator is free software: you can redistribute it and/or         %%
%% modify it under the terms of the GNU Affero General Public License         %%
%% as published by the Free Software Foundation, either version 3 of          %%
%% the License, or (at your option) any later version.                        %%
%%                                                                            %%
%% PRISMA-Aggregator is distributed in the hope that it will be useful,       %%
%% but WITHOUT ANY WARRANTY; without even the implied warranty of             %%
%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.                       %%
%% See the GNU Affero General Public License for more details.                %%
%%                                                                            %%
%% You should have received a copy of the GNU Affero General Public License   %%
%% along with PRISMA-Aggregator.  If not, see <http://www.gnu.org/licenses/>. %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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
