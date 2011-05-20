#!/usr/bin/env ruby

# Script to help setup a manual test of fast-forward-map.
#
# Prerequisites...
#
# - A medium-sized cluster -- 10 or more nodes, already joined.
#   RightScale deployments were okay for this.
#
# This script helps grab that cluster's server-list and
# compute some keys that will be moved during a rebalancing.
#
# You should follow the emitted steps to reset the cluster back to the
# single, start node, and follow the remaining steps.
#
u = 'Administrator'
p = 'password'

# The node to be treated as the first or start node of the cluster...
#
start = ARGV[0] || '50.18.65.236,10.168.81.238' # public-ip,private-ip

pub_start = start.split(',')[0]
pri_start = start.split(',')[-1]

keys = "a b c d e f g h i j k l m".split(" ")

bin = "/opt/membase/bin"
cup = "-c #{pub_start} -u #{u} -p #{p}"

servers = `#{bin}/membase server-list #{cup}`
servers = servers.split("\n").map {|x| x.split(' ')[0].sub('ns_1@', '')}.sort()
others  = servers - [pri_start]

c = "#{bin}/membase rebalance #{cup}"
others.each {|x| c = c + " --server-remove=#{x}:8091"}
remove_others = c

c = "#{bin}/membase rebalance #{cup}"
others.each {|x| c = c + " --server-add=#{x}:8091"}
add_others = c

vbt = "curl http://#{u}:#{p}@#{pub_start}:8091/pools/default/buckets/default" +
      " | #{bin}/vbuckettool - #{keys.join(' ')}"

# The vbuckettool output lines look like...
#
# key: a vBucketId: 183 master: 10.161.27.203:11210 replicas: 10.166.111.144:11210
#
# mkeys will look like an array of ["key", "host"].
#
mkeys = `#{vbt}`
mkeys = mkeys.split("\n").
  map {|x| [x.split(' ')[1], x.split(' ')[5].split(':')[0]] }.
  select {|x| x[1] != pri_start }

# ----------------------------------------------

print "public start node: #{pub_start}\n"
print "private start node: #{pri_start}\n"
print "-------\n"

print "0) fyi, here are all the servers in the cluster...\n"
print servers.join("\n")
print "\n-------\n"

print "1) first, shrink the cluster back down to the one, start node...\n"
print "remove_others:\n#{remove_others}\n"
print "\n-------\n"

print "2) next, insert some data...\n"
keys.each do |k|
  print "printf \"set #{k} 0 0 1\\r\\n#{k}\\r\\n\" | nc #{pub_start} 11211\n"
end
print "\n-------\n"

print "3) fyi, these are the keys that will move...\n"
print mkeys.join("\n")
print "\n-------\n"

print "4) fyi, here are the inital cmd_get's...\n"
servers.each do |s|
  print "#{bin}/mbstats #{s}:11210 all | grep cmd_get\n"
end
print "\n-------\n"

print "5) next, rebalance back in all the nodes...\n"
print "add_others:\n#{add_others}\n"
print "\n-------\n"

print "5.1) concurrently with #5, do some get's (count how many of these you do)...\n"
keys.each do |k|
  print "printf \"get #{k}\\r\\n\" | nc #{pub_start} 11211\n"
end
print "\n-------\n"

print "6) then, these cmd_get's should be non-zero...\n"
([pub_start] + (mkeys.map {|x| x[1]})).each do |s|
  print "#{bin}/mbstats #{s}:11210 all | grep cmd_get\n"
end
print "\n-------\n"

print "7) and, these cmd_get's should be 0...\n"
(others - (mkeys.map {|x| x[1]})).each do |s|
  print "#{bin}/mbstats #{s}:11210 all | grep cmd_get\n"
end
print "\n-------\n"

