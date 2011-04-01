#!/bin/env ruby

Dir.chdir(File.join(File.dirname(__FILE__), "..", "priv/public"))

print "var AllImages = ["
print(Dir["images/**/*"].select {|p| File.file? p}.map {|p| p.inspect}.join(", "))
puts "];"
