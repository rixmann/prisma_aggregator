#! /bin/sh
#
#
#
#
EJABBERD_LIB_PATH="/usr/lib/ejabberd/"

erlc -I $EJABBERD_LIB_PATH"include/" -pz $EJABBERD_LIB_PATH"ebin/" prisma_aggregator_sup.erl aggregator_connector.erl mod_prisma_aggregator.erl mod_prisma_aggregator_tester.erl prisma_random_generator.erl agr.erl prisma_statistics_server.erl &&

#cp erlang-json-eep-parser/*.beam .

sudo cp *.beam  $EJABBERD_LIB_PATH"ebin/"

#sudo cp prisma_aggregator.hrl /usr/lib/ejabberd/include/
