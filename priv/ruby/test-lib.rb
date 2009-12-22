require 'rubygems'
require 'socket'
require 'firewatir'
require 'test/unit'
require 'active_support/test_case'

module Selectors
  def switch_overview
    @b.link(:id, 'switch_overview')
  end

  def switch_alerts
    @b.link(:id, 'switch_alerts')
  end

  def index_loc!
    @b.goto('http://localhost:8080/index.html')
  end
end

module TestLib
  module_function

  def wait_socket(port, timeout=10)
    interval = 0.01
    times = (timeout.to_f/interval).ceil

    last_exc = nil

    times.times do
      begin
        s = TCPSocket.new('127.0.0.1', port)
        s.close rescue nil
        return
      rescue Errno::ECONNREFUSED
        last_exc = $!
      end
      sleep interval
    end

    raise last_exc
  end

  def ensure_erlang
    return if @@erlang_ready
    @@erlang_job.join
    @@erlang_ready =  true
    @@erlang_job = nil
  end

  def start
    at_exit do
      close_windows!
    end

    @@gdb_done = false
    @@erlang_ready = false
    if ENV['RUN_ERLANG']
      @@erlang_job = Thread.new do
        $erlang_pid = fork do
          Process::setpgrp
          Dir.chdir(File.dirname(__FILE__)+"/../../")
          exec "./start.sh -noshell </dev/null >erlang-out 2>&1"
        end
        wait_socket(8080)
        puts "Spawned Erlang (pid is #{$erlang_pid})"

        at_exit do
          Process::kill(9, -$erlang_pid)
          puts "killed erlang"
        end
      end
    else
      @@erlang_ready = true
    end

    @@windows = []
  end

  def close_windows!
    return if ENV['KEEP_WINDOWS']
    return unless @@windows.first

    # workaround some bugs in firewatir
    @@windows.first.js_eval <<HERE
;(function () {
  var list = getWindows();
  for (var i in list) {
    try {list[i].close();} catch (e) {}
  }
})();
HERE

    if RUBY_PLATFORM =~ /darwin|mac os/i
      %x{ osascript -e 'tell application "Firefox" to quit' }
    end
  end

  def create_window
    rv = FireWatir::Firefox.new

    unless @@gdb_done
      @@gdb_done = true

      begin
        require 'gdb'
        GDB.force_socket_nodelay($jssh_socket)
      rescue Exception
        # ignore
      end
    end

    @@windows << rv
    rv
  end

  def release_window(w)
    if @@windows.size > 1
      w.close
    else
      w.goto("about:blank")
    end
  end
end

TestLib.start

class TestCase < ActiveSupport::TestCase
  include Selectors

  def setup
    @b = TestLib::create_window
    TestLib::ensure_erlang
  end
  def teardown
    if @test_passed
      TestLib::release_window(@b)
    end
  end
end
