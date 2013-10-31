#!/usr/bin/ruby

require 'restclient'
require 'json'
require 'pp'
require 'active_support'
require 'cgi'
require 'thread'
require 'test/unit'

RestClient.log = RestClient.create_log 'stdout'

# monkey-patch RestClient for more detailed response logging
class RestClient::Request
  def log_response res
    return unless RestClient.log

    size = @raw_response ? File.size(@tf.path) : (res.body.nil? ? 0 : res.body.size)
    if !@raw_response && size > 0 && size < 1024
      RestClient.log << "# => #{res.code} #{res.class.to_s.gsub(/^Net::HTTP/, '')} | #{(res['Content-type'] || '').gsub(/;.*$/, '')} #{size} bytes:#{res.body}\n"
    else
      RestClient.log << "# => #{res.code} #{res.class.to_s.gsub(/^Net::HTTP/, '')} | #{(res['Content-type'] || '').gsub(/;.*$/, '')} #{size} bytes\n"
    end
  end
end

$username = 'Administrator'
$password = "asdasd"

require 'ostruct'
$opts = OpenStruct.new({
                         :quota => 900,
                         :quota_given => true,
                         :replicas => 0,
                         :no_default_bucket => true})


module Methods
  def req!(method, path, payload = nil, headers = nil)
    base_url = Thread.current[:base_url] || $base_url
    opts = {
      :method => method, :url => base_url + path, :payload => payload, :headers => headers || {}
    }
    if $username
      opts[:user] = $username
      opts[:password] = $password
    end
    RestClient::Request.execute(opts)
  end

  def post!(path, payload, headers = nil)
    req!(:post, path, payload, headers)
  end

  def put!(path, payload, headers = nil)
    req!(:put, path, payload, headers)
  end

  def get!(path, headers = nil)
    req!(:get, path, nil, headers)
  end

  def getj!(path, headers = nil)
    JSON.parse(get!(path, headers).body)
  end

  def build_base_uri(hostname)
    hostname += ":8091" unless hostname =~ /:/
    "http://#{hostname}"
  end

  def set_node!(hostname)
    $base_url = build_base_uri(hostname)
  end

  def switching_node(hostname)
    old_base = $base_url
    set_node!(hostname)
    yield
  ensure
    $base_url = old_base
  end

  def setup_node!(hostname, no_default_bucket = $opts.no_default_bucket)
    switching_node(hostname) do
      # wait_rebalancing
      quota = $opts.quota
      if $opts.quota_given
        post!("/pools/default",
              :memoryQuota => quota)
      end
      unless no_default_bucket
        post!("/pools/default/buckets",
              :name => "default",
              :ramQuotaMB => $opts.sane_default_bucket ? quota/2 : quota,
              :authType => 'sasl',
              :saslPassword => '',
              :replicaNumber => $opts.replicas.to_s)
      end
      post!("/settings/web", {:port => "SAME", :username => $username, :password => $password})
    end
  end

  def each_possible_node
    port = 9000
    while true
      yield "127.0.0.1:#{port}"
      port += 1
    end
  end

  def poll_condition
    while true
      break if yield
      sleep 0.02
    end
  end

  def discover_nodes!
    good_nodes = []
    each_possible_node do |host|
      set_node! host
      begin
        get! "/pools"
        good_nodes << host
      rescue Exception
        break
      end
    end
    $all_nodes = good_nodes
  end

  def do_every_node!
    $all_nodes.each do |host|
      set_node! host
      yield
    end
  end

  def uncluster_everything!
    threads = $all_nodes.map do |host|
      Thread.new do
        Thread.current[:base_url] = build_base_uri(host)
        uuid_before = getj!("/pools")["uuid"]
        post!("/controller/ejectNode",
              :otpNode => "zzzzForce")
        poll_condition do
          (getj!("/pools")["uuid"] != uuid_before) rescue false
        end
      end
    end
    threads.each(&:join)
    nil
  end

  def add_node! node, cluster_node
    switching_node cluster_node do
      post!("/controller/addNode",
            :user => $username,
            :password => $password,
            :hostname => node)
    end
  end
end

self.send(:extend, Methods)

discover_nodes!

puts "discovered: #{$all_nodes}"

class TestGroups < Test::Unit::TestCase
  include Methods

  def all
    $all_nodes
  end

  def setup
    uncluster_everything!
    assert(all.size >= 2)
    setup_node! all.first
    set_node! all.first
  end

  def teardown
    $base_url = "127.0.0.1:666677"
  end

  def cluster_two!
    add_node! all.last, all.first
    @hostnames = [all.first, all.last].map do |n|
      ni = switching_node(n) {getj!("/nodes/self")}
      ni["hostname"]
    end
  end

  def test_basic
    cluster_two!

    server_groups = getj! "/pools/default/serverGroups"
    groups = server_groups["groups"]
    assert groups
    assert groups.size == 1
    g = groups.first
    assert "Group 1", g["name"]
    assert_equal "/pools/default/serverGroups/0", g["uri"]
    nodes = g["nodes"]
    assert_equal 2, g["nodes"].size
    group_hostnames = nodes.map {|ni| ni["hostname"]}.sort
    assert_equal @hostnames.sort, group_hostnames
  end

  def test_group_ops
    post! "/pools/default/serverGroups", :name => "group 2"
    server_groups = getj!("/pools/default/serverGroups")["groups"]
    assert_equal(["Group 1", "group 2"], server_groups.map {|g| g["name"]})

    second_group = server_groups.detect {|g| g["name"] == "group 2"}["uri"]

    put!("/pools/default/serverGroups/0", :name => "group renamed")

    server_groups = getj!("/pools/default/serverGroups")["groups"]

    assert_equal(["group 2", "group renamed"], server_groups.map {|g| g["name"]}.sort)

    assert_equal("group renamed", server_groups.detect {|g| g["uri"] = "/pools/default/serverGroups/0"}["name"])

    assert_raises RestClient::ResourceNotFound do
      put!("/pools/default/serverGroups/nonexistant", :name => "group renamed")
    end

    assert_raises RestClient::ResourceNotFound do
      post!("/pools/default/serverGroups/0", :name => "group 2")
    end

    assert_raises RestClient::BadRequest do
      put!("/pools/default/serverGroups/0", :name => "group 2")
    end

    req!(:delete, second_group)

    server_groups = getj! "/pools/default/serverGroups"
    assert_equal(["group renamed"], server_groups["groups"].map {|g| g["name"]})

    assert_equal 1, server_groups["groups"].size
    assert_equal "/pools/default/serverGroups/0", server_groups["groups"][0]["uri"]
  end

  def test_simple_move
    post! "/pools/default/serverGroups", :name => "group 2"
    server_groups = getj!("/pools/default/serverGroups")

    assert_raises RestClient::BadRequest do
      put! server_groups["uri"], [].to_json
    end

    assert_raises RestClient::Conflict do
      baduri = server_groups["uri"] + "1"
      put! baduri, [].to_json
    end

    assert_raises RestClient::BadRequest do
      new_server_groups = JSON.parse(server_groups.to_json)
      new_server_groups["groups"].each {|g| g["nodes"] = []}
      put! new_server_groups["uri"], new_server_groups.to_json
    end

    new_server_groups = JSON.parse(server_groups.to_json)
    group_2 = new_server_groups["groups"].detect {|g| g["name"] == "group 2"}
    group_1 = (new_server_groups["groups"] - [group_2]).first

    assert_equal 1, group_1["nodes"].size
    assert_equal 0, group_2["nodes"].size

    group_2["nodes"].concat(group_1["nodes"])
    group_1["nodes"] = []

    put! new_server_groups["uri"], new_server_groups.to_json
    new_server_groups = getj!("/pools/default/serverGroups")
    group_2 = new_server_groups["groups"].detect {|g| g["name"] == "group 2"}
    group_1 = (new_server_groups["groups"] - [group_2]).first

    assert_equal 0, group_1["nodes"].size
    assert_equal 1, group_2["nodes"].size
    assert_not_equal new_server_groups["uri"], server_groups["uri"]
  end

  def test_add_to_group
    post! "/pools/default/serverGroups", :name => "group 2"
    post! "/pools/default/serverGroups", :name => "group 3"
    post! "/pools/default/serverGroups", :name => "group 4"

    server_groups = getj!("/pools/default/serverGroups")

    group_3_info = server_groups["groups"].detect {|g| g["name"] == "group 3"}

    assert_equal(group_3_info["uri"] + "/addNode", group_3_info["addNodeURI"])

    assert_raises RestClient::ResourceNotFound do
      post!(group_3_info["addNodeURI"] + "nonexistant",
            :user => $username,
            :password => $password,
            :hostname => all[1])
    end

    post!(group_3_info["addNodeURI"],
          :user => $username,
          :password => $password,
          :hostname => all[1])

    add_node! all.last, all.first


    all_mapped = all.map do |n|
      ni = switching_node(n) {getj!("/nodes/self")}
      ni["hostname"]
    end

    server_groups = getj!("/pools/default/serverGroups")

    expec = {
      "Group 1" => [all_mapped.first, all_mapped.last].sort,
      "group 2" => [],
      "group 3" => [all_mapped[1]],
      "group 4" => []
    }

    actual = server_groups["groups"].inject({}) do |h, g|
      h[g["name"]] = g["nodes"].map {|ni| ni["hostname"]}.sort
      h
    end

    assert_equal expec, actual
  end

  def test_bad_group_reassign
    post! "/pools/default/serverGroups", :name => "group 2"
    post! "/pools/default/serverGroups", :name => "group 3"
    post! "/pools/default/serverGroups", :name => "group 4"

    server_groups = getj!("/pools/default/serverGroups")

    group_3_info = server_groups["groups"].detect {|g| g["name"] == "group 3"}

    assert_equal(group_3_info["uri"] + "/addNode", group_3_info["addNodeURI"])

    post!(group_3_info["addNodeURI"],
          :user => $username,
          :password => $password,
          :hostname => all[1])

    add_node! all.last, all.first

    server_groups = getj!("/pools/default/serverGroups")

    bad_groups1 = JSON.parse(server_groups.to_json)
    bad_groups1["groups"].detect {|g| g["name"] == "Group 1"}["nodes"].pop

    begin
      put! bad_groups1["uri"], bad_groups1.to_json
      flunk
    rescue RestClient::BadRequest => exc
      response = JSON.parse(exc.response)
      assert_equal 2, response.size
      assert_equal "Bad input", response[0]
      stuff = response[1]
      expected_stuff = bad_groups1["groups"].map do |g|
        {
          "uri" => g["uri"],
          "name" => g["name"],
          "nodeNames" => g["nodes"].map {|ni| ni["otpNode"]}
        }
      end
      assert_equal expected_stuff, stuff
    end
  end

  def test_default_group
    add_node! all[1], all.first

    post! "/pools/default/serverGroups", :name => "group 2"
    server_groups = getj!("/pools/default/serverGroups")
    group_2 = server_groups["groups"].detect {|g| g["name"] == "group 2"}
    group_1 = server_groups["groups"].detect {|g| g["name"] == "Group 1"}
    assert_equal "/pools/default/serverGroups/0", group_1["uri"]

    assert_equal 2, group_1["nodes"].size

    # not empty yet
    assert_raises RestClient::BadRequest do
      req!(:delete, "/pools/default/serverGroups/0")
    end

    # move nodes to group 2
    group_2["nodes"] = group_1["nodes"]
    group_1["nodes"] = []

    put! server_groups["uri"], server_groups.to_json

    # verify move of nodes
    server_groups = getj!("/pools/default/serverGroups")
    group_2 = server_groups["groups"].detect {|g| g["name"] == "group 2"}
    group_1 = server_groups["groups"].detect {|g| g["name"] == "Group 1"}
    assert_equal "/pools/default/serverGroups/0", group_1["uri"]

    assert_equal 0, group_1["nodes"].size
    assert_equal 2, group_2["nodes"].size

    # now delete
    req!(:delete, "/pools/default/serverGroups/0")

    # verify lack of default group
    server_groups = getj!("/pools/default/serverGroups")
    group_2 = server_groups["groups"].detect {|g| g["name"] == "group 2"}
    group_1 = server_groups["groups"].detect {|g| g["name"] == "Group 1"}
    assert_nil group_1
    assert_equal 2, group_2["nodes"].size

    assert_equal 1, server_groups["groups"].size

    # see if we can successfully add node after default group is dead
    add_node! all[2], all.first

    server_groups = getj!("/pools/default/serverGroups")
    group_2 = server_groups["groups"].detect {|g| g["name"] == "group 2"}
    assert_equal 3, group_2["nodes"].size
    assert_equal 1, server_groups["groups"].size

    # see if we can create group with same name as (dead) default group
    post! "/pools/default/serverGroups", :name => "Group 1"
    server_groups = getj!("/pools/default/serverGroups")
    group_1 = server_groups["groups"].detect {|g| g["name"] == "Group 1"}
    assert_not_equal "/pools/default/serverGroups/0", group_1["uri"]
    assert_equal 0, group_1["nodes"].size
  end
end

