# mlockall

A NIF allowing to m(un)lockall from Erlang.

# usage

    Erlang R15B03 (erts-5.9.3) [source] [64-bit] [smp:8:8] [async-threads:0] [hipe] [kernel-poll:false]

    Eshell V5.9.3  (abort with ^G)
    1> os:cmd("grep VmLck /proc/$PPID/status").
    "VmLck:\t       0 kB\n"
    2> mlockall:lock([current, future]).
    ok
    3> os:cmd("grep VmLck /proc/$PPID/status").
    "VmLck:\t  719404 kB\n"
    4> mlockall:unlock().
    ok
    5> os:cmd("grep VmLck /proc/$PPID/status").
    "VmLck:\t       0 kB\n"

# notes

Tested on GNU/Linux with Erlang/OTP R14B04 and R15B03.
