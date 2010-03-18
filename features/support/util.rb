require 'rest_client'
require 'json'

PREFIX = "cucumberCluster"

def dbg(m)
  # p(m)
end

def cluster_stop(prefix = nil)
  prefix ||= PREFIX
  if File.exists?("./#{prefix}_stop_all.sh")
    dbg "stopping cluster..."
    `./#{prefix}_stop_all.sh`
    FileUtils.rm_f Dir.glob("./tmp/node_*.pid")
    sleep(2.0)
  end
end

def cluster_prep(size, prefix = nil)
  prefix ||= PREFIX
  cluster_stop()
  `./test/gen_cluster_scripts.rb #{size} 0 #{prefix}`
end

def cluster_start(prefix = nil)
  prefix ||= PREFIX
  pid = fork do # In the child process...
               FileUtils.rm_rf Dir.glob("./config/n_*")
               `./#{prefix}_start_all.sh`
               exit
             end
  if pid
    # In the parent process...
    dbg "starting cluster..."
    sleep(3.0)
  end
end

# ------------------------------------------------------

def cluster_join(joiner, joinee)
  begin
    RestClient.post("http://localhost:#{rest_port(joiner)}/node/controller/doJoinCluster",
                    "clusterMemberHostIp" => "127.0.0.1",
                    "clusterMemberPort" => rest_port(joinee),
                    "user" => "",
                    "password" => "")
    sleep(10.0)
  rescue RestClient::ServerBrokeConnection => ok
    # This is expected, as the joiner to might restart webservices when joining.
    sleep(10.0)
  rescue Exception => x
    dbg "doJoinCluster exception #{x}"
    raise x
  end
end

def cluster_eject(ejectee, ejecter = nil)
  ejecter ||= ejectee

  ejectee_node_info = node_info(ejectee, ejecter)

  assert ejectee_node_info
  assert ejectee_node_info['otpNode']

  begin
    RestClient.post("http://localhost:#{rest_port(ejecter)}" +
                    "/controller/ejectNode",
                    "otpNode" => ejectee_node_info['otpNode'])
  rescue RestClient::ServerBrokeConnection => e
    if ejectee == ejecter
      # This is expected, as the leaver resets.
      true
    else
      raise e
    end
  end

  sleep(5.0)
end

# ------------------------------------------------------

def node_info(node_target, node_to_ask = nil)
  node_to_ask ||= node_target

  d = JSON.parse(RestClient.get("http://localhost:#{rest_port(node_to_ask)}" +
                                "/pools/default").body)
  assert d
  assert d['nodes']

  d['nodes'].find {|node_info|
    node_info['ports']['direct'] == direct_port(node_target)
  }
end

# ------------------------------------------------------

def assert_cluster_not_joined()
  assert $node_labels
  assert $node_labels.length > 1

  $node_labels.each do |x|
    d = JSON.parse(RestClient.get("http://localhost:#{rest_port(x)}/pools/default").body)
    assert d['nodes'].length == 1
  end
end

def assert_cluster_fully_joined()
  assert $node_labels
  assert $node_labels.length > 1

  $node_labels.each do |x|
    d = JSON.parse(RestClient.get("http://localhost:#{rest_port(x)}/pools/default").body)
    assert d['nodes'].length == $node_labels.length, "node #{x} is not aware of all nodes: #{d}"
  end
end

# ------------------------------------------------------

def node_pid(node_label)
  IO.read("./tmp/node_#{node_index(node_label)}.pid").chomp
end

def node_kill(node_label)
  dbg "killing node #{node_label}..."
  `kill #{node_pid(node_label)}`
  sleep(0.1)
end

def node_start(node_label, prefix = nil)
  prefix ||= PREFIX
  node_i = node_index(node_label)
  dbg "starting node #{node_label} (#{node_i})..."
  pid = fork do # In the child process...
               `./start_shell.sh -name n_#{node_i}@127.0.0.1 -noshell -ns_server ns_server_config \\"#{prefix}_config\\" -ns_server pidfile \\"./tmp/node_#{node_i}.pid\\"`
               exit
             end
  if pid
    # In the parent process...
    sleep(8.0)
  end
end

def node_index(node_label)
  node_label[0] - 65 # 'A' == 65.
end

# ------------------------------------------------------

def rest_port(node_label) # Ex: "A"
  9000 + node_index(node_label)
end

def direct_port(node_label) # Ex: "A"
  12000 + (node_index(node_label) * 2)
end

def proxy_port(node_label)
  direct_port(node_label) + 1
end

# ------------------------------------------------------

def bucket_create(node, bucket_to_create, params = {})
  RestClient.post("http://localhost:#{rest_port(node)}/pools/default/buckets",
                  "name" => bucket_to_create,
                  "cacheSize" => params[:cacheSize] || "2")
  sleep(0.1)
end

def bucket_info(node, bucket)
  r = RestClient.get("http://localhost:#{rest_port(node)}/pools/default/buckets/#{bucket}")
  if r
    return JSON.parse(r.body)
  end
  nil
end
