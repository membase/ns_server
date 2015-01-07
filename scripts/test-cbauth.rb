#!/usr/bin/ruby

require 'minitest/autorun'
require_relative 'base-test'


class TestCBAuth < Minitest::Test
  include Methods

  def all
    $all_nodes
  end

  def setup
    uncluster_everything!
    # this is sadly needed so far
    sleep 4
    setup_node! all.first
    set_node! all.first
    all[1..-1].each {|n| add_node! n, all.first}
    rebalance!
  end

  def teardown
    $base_url = nil
  end

  def print_cmd! cmd
    puts
    puts "========================================================="
    puts cmd
    puts "========================================================="
  end

  def rebalance!
    nodes = all.map do |n|
      switching_node(n) {getj!("/nodes/self")}["otpNode"]
    end
    print_cmd! "rebalance"
    post!("/controller/rebalance",
          :knownNodes => nodes.join(","),
          :ejectedNodes => "")
    task = []
    poll_condition do
      task = getj!("/pools/default/tasks")[0]
      task["status"] == "notRunning"
    end
    assert_equal nil, task["errorMessage"]
  end

  def create_bucket! name, password = ""
    print_cmd! "create_bucket " + name
    post!("/pools/default/buckets",
          :name => name,
          :threadsNumber => 3,
          :replicaIndex => 1,
          :replicaNumber => 1,
          :ramQuotaMB => 100,
          :bucketType => "membase",
          :authType => "sasl",
          :saslPassword => password)
  end

  def sh(*args)
    puts(args.join(" "))
    system(*args) || raise
  end

  def test_basic_stuff
    create_bucket! "other", "apassword"
    create_bucket! "default"
    create_bucket! "foo", ""

    puts post!("/diag/eval", 'ns_orchestrator:ensure_janitor_run("default")')
    puts post!("/diag/eval", 'ns_orchestrator:ensure_janitor_run("other")')
    puts post!("/diag/eval", 'ns_orchestrator:ensure_janitor_run("foo")')

    sh "go build -o /tmp/cbauth-example github.com/couchbase/cbauth/cmd/cbauth-example"
    sh "go build -o /tmp/multi-bucket-demo github.com/couchbase/cbauth/cmd/multi-bucket-demo"

    base_url = "http://#{all.first}"

    ENV["NS_SERVER_CBAUTH_URL"] = base_url + "/_cbauth"
    ENV["NS_SERVER_CBAUTH_RPC_URL"] = base_url + "/cbauthtest"
    ENV["NS_SERVER_CBAUTH_USER"] = $username
    ENV["NS_SERVER_CBAUTH_PWD"] = $password

    sh "/tmp/multi-bucket-demo --serverURL=#{base_url}"
    sh "/tmp/multi-bucket-demo --serverURL=#{base_url} --bucketName=default"
    sh "/tmp/multi-bucket-demo --serverURL=#{base_url} --bucketName=other"

    puts "waiting for :44443 to be free"
    poll_condition do
      (TCPSocket.new("127.0.0.1", 44443).tap(&:close) && false) rescue true
    end
    puts ":44443 is free"

    IO.popen("/tmp/cbauth-example --listen=127.0.0.1:44443 --mgmtURL=#{base_url}", "r+") do |f|
      poll_condition do
        TCPSocket.new("127.0.0.1", 44443).tap(&:close) rescue false
      end
      switching_node("127.0.0.1:44443") do
        getj! "/h/#{all.last}/other"
        getj! "/bucket/other"
        switching_username nil do
          getj! "/bucket/default"
        end
      end
      f.close_write
      f.read
    end
  end
end
