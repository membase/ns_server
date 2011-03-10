{node, n1, 'n_0@127.0.0.1'}.
{node, n2, 'n_1@127.0.0.1'}.

{logdir, "../logs"}.

{suites, "common_tests", all}.
{skip_suites, "common_tests", [eunit_SUITE], "Ignore"}.