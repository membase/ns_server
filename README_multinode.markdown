# Running Multiple Nodes per machine

During testing or development, you might want to run more than one
node per box.  For example, you might want to run two nodes ("ns_1"
and "ns_2") on your development laptop.  To do so requires priv/config
file propery overrides.  Here are the step by step instructions...

There are helper scripts that help generate the right multi-node
configuration files.  To get a 5 node cluster config file, so that
all the nodes (n_0, n_1, ...) run on 127.0.0.1...

    ./test/gen_cluster_scripts.rb 5

To start the cluster...

    ./cluster_run.sh

Now, you can point your web browser to...

    http://localhost:9000
    http://localhost:9001
    ...
    http://localhost:9004

And, you can join the nodes together with the web console UI.

The memcached direct servers will be running on even port numbers...

   12000, 12002, 12004, ...

The emoxi servers will be running on odd port numbers

   12001, 12003, 12005, ...

To stop the cluster press Ctrl-D or Ctrl-C.

After you've joined nodes together, they will remember their join
configuration (in the ./config directory) and when you start/stop
the cluster, they should automatically rejoin.

-------------------

Below are the old manual instructions for joining nodes together into
a cluster...

Make a copy of the priv/config file...

    cp priv/config priv/config2

Start erlang...

    erl -name ns_1

Make a note of your "node name" at erlang's shell prompt.  For
example, below my node name is "ns_1@stevenmb.gateway.2wire.net"...

    stevenmb:ns_server steveyen$ erl -name ns_1
    Erlang R13B03 (erts-5.7.4) [source]
    Eshell V5.7.4  (abort with ^G)
    (ns_1@stevenmb.gateway.2wire.net)1>

Quit/ctrl-C from the erlang shell.

Next, open up your favorite text editor to edit the priv/config2 file.
You'll need to edit everywhere you see a port number, and add extra
"per-node" entries.  One by one...

In your priv/config2 file, if you see...

    {rest, [{'_ver', {0, 0, 0}},
            {port, 8091}
           ]}.

Add an additional "per-node" entry right below it, so it looks like...

    {rest, [{'_ver', {0, 0, 0}},
            {port, 8091}
           ]}.
    {{node, 'ns_2@stevenmb.gateway.2wire.net', rest},
         [{'_ver', {0, 0, 0}},
          {port, 8081}
         ]}.

With the above change, the priv/config2 file is saying that by default
the rest key has a port value of 8091.  And, on node
ns_2@stevenmb.gateway.2wire.net, the value of the rest key will have a
port number of 8081.  So, when ns_1 and ns_2 run on the same machine,
they won't have a REST admin api port conflict.

By the way, you can add more than one "per-node" entries, which is
useful in case you move your machine between networks.  For example, I
have 3 extra entries, one for the office, one for home, and one for
when I'm not connected.  So, my per-node overrides in my priv/config2
file look like...

    {rest, [{'_ver', {0, 0, 0}},
            {port, 8091}
           ]}.
    {{node, 'ns_2@stevenmb.gateway.2wire.net', rest},
         [{'_ver', {0, 0, 0}},
          {port, 8081}
         ]}.
    {{node, 'ns_2@stevenmb.hsd1.ca.comcast.net', rest},
         [{'_ver', {0, 0, 0}},
          {port, 8081}
         ]}.
    {{node, 'ns_2@stevenmb.local', rest},
         [{'_ver', {0, 0, 0}},
          {port, 8081}
         ]}.

Let's keep going, as there are more "per-node" entries to handle more
port conflicts...

Do the same for the "port_servers" key.  For example...

    {port_servers,
      [{'_ver', {0, 0, 0}},
       {memcached, "./memcached",
        [
         "-E", "engines/default_engine.so",
         "-p", "11212"
         ],
        [{env, [{"MEMCACHED_CHECK_STDIN", "thread"},
                {"ISASL_PWFILE", "/tmp/isasl.pw"} % Also isasl_path above.
               ]}]
       }
      ]}.
    {{node, 'ns_2@stevenmb.gateway.2wire.net', port_servers},
      [{'_ver', {0, 0, 0}},
       {memcached, "./memcached",
        [
         "-E", "engines/default_engine.so",
         "-p", "11222"
         ],
        [{env, [{"MEMCACHED_CHECK_STDIN", "thread"},
                {"ISASL_PWFILE", "/tmp/isasl.pw"} % Also isasl_path above.
               ]}]
       }
      ]}.

Above, ns_1 will start a memcached running on port 11212 since that's
the default setting; and ns_2 will start a memcached running on port
11222.

And, the same for your pools port number.  This one is a little
special, where the per-node overrides are inside the nested value.

So, instead of the default config...

    {pools, [
      {'_ver', {0, 0, 0}},
      {"default", [
        {port, 11213},
        {buckets, [
          {"default", [
            {auth_plain, undefined},
            {size_per_node, 64} % In MB.
          ]}
        ]}
      ]}
    ]}.

You will make it instead look like, adding per-node port overrides
inside the value.

    {pools, [
      {'_ver', {0, 0, 0}},
      {"default", [
        {port, 11213},
        {{node, 'ns_2@stevenmb.gateway.2wire.net', port}, 11223},
        {{node, 'ns_2@stevenmb.hsd1.ca.comcast.net', port}, 11223},
        {{node, 'ns_2@stevenmb.local', port}, 11223},
        {buckets, [
          {"default", [
            {auth_plain, undefined},
            {size_per_node, 64} % In MB.
          ]}
        ]}
      ]}
    ]}.

* * * * *
Copyright (c) 2011, Couchbase, Inc.

