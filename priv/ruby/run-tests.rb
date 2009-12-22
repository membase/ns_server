#!/usr/bin/env ruby

require 'test/unit'

tests = Dir.chdir(File.dirname(__FILE__)) do
  Dir['t/*.rb'].map {|n| File.expand_path(n)}
end

tests.each {|path| load(path)}

Test::Unit::AutoRunner.run
