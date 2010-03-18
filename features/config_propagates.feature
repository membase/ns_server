Feature: Config Propagation
  In order to have efficient use of resources
  As a user of northscale software
  I want to be able to join and eject nodes from a cluster

  Scenario: Bucket Propagation
    Given I have configured nodes A and B
    And they are not joined
    And node B has bucket Foo
    When I join node A to B
    Then node A knows about bucket Foo

