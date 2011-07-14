-include("ejabberd.hrl").

-define(SPT, process_mapping).
-define(PST, subscription).

-define(INETS, prisma_aggregator_inets).
-define(SUP, prisma_aggregator_sup).
-define(RAND, prisma_random_generator).

-define(CFG, aggregator_config).
-define(POLLTIME, 60000).

-record(process_mapping, {key, pid}).

-record(subscription, {id, url = "", 
		       last_msg_key = "", 
		       source_type="", 
		       accessor = "", 
		       host = "",
		       polltime = 6000}).

