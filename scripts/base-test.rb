require_relative 'rest-methods'

self.send(:extend, RESTMethods)

discover_nodes!

puts
puts "Nodes discovered: #{$all_nodes}"
