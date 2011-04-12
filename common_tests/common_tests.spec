{logdir, "../logs"}.
{suites, "common_tests", all}.
%Disable cover until the purged warnings are fixed
%{cover, "./common_tests.cover"}.