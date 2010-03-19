Given /^node (.*) has bucket (.*)$/ do |node, bucket_to_create|
  bucket_create(node, bucket_to_create)
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

