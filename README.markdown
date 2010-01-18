# The NorthScale Server

This application represents the top of the hierarchy of all memcached
smart services.  It is an application in the Erlang OTP sense.

<div>
    <img src="https://github.com/northscale/ns_server/raw/master/doc/images/ns_server.png"
         alt="[ns server]" style="float: right"/>
</div>

## Building

Build dependencies include...

* erlang (5.7.4, also needed at runtime)
* ruby (1.8.6)
* ruby gems
    * sprockets (install with `gem install sprockets`)

Building...

    git clone git@github.com:northscale/ns_server.git
    cd ns_server
    git submodule init
    git submodule update
    make

## Starting

Before you start the server, you may need to do the following
  * Make sure the needed ports are not being used (these include
    8080, 11211, 11212, etc).
  * Build a version of the 1.6 memcached branch that has isasl
    enabled (./configure --enable-isasl).
  * Create a sym link from the 1.6 memcached to <REPO_ROOT>/priv/memcached
  * Make sure that the default_engine.so created when building the
    1.6 memcached is on your LD_LIBRARY_PATH (in OS X this is the
    DYLD_LIBRARY_PATH).
  * Make sure the memcached port_server config in the priv/config file
    has the engine option (-E ..) and the option is not commented out
    (at the moment this arg is commented out in the config file).
  * Just a general note, if you are making changes to the config file
    and these changes don't appear to be reflected in the start up
    procedures, try deleting the <REPO_ROOT>/data dir.

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

Tip: if you see error message like...

    =ERROR REPORT==== 18-Jan-2010::10:45:00 ===
    application_controller: bad term: priv/config2

Then you will have to add backslashes around the path double-quotes --
like \"priv/config\"

* * * * *
Copyright (c) 2010, NorthScale, Inc.
