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
#   cluster_run.sh
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

base_direct_port = (ENV['BASE_DIRECT_PORT'] || ENV['BASE_CACHE_PORT'] || "12000").to_i
base_api_port = (ENV['BASE_API_PORT'] || "9000").to_i

nodes = ""

num_nodes.times do |x|
  nodes = nodes + <<-END
    {{node, 'n_#{x + base_api_port - 9000}@127.0.0.1', rest},
      [{'_ver', {0, 0, 0}},
       {port, #{x + base_api_port}}]}.
    {{node, 'n_#{x + base_api_port - 9000}@127.0.0.1', port_servers},
      [{'_ver', {0, 0, 0}},
       {memcached, "./priv/memcached",
        ["-p", "#{(x * 2) + base_direct_port}",
         "-X", "./priv/engines/stdin_term_handler.so",
         "-E", "./priv/engines/bucket_engine.so",
         "-e", "admin=_admin;engine=./priv/engines/ep.so;default_bucket_name=default;auto_create=false"
        ],
        [{env, [{"MEMCACHED_TOP_KEYS", "100"},
                {"ISASL_PWFILE", "./priv/isasl.pw"}, % Also isasl path above.
                {"ISASL_DB_CHECK_TIME", "1"}
               ]},
         use_stdio,
         stderr_to_stdout,
         stream]
       },
       {moxi, "./priv/moxi",
                ["-Z", "port_listen="#{(x * 2) + base_direct_port + 1}",
                 "-z", "auth=,url=http://127.0.0.1:8080/pools/default/bucketsStreaming/default,\#@"
                ],
                [{env, []},
                 use_stdio, stderr_to_stdout, stream]
       }]}.
    END
end

pools = <<END
{memcached, [{'_ver', {0, 0, 0}},
        {port, #{base_direct_port}},
        {admin_user, "_admin"},
        {admin_pass, "_admin"},
        {buckets, ["default"]}]}.

{pools, [
  {'_ver', {0, 0, 0}},
  {"default", [
END

num_nodes.times do |x|
  pools = pools + "{{node, 'n_#{x + base_api_port - 9000}@127.0.0.1', port}, #{(x * 2) + base_direct_port + 1}},\n"
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

numbers = (0...num_nodes).to_a

File.open(prefix + "_run.sh", File::CREAT|File::TRUNC|File::WRONLY, 0755) do |f|
  f.write(<<EOF)
#!/bin/sh

# num_nodes is #{num_nodes}

start_node() {
    echo "Starting $1"

    ./test/orphaner.rb erl -pa \`find . -type d -name ebin\` \\
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
        -ns_server ns_server_config \\"#{prefix}_config\\" &
}

erl -noshell -setcookie nocookie -sname init -run init stop 2>&1 > /dev/null

for node in #{numbers.map{|i| "n_" + (i + base_api_port - 9000).to_s}.join(" ")}
do
    start_node $node
done
echo "Ctrl-C or Ctrl-D to quit"
exec cat
EOF
end
