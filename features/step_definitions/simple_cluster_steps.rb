Given /^I have configured nodes (.*)$/ do |nodes|
  # The nodes looks like "A, B and C".
  $node_labels = nodes.gsub(/,/, '').
                       gsub(/and /, '').
                       split(' ') # Looks like ["A", "B', C"].
  cluster_prep($node_labels.length)
  cluster_start()
end

Given /^they are not joined$/ do
  assert $node_labels
  assert $node_labels.length > 1

  $node_labels.each do |x|
    d = JSON.parse(RestClient.get("http://localhost:#{rest_port(x)}/pools/default"))
    assert d['nodes'].length == 1
  end
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

