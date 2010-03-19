Feature: Node Up/Down
  In order to have efficient use of resources
  As a user of northscale software
  I want to be able to have nodes detect node health

  Scenario: Node goes down
    Given I have configured nodes A and B
    And they are already joined
    When node A goes down
    Then node B sees that node A is down

  Scenario: Node comes back up
    Given I have configured nodes A and B
    And they are already joined
    And node A is down
    When node A comes back up
    Then node B sees that node A is up
     And node A sees that node B is up

  Scenario: Node goes down, in 3 node cluster
    Given I have configured nodes A, B and C
    And they are already joined
    When node A goes down
    Then node B sees that node A is down
     And node C sees that node A is down

  Scenario: Node comes back up, in 3 node cluster
    Given I have configured nodes A, B and C
    And they are already joined
    And node A is down
    When node A comes back up
    Then node B sees that node A is up
     And node C sees that node A is up
     And node A sees that node B is up
     And node A sees that node C is up
     And node B sees that node C is up
     And node C sees that node B is up

