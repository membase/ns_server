Given /^node (.*) has bucket ([A-Za-z_]+)$/ do |node, bucket_to_create|
  bucket_create(node, bucket_to_create)
end

Given /^node (.*) has bucket ([A-Za-z_]+) of ([0-9]+) MB per node size$/ do |node, bucket_to_create, bucket_size|
  bucket_create(node, bucket_to_create, { :cacheSize => bucket_size.to_i })
end

When /^I add bucket (.*) to node (.*)$/ do |bucket_to_create, node|
  bucket_create(node, bucket_to_create)
end

Then /^node (.*) knows about bucket (.*)$/ do |node, bucket|
  b = bucket_info(node, bucket)
  assert b
  assert b["name"] == bucket
end

Then /^node (.*) does not know about bucket (.*)$/ do |node, bucket|
  assert bucket_info(node, bucket).nil?
end

Then /^all the nodes think the (.+) bucket has ([0-9]+) MB size across the cluster$/ do |bucket, clusterWideBucketSize|
  $node_labels.each do |node|
    assert bucket_info(node, bucket)["basicStats"]["cacheSize"] = clusterWideBucketSize
  end
end
