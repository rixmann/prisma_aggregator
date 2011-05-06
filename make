#! /bin/sh
#
#
#
#
EJABBERD_LIB_PATH="/usr/lib/ejabberd/"

erlc -I $EJABBERD_LIB_PATH"include/" -pz $EJABBERD_LIB_PATH"ebin/" prisma_aggregator_sup.erl aggregator_connector.erl mod_prisma_aggregator.erl &&

sudo cp mod_prisma_aggregator.beam aggregator_connector.beam prisma_aggregator_sup.beam $EJABBERD_LIB_PATH"ebin/"

#sudo cp prisma_aggregator.hrl /usr/lib/ejabberd/include/
