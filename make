#! /bin/sh
#
#
#
#

erlc -I /usr/lib/ejabberd/include/ -pz /usr/lib/ejabberd/ebin/ prisma_aggregator_sup.erl aggregator_connector.erl mod_prisma_aggregator.erl &&

sudo cp mod_prisma_aggregator.beam aggregator_connector.beam prisma_aggregator_sup.beam /usr/lib/ejabberd/ebin/

#sudo cp prisma_aggregator.hrl /usr/lib/ejabberd/include/
