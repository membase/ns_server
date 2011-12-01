# In console 1...
#   make prep
#
# In console 2...
#   cd .. && ./cluster_run.sh
#
# In console 1...
#   make usual
#
# Some other some useful commands...
#   make all-server-list
#   make all-bucket-list
#
NODES=4

prep: clean
	(cd .. && ./test/gen_cluster_scripts.rb $(NODES))

clean:
	rm -rf ../data ../config ../logs ../Mnesia*

# Initialize a just started cluster, with a default bucket,
# with all nodes joined and rebalanced.
#
usual: all-cluster-init bucket-create joiners-add rebalance

# ---------------------------------------------------

# Run a membase CLI command against every node.
#
DO=error

all-rest-do:
	@for ((i = $(REST_PORT); i < $(REST_PORT) + $(NODES); i++)); do \
       $(MAKE) REST_PORT=$$i $(DO); \
    done

all-memcached-do:
	@for ((i = $(MEMCACHED_PORT); i < $(MEMCACHED_PORT) + 2 * $(NODES); i = i + 2)); do \
       $(MAKE) MEMCACHED_PORT=$$i $(DO); \
    done

# ---------------------------------------------------

all-cluster-init:
	$(MAKE) all-rest-do NODES=$(NODES) DO=cluster-init

all-server-list:
	$(MAKE) all-rest-do NODES=$(NODES) DO=server-list

all-server-info:
	$(MAKE) all-rest-do NODES=$(NODES) DO=server-info

all-bucket-list:
	$(MAKE) all-rest-do NODES=$(NODES) DO=bucket-list

all-stats-all:
	$(MAKE) all-memcached-do NODES=$(NODES) DO=stats-all

all-stats-dispatcher:
	$(MAKE) all-memcached-do NODES=$(NODES) DO=stats-dispatcher

all-stats-tap:
	$(MAKE) all-memcached-do NODES=$(NODES) DO=stats-tap

all-stats-timings:
	$(MAKE) all-memcached-do NODES=$(NODES) DO=stats-timings

all-stats-reset:
	$(MAKE) all-memcached-do NODES=$(NODES) DO=stats-reset

# ---------------------------------------------------

# Run a membase CLI command against joining nodes.
#
joiners-do:
	@for ((i = $(REST_PORT) + 1; i < $(REST_PORT) + $(NODES); i++)); do \
        $(MAKE) JOINER_ADDR=127.0.0.1:$$i $(DO); \
    done

joiners-add:
	$(MAKE) joiners-do NODES=$(NODES) DO=server-add

joiners-remove:
	$(MAKE) joiners-do NODES=$(NODES) DO=server-remove

# ---------------------------------------------------

# Helper targets for common membase-cli commands.
#
MEMBASE_CLI=../../membase-cli/couchbase
MANAGEMENT=../../ep-engine/management

REST_USER=Administrator
REST_PASSWORD=111111
REST_HOST=127.0.0.1
REST_PORT=9000

cluster-init:
	$(MEMBASE_CLI) cluster-init -c $(REST_HOST):$(REST_PORT) \
       --cluster-init-username=$(REST_USER) \
       --cluster-init-password=$(REST_PASSWORD)

server-list:
	$(MEMBASE_CLI) server-list -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD)

server-info:
	$(MEMBASE_CLI) server-info -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD)

server-add:
	$(MEMBASE_CLI) server-add -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD) \
       --server-add=$(JOINER_ADDR) \
       --server-add-username=$(REST_USER) \
       --server-add-password=$(REST_PASSWORD)

server-remove:
	$(MEMBASE_CLI) rebalance -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD) \
       --server-remove=$(JOINER_ADDR)

rebalance:
	$(MEMBASE_CLI) rebalance -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD) \

rebalance-stop:
	$(MEMBASE_CLI) rebalance-stop -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD) \

rebalance-status:
	$(MEMBASE_CLI) rebalance-status -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD) \

BUCKET=default
BUCKET_TYPE=membase
BUCKET_PASSWORD=
BUCKET_RAMSIZE=200
BUCKET_REPLICA=1

bucket-create:
	$(MEMBASE_CLI) bucket-create -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD) \
       --bucket=$(BUCKET) \
       --bucket-type=$(BUCKET_TYPE) \
       --bucket-password=$(BUCKET_PASSWORD) \
       --bucket-ramsize=$(BUCKET_RAMSIZE) \
       --bucket-replica=$(BUCKET_REPLICA)

bucket-list:
	$(MEMBASE_CLI) bucket-list -c $(REST_HOST):$(REST_PORT) \
       -u $(REST_USER) -p $(REST_PASSWORD)

# -----------------------------------------------

MEMCACHED_HOST=127.0.0.1
MEMCACHED_PORT=12000

stats-all:
	$(MANAGEMENT)/stats $(MEMCACHED_HOST):$(MEMCACHED_PORT) all

stats-dispatcher:
	$(MANAGEMENT)/stats $(MEMCACHED_HOST):$(MEMCACHED_PORT) dispatcher

stats-hash:
	$(MANAGEMENT)/stats $(MEMCACHED_HOST):$(MEMCACHED_PORT) hash

stats-tap:
	$(MANAGEMENT)/stats $(MEMCACHED_HOST):$(MEMCACHED_PORT) tap

stats-timings:
	$(MANAGEMENT)/stats $(MEMCACHED_HOST):$(MEMCACHED_PORT) timings

stats-reset:
	$(MANAGEMENT)/stats $(MEMCACHED_HOST):$(MEMCACHED_PORT) reset

# -----------------------------------------------

test-rebalance-loop: usual
	for i in {0..10000000}; do \
        echo ------------------------- $$i - `date`; \
        $(MAKE) joiners-remove; \
        sleep 2; \
        $(MAKE) joiners-add; \
        sleep 2; \
        $(MAKE) rebalance; \
        sleep 2; \
    done;
