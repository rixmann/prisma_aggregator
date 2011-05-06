-include("ejabberd.hrl").

-define(SPT, process_mapping).
-define(INETS, prisma_aggregator_inets).

-record(process_mapping, {key, pid}).
