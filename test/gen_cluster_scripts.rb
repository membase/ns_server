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

num_nodes.times do |x|
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
end

pools = <<END
{pools, [
  {'_ver', {0, 0, 0}},
  {"default", [
END

num_nodes.times do |x|
  pools = pools + "{{node, 'n_#{x}@127.0.0.1', port}, #{(x * 2) + 12001}},\n"
end

buckets = ""
num_buckets.times do |x|
  buckets = buckets + ",{\"b_#{x}\", [{auth_plain, undefined}, {size_per_node, #{x + 1}}]}\n"
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

# Backwards compatibility for ruby 1.8.6
numbers = []
num_nodes.times { |x| numbers << x }

File.open(prefix + "_start_all.sh", 'w') {|f|

  s=<<EOF
#!/bin/sh

# num_nodes is #{num_nodes}

start_node() {
    echo "Starting $1"

    erl -pa \`find . -type d -name ebin\` \\
        -setcookie nocookie \\
        -run ns_bootstrap \\
        -kernel inet_dist_listen_min 21100 inet_dist_listen_max 21199 \\
        -sasl sasl_error_logger false \\
        -sasl error_logger_mf_dir '"logs"' \\
        -sasl error_logger_mf_maxbytes 10485760 \\
        -sasl error_logger_mf_maxfiles 10 \\
        -- \\
        -no-input \\
        -name $1@127.0.0.1 -noshell \\
        -ns_server ns_server_config \\"cluster_config\\" \\
        -ns_server pidfile \\"tmp/$1.pid\\" &
}

erl -noshell -setcookie nocookie -sname init -run init stop 2>&1 > /dev/null

for node in #{numbers.map{|i| "n_" + i.to_s}.join(" ")}
do
    start_node $node
done
EOF

  f.write s
}

File.open(prefix + "_stop_all.sh", 'w') {|f|

  s=<<EOF
#!/bin/sh
# num_nodes is #{num_nodes}

kill `cat #{numbers.map{|i| "tmp/n_#{i}.pid"}.join(" ")}`
EOF

  f.write s
}

# -------------------------------------------------------

File.chmod 0755, "#{prefix}_start_all.sh", "#{prefix}_stop_all.sh"
