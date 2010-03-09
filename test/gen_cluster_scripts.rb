#!/usr/bin/ruby

# Helper script to generate a priv/config file and start/stop scripts
# with num_nodes of unjoined nodes, all running on 127.0.0.1.  For
# example, to get a 100 node setup with 5 extra buckets, try...
#
#   ./gen_priv_config.rb 100 5
#
# The above will generate files like...
#
#   cluster_config
#   cluster_start_all.sh
#   cluster_stop_all.sh
#
# The node names will look like n_0@127.0.0.1, n_1@127.0.0.1, ...
#
# The extra buckets (which are in addition to the usual default
# bucket) will look like b_0, b_1, ...
#
prefix = ARGV[2] || "cluster"

num_nodes = ARGV[0] || "10"
num_nodes = num_nodes.to_i

num_buckets = ARGV[1] || "0"
num_buckets = num_buckets.to_i

nodes = ""

x = 0
while x < num_nodes
  nodes = nodes + <<-END
    {{node, 'n_#{x}@127.0.0.1', rest},
      [{'_ver', {0, 0, 0}},
       {port, #{x + 9000}}]}.
    {{node, 'n_#{x}@127.0.0.1', port_servers},
      [{'_ver', {0, 0, 0}},
       {memcached, "./priv/memcached",
        ["-p", "#{(x * 2) + 12000}",
         "-E", "./priv/engines/bucket_engine.so",
         "-e", "admin=_admin;engine=./priv/engines/default_engine.so;default_bucket_name=default;auto_create=false",
         "-B", "auto"],
        [{env, [{"MEMCACHED_CHECK_STDIN", "thread"},
                {"MEMCACHED_TOP_KEYS", "100"},
                {"ISASL_PWFILE", "./priv/isasl.pw"},
                {"ISASL_DB_CHECK_TIME", "1"}]}]}]}.
    END
  x = x + 1
end

pools = <<END
{pools, [
  {'_ver', {0, 0, 0}},
  {"default", [
END

x = 0
while x < num_nodes
  pools = pools + "{{node, 'n_#{x}@127.0.0.1', port}, #{(x * 2) + 12001}},\n"
  x = x + 1
end

buckets = ""
x = 0
while x < num_buckets
  buckets = buckets + ",{\"b_#{x}\", [{auth_plain, undefined}, {size_per_node, #{x + 1}}]}\n"
  x = x + 1
end

pools = pools + <<END
    {buckets, [
      {"default", [
        {auth_plain, undefined},
        {size_per_node, 2} % In MB.
      ]}
#{buckets}
    ]}
  ]}
]}.
END

# -------------------------------------------------------

File.open(prefix + "_config", 'w') {|f|
  f.write("% num_nodes is #{num_nodes}\n")
  f.write("#{nodes}\n")
  f.write("#{pools}\n")
}

File.open(prefix + "_start_all.sh", 'w') {|f|
  f.write("#!/bin/sh\n")
  f.write("# num_nodes is #{num_nodes}\n")
  x = 0
  while x < num_nodes
    f.write("./start_shell.sh -name n_#{x}@127.0.0.1 -noshell" +
               " -ns_server ns_server_config \\\"#{prefix}_config\\\"" +
               " -ns_server pidfile \\\"./tmp/node_#{x}.pid\\\" </dev/null &\n")
    x = x + 1
  end
}

File.open(prefix + "_stop_all.sh", 'w') {|f|
  f.write("#!/bin/sh\n")
  f.write("# num_nodes is #{num_nodes}\n")
  x = 0
  while x < num_nodes
    f.write("kill `cat ./tmp/node_#{x}.pid`\n")
    x = x + 1
  end
}

# -------------------------------------------------------

`chmod a+x #{prefix}_start_all.sh`
`chmod a+x #{prefix}_stop_all.sh`




