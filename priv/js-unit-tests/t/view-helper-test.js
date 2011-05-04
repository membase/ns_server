var ViewHelpersTest = TestCase("ViewHelpersTest");


ViewHelpersTest.prototype.testStripPort = function () {
  var servers = [
    {hostname: "lh:9000"},
    {hostname: "lh:9001"},
    {hostname: "dn2:8091"}
  ];

  // this tests main logic
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, servers));
  assertEquals("lh:9001", ViewHelpers.maybeStripPort(servers[1].hostname, servers));
  assertEquals("dn2", ViewHelpers.maybeStripPort(servers[2].hostname, servers));

  // and this tests correctness of caching
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, []));
  assertEquals("lh", ViewHelpers.maybeStripPort(servers[0].hostname, [servers[0]]));
  assertEquals("dn2", ViewHelpers.maybeStripPort(servers[2].hostname, servers));
  assertEquals("lh:9000", ViewHelpers.maybeStripPort(servers[0].hostname, servers));
}
