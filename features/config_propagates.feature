Feature: Config Propagation
  In order to have efficient use of resources
  As a user of membase software
  I want to configuration to propagate uniformly across a cluster

  Scenario: Bucket Propagation
    Given I have configured nodes A and B
    And they are not joined
    And node B has bucket Foo
    When I join node A to B
    Then node A knows about bucket Foo
    And node B knows about bucket Foo

  Scenario: Bucket Propagation, 3 nodes
    Given I have configured nodes A, B and C
    And they are not joined
    And node B has bucket Foo
    When I join node A to B
    And I join node C to B
    Then node A knows about bucket Foo
    And node B knows about bucket Foo
    And node C knows about bucket Foo

  Scenario: Bucket Propagation, 3 nodes, add a bucket
    Given I have configured nodes A, B and C
    And they are not joined
    And node B has bucket Foo
    When I join node A to B
    And I join node C to B
    And I add bucket Bar to node B
    Then node A knows about bucket Foo
    And node B knows about bucket Foo
    And node C knows about bucket Foo
    And node A knows about bucket Bar
    And node B knows about bucket Bar
    And node C knows about bucket Bar

  Scenario: Bucket Propagation, 3 nodes, add a bucket mid-join
    Given I have configured nodes A, B and C
    And they are not joined
    And node B has bucket Foo
    When I join node A to B
    And I add bucket Bar to node B
    And I join node C to B
    Then node A knows about bucket Foo
    And node B knows about bucket Foo
    And node C knows about bucket Foo
    And node A knows about bucket Bar
    And node B knows about bucket Bar
    And node C knows about bucket Bar

