When /^I GET path ([^\s]+) on node ([A-Z])$/ do |path, node|
  $last_response = begin
                     raw_node_rpc(node, :get, path)
                   rescue RestClient::ExceptionWithResponse => e
                     e.response
                   end
end

Then /^I should get status code ([0-9]+)$/ do |code|
  code = code.to_i
  assert_equal $last_response.code, code.to_i
end

Then /^I should get parsable json$/ do
  assert_nothing_raised do
    JSON.parse($last_response.body)
  end
end
