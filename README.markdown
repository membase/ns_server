# The NorthScale Server

This application represents the top of the hierarchy of all memcached
smart services.  It is an application in the Erlang OTP sense.

![ns_server](https://github.com/northscale/ns_server/raw/master/doc/images/ns_server.png)

## Building

Build dependencies include...

    erlang (5.7.4, also needed at runtime)
    ruby (1.8.6)
    gem
    gem install sprockets

Building...

    git clone git@github.com:northscale/ns_server.git
    cd ns_server
    git submodule init
    git submodule update
    make

## Starting

The ns_server can be started through the `start.sh` script found in the
main directory.

    ./start.sh

It starts under sasl, which will give you more detailed logging on
both progress and failures of the application and the heirarcy.

### Interactive Execution

If you'd like to just start a shell, then interact with the running
application, use:

    ./start-shell.sh.

To start with a different node name, and pass parameters (such as a
different config file), use:

    ./start_shell.sh -name $NODE_NAME -ns_server ns_server_config "$CONFIG_FILE"

For example:

    ./start_shell.sh -name ns_2 -ns_server ns_server_config "priv/config2"

* * * * *
Copyright (c) 2010, NorthScale, Inc.
