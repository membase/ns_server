Given /^node (.*) has bucket (.*)$/ do |node, bucket_to_create|
  bucket_create(node, bucket_to_create)
end

Then /^node (.*) knows about bucket (.*)$/ do |node, bucket|
  b = bucket_info(node, bucket)
  assert b
  assert b["name"] == bucket
end

