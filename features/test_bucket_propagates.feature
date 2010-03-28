Feature: Test Application Bucket Propagation
  In order to have efficient use of resources
  As a user of northscale software
  I want to bucket configuration, including the Test Server bucket, to propagate uniformly across a cluster

  Scenario: test_application Bucket Propagation
    Given I have configured nodes A and B
    And they are not joined
    And node A has bucket test_application of 1 MB per node size
    And node B has bucket test_application of 3 MB per node size
    When I join node A to B
    Then node A knows about bucket test_application
    And node B knows about bucket test_application
    And all the nodes think the test_application bucket has 6 MB size across the cluster

  Scenario: test_application Bucket Propagation, 3 nodes
    Given I have configured nodes A, B and C
    And they are not joined
    And node A has bucket test_application of 1 MB per node size
    And node B has bucket test_application of 3 MB per node size
    And node C has bucket test_application of 5 MB per node size
    When I join node A to B
    And I join node C to B
    Then node A knows about bucket test_application
    And node B knows about bucket test_application
    And node C knows about bucket test_application
    And all the nodes think the test_application bucket has 9 MB size across the cluster

