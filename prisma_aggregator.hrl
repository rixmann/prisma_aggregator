-include("ejabberd.hrl").

-define(SPT, process_mapping).
-define(PST, subscription).

-define(INETS, prisma_aggregator_inets).
-define(SUP, prisma_aggregator_sup).

-record(process_mapping, {key, pid}).

-record(subscription, {id, url = "", sender = "", receiver = "", last_msg_key = ""}).

