@later
Feature: Persistence
  As a user of membase
  I want membase to efficiently and correctly use my SSD hardward

  Scenario Outline: SSD is considered an expensive disk resource that's not to be wasted
    Given I have configured membase with <s> MB of SSD storage
      And I have configured membase with <d> MB of non-SSD storage
     When I try to fill up membase with much more than s + d total MB of data
     Then I should be able to successfully store only about s + d MB of data
      And see errors when I store much more than approximately s + d MB of data
    Examples:
      |  s |  d |
      |  0 | 10 |
      | 10 |  0 |
      | 10 | 15 |
      |  0 |  0 |

