require 'rest_client'
require 'json'
require 'socket'
require 'fileutils'

PREFIX = "cucumberCluster"

def dbg(m)
  # p(m)
end

module Kernel
  def poll_for_condition(timeout = 10, fail_unless_ok = true)
    start = Time.now.to_f

    ok = false
    begin
      break if (ok = yield)
      sleep 0.1
    end while (Time.now.to_f - start) < timeout

    unless ok
      if fail_unless_ok
        # puts "Timeout!!"
        # STDIN.gets
        raise "Timeout hit while waiting for condition"
      end
    end
    ok
  end
end

class ClusterConfig
  include Test::Unit::Assertions
  extend Test::Unit::Assertions

  @@active_cluster = nil
  def self.active_cluster(prefix = nil)
    rv = @@active_cluster
    if prefix
      assert_equal prefix, @@active_cluster.prefix
    end
    rv
  end

  attr_reader :size
  attr_reader :configs
  attr_reader :prefix
  attr_reader :num_buckets

  def initialize(size, prefix = PREFIX, num_buckets = 0)
    @size = size
    @prefix = prefix
    @num_buckets = num_buckets
    @cluster_ptys = []
  end

  # ------------------------------------------------------

  def node_index(node_label)
    node_label[0] - 65 # 'A' == 65.
  end

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

  def node_pid(node_label)
    i = node_index(node_label)
    pid, ports = @cluster_ptys[i]
    pid
  end

  def node_kill(node_label)
    i = node_index(node_label)
    pid, ports = @cluster_ptys[i]

    Process.kill("KILL", pid)
    Process.wait(pid)

    wait_down_ports(ports)

    @cluster_ptys[i] = []
  end

  def node_resurrect(node_label)
    i = node_index(node_label)
    pid, ports = @cluster_ptys[i]
    assert !pid
    @cluster_ptys[i] = start_single_node(i)
    wait_up_ports(@cluster_ptys[i][-1])
    sleep 3
  end

  # ------------------------------------------------------

  def start_single_node(i)
    ports = [12000+i*2,12000+i*2+1,9000+i]

    wait_down_ports(ports, -1)

    reader, writer = IO.pipe
    pid = fork do
      ENV['RELIABLE_START_FD'] = reader.fileno.to_s
      time = Time.now.utc
      tstamp = "%04d%02d%02dT%02d%02d%02d" % [time.year, time.month, time.day, time.hour, time.min, time.sec]
      STDOUT.reopen("tmp/log_#{tstamp}_#{(?A+i).chr}", "w")
      STDERR.reopen(STDOUT)

      Process.setpgid(0,0)
      exec "./test/orphaner.rb ./start_shell.sh -noshell -name n_#{i}@127.0.0.1 -ns_server ns_server_config \"#{prefix}_config\" </dev/null"
    end
    reader.close
    writer.write('O')
    writer.close
    # puts "started one process"
    # gets
    [pid, ports]
  end

  def start!
    if @@active_cluster
      @@active_cluster.stop!
    end

    system "./test/gen_cluster_scripts.rb #{size} 0 #{prefix}"
    FileUtils.rm_rf './config'

    @cluster_ptys = []

    ports_to_wait = []

    begin
      size.times do |i|
        pid, ports = rv = start_single_node(i)
        ports_to_wait.concat(ports)
        @cluster_ptys << rv
      end

      wait_up_ports(ports_to_wait)
    rescue Exception
      stop!
      raise
    end

    # we need some extra time to settle some things (free memory at least)
    sleep 5
  end

  def wait_up_ports(ports_to_wait, timeout = 10)
    poll_for_condition(timeout) do
      tmp = ports_to_wait
      ports_to_wait = []
      tmp.each do |p|
        begin
          TCPSocket.new('127.0.0.1',p).close
        rescue Errno::ECONNREFUSED
          ports_to_wait << p
        end
      end
      ports_to_wait.empty?
    end
  end

  def wait_down_ports(wait_ports, timeout = 120)
    poll_for_condition(timeout) do
      wait_ports = wait_ports.select do |p|
        begin
          TCPSocket.new('127.0.0.1', p).close
          true
        rescue Exception => exc
          false
        end
      end
      wait_ports.empty?
    end
  end

  def stop!
    # puts "before stop"
    # gets

    wait_ports = []
    @cluster_ptys.each do |(pid, ports)|
      next unless pid
      Process.kill("KILL", pid)
      Process.wait(pid)
      wait_ports.concat(ports)
    end
    @cluster_ptys.clear

    wait_down_ports(wait_ports)

    @@active_cluster = nil if self == @@active_cluster
  end

  def self.activate!(*args)
    config = self.new(*args)
    config.start!
    @@active_cluster = config
  end

  def self.stop_active!(prefix = PREFIX)
    cluster = ClusterConfig.active_cluster(prefix)
    assert cluster

    assert_equal prefix, cluster.prefix

    # puts "before stopping"
    # gets
    cluster.stop
    # puts "stopped cluster"
    # gets
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
    RestClient.diag do
      x = RestClient.post("http://localhost:#{rest_port(ejecter)}" +
                          "/controller/ejectNode",
                          "otpNode" => ejectee_node_info['otpNode'])
      dbg "ejectNode #{ejectee}, on #{ejecter}...done #{x}"
    end
  rescue RestClient::ServerBrokeConnection => e
    if ejectee == ejecter
      # This is expected, as the leaver resets.
      dbg "ejectNode #{ejectee}, on #{ejecter}...end"
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

  d = JSON.parse(RestClient.diag_get("http://localhost:#{rest_port(node_to_ask)}" +
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
    d = JSON.parse(RestClient.diag_get("http://localhost:#{rest_port(x)}/pools/default").body)
    assert d['nodes'].length == 1
  end
end

def assert_cluster_fully_joined()
  assert $node_labels
  assert $node_labels.length > 1

  $node_labels.each do |x|
    d = JSON.parse(RestClient.diag_get("http://localhost:#{rest_port(x)}/pools/default").body)
    assert d['nodes'].length == $node_labels.length, "node #{x} is not aware of all nodes: #{d}"
  end
end

# ------------------------------------------------------

def rest_port(node_label)
  ClusterConfig.active_cluster.rest_port(node_label)
end

def direct_port(node_label)
  ClusterConfig.active_cluster.direct_port(node_label)
end

def proxy_port(node_label)
  ClusterConfig.active_cluster.proxy_port(node_label)
end

def node_pid(node_label)
  ClusterConfig.active_cluster.node_pid(node_label)
end

def node_kill(node_label)
  ClusterConfig.active_cluster.node_kill(node_label)
end

# ------------------------------------------------------

def node_resurrect(node_label, prefix = PREFIX)
  ClusterConfig.active_cluster(prefix).node_resurrect(node_label)
end

# ------------------------------------------------------

def RestClient.diag
  yield
rescue RestClient::BadRequest => exc
  puts "exc.response: #{exc.response.body.inspect}"
  raise exc
end

def RestClient.diag_get(*args)
  RestClient.diag do
    RestClient.get(*args)
  end
end

def bucket_create(node, bucket_to_create, params = {})
  RestClient.diag do
    RestClient.post("http://localhost:#{rest_port(node)}/pools/default/buckets",
                    "name" => bucket_to_create,
                    "cacheSize" => params[:cacheSize] || "2")
  end
  sleep(0.5)
end

def bucket_info(node, bucket)
  r = RestClient.diag do
    RestClient.get("http://localhost:#{rest_port(node)}/pools/default/buckets/#{bucket}")
  end
  return unless r
  JSON.parse(r.body)
end

def node_rpc(node, method, path, *params)
  url = "http://localhost:#{rest_port(node)}" + path
  rv = RestClient.send(method, url, *params)

  if rv.body.size != 0
    JSON.parse(rv.body)
  end
end

def node_get(node, path, *params)
  node_rpc(node, :get, path, *params)
end
