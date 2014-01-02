#!/usr/bin/env ruby

require 'socket'

BIND_PORT = ARGV[0] ? ARGV[0].to_i : 22222

def run_accept_loop(server_sock)
  while true
    client = server_sock.accept
    puts "got client #{client}"
    Thread.new { run_client_loop(client) }
  end
end

def run_client_loop(client)
  puts "starting client loop: #{client}"
  while true
    stuff = client.readpartial(16384)
    puts "#{client}: got #{stuff.inspect}"
    client.write stuff
  end
rescue EOFError
  client.close rescue nil
  puts "ended client: #{client}"
  return
rescue Exception => exc
  puts "got exception: #{exc}"
end

run_accept_loop(TCPServer.new(BIND_PORT))

