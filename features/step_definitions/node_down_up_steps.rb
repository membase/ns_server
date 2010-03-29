Given /^node ([A-Z]*) is down$/ do |to_be_killed|
  node_kill(to_be_killed)
end

When /^node (.*) goes down$/ do |to_be_killed|
  node_kill(to_be_killed)
end

When /^node (.*) comes back up$/ do |to_be_started|
  node_resurrect(to_be_started)
end

Then /^node (.*?) sees that node (.*?) is (.*)$/ do |to_ask, target, health|
  health = health.gsub(/down/, 'unhealthy')
  health = health.gsub(/back up/, 'healthy')
  health = health.gsub(/up/, 'healthy')

  assert node_info(target, to_ask)['status'] == health
end

