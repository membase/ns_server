Given /^I have configured nodes (.*)$/ do |nodes|
  # The nodes looks like "A, B and C".
  $node_labels = nodes.gsub(/,/, '').
                       gsub(/and /, '').
                       split(' ') # Looks like ["A", "B', C"].
  ClusterConfig.activate!($node_labels.length)
end

Given /^they are not joined$/ do
  assert_cluster_not_joined()
end

Given /^they are already joined$/ do
  assert $node_labels
  assert $node_labels.length > 1

  prev = nil
  $node_labels.each do |x|
    if prev
      cluster_join(x, prev)
    end
    prev = x
  end

  assert_cluster_fully_joined()
end

When /^I join node (.*) to (.*)$/ do |joiner, joinee|
  cluster_join(joiner, joinee)
end

When /^I tell node (.*) to leave the cluster$/ do |leaver|
  cluster_eject(leaver)
end

Then /^all nodes know about each other$/ do
  assert_cluster_fully_joined()
end

Then /^the nodes stop knowing about each other$/ do
  assert_cluster_not_joined()
end

Then /^node ([A-Z]+) and ([A-Z]+) know about each other$/ do |x, y|
  assert node_info(x, y)
  assert node_info(y, x)
end

Then /^node ([A-Z]+) and ([A-Z]+) don\'t know about each other$/ do |x, y|
  assert node_info(x, y).nil?
  assert node_info(y, x).nil?
end
