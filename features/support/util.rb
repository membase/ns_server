require 'rest_client'
require 'json'

PREFIX = "cucumberCluster"

def cluster_stop(prefix = nil)
  prefix ||= PREFIX
  if File.exists?("./#{prefix}_stop_all.sh")
    p "stopping cluster..."
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
    p "starting cluster..."
    sleep(3.0)
  end
end

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
    p "doJoinCluster exception #{x}"
    raise x
  end
end

def cluster_eject(ejectee, ejecter = nil)
  ejecter ||= ejectee

  d = JSON.parse(RestClient.get("http://localhost:#{rest_port(ejecter)}" +
                                "/pools/default"))

  assert d
  assert d['nodes']

  ejectee_node_info = d['nodes'].find {|node_info|
    node_info['ports']['direct'] == direct_port(ejectee)
  }

  assert ejectee_node_info
  assert ejectee_node_info['otpNode']

  begin
    RestClient.post("http://localhost:#{rest_port(ejecter)}" +
                    "/controller/ejectNode",
                    "otpNode" => ejectee_node_info['otpNode'])
    sleep(5.0)
  rescue RestClient::ServerBrokeConnection => e
    if ejectee == ejecter
      # This is expected, as the leaver resets.
      sleep(5.0)
    else
      raise e
    end
  end
end

def assert_cluster_not_joined()
  assert $node_labels
  assert $node_labels.length > 1

  $node_labels.each do |x|
    d = JSON.parse(RestClient.get("http://localhost:#{rest_port(x)}/pools/default"))
    assert d['nodes'].length == 1
  end
end

def assert_cluster_fully_joined()
  assert $node_labels
  assert $node_labels.length > 1

  $node_labels.each do |x|
    d = JSON.parse(RestClient.get("http://localhost:#{rest_port(x)}/pools/default"))
    assert d['nodes'].length == $node_labels.length
  end
end

def rest_port(node_label) # Ex: "A"
  i = node_label[0] - 65 # 'A' == 65.
  9000 + i
end

def direct_port(node_label) # Ex: "A"
  i = node_label[0] - 65 # 'A' == 65.
  12000 + (i * 2)
end

def proxy_port(node_label)
  direct_port(node_label) + 1
end



