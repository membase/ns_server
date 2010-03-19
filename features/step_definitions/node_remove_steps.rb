When /^I ask node (.*) to remove node (.*) from the cluster$/ do |node_to_ask, node_to_eject|
  p RestClient.get("http://localhost:#{rest_port(node_to_ask)}" +
                              "/pools/default").body
  p RestClient.get("http://localhost:#{rest_port(node_to_eject)}" +
                              "/pools/default").body
  cluster_eject(node_to_eject, node_to_ask)
  sleep(20)
  p RestClient.get("http://localhost:#{rest_port(node_to_ask)}" +
                              "/pools/default").body
  p RestClient.get("http://localhost:#{rest_port(node_to_eject)}" +
                              "/pools/default").body
end
