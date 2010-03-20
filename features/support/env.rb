require 'test/unit/assertions'

World(Test::Unit::Assertions)

After do |scenario|
  # Do something after each scenario.
  # The +scenario+ argument allows us to inspect status with
  # the #failed?, #passed? and #exception methods.

  cluster_stop()
end
