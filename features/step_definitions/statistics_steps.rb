require 'memcached'

Given /^default bucket has size (\d+)M$/ do |size|
  node_rpc('A', :delete, '/pools/default/buckets/default')
  bucket_create('A', 'default', :cacheSize => size)
  sleep 1
end

When /^I put (\d+)M of data to default bucket$/ do |size|
  size = size.to_i
  fmt = 'a_%d'
  c = Memcached.new("127.0.0.1:#{direct_port('A')}",
                    :binary_protocol => true,
                    :tcp_nodelay => true)
  begin
    halfmeg = '0123456789ABCDEF' * 32768
    (size*2).times do |i|
      key = fmt % [i]
      c.set(key, halfmeg)
      assert_equal halfmeg, c.get(key)
    end
  ensure
    c.quit rescue nil
  end
end

Then /^I should get (\d+)% cache utilization for ([a-zA-Z_]+) bucket$/ do |percent, name|
  puts "waiting 10 secs for stats aggregator"
  sleep 10
  info = node_get('A', '/pools/default/buckets/default')

  actual_utilization = info['basicStats']['cachePercentUsed']
  assert_in_delta  0.5, actual_utilization, 0.005
end
