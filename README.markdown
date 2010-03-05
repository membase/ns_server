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
    make

## Starting

Before you start the server, you may need to do the following
  * Below, <REPO_ROOT> is where you checked out and built ns_server above.
  * Make sure the needed ports are not being used (these include
    8080, 11211, 11212, etc).
  * Build the "for_release" branch of northscale memcached that has isasl
    enabled (git clone git@github.com:northscale/memcached.git &&
    cd memcached &&
    git checkout --track origin/for_release &&
    ./config/autorun.sh &&
    ./configure --enable-isasl &&
    make && make test).
  * Build the bucket_engine library from the
    git@github.com:northscale/bucket_engine.git repository.
    (git clone git@github.com:northscale/bucket_engine.git &&
    cd bucket_engine &&
    ./configure --with-memcached=/path/to/your/above/dir/for/memcached/ &&
    make && make test)
  * Create a sym link from the for_release northscale memcached
    that you just built to <REPO_ROOT>/priv/memcached
  * Create a sym link from the for_release northscale memcached
    memcached/.libs/default_engine.so to
    <REPO_ROOT>/priv/default_engine.so
  * If your sym links are correct, you should be able to cd <REPO_ROOT>/priv
    and run (just to test):
./memcached -d -P /tmp/memcached.pid -E default_engine.so -e "engine=./engines/default_engine.so" -vvv
    NOTE: the emoxi tests will run this from ../../priv
    then kill:
kill `cat /tmp/memcached.pid`
    The build process, when running 'make test', will start memcached
    in this manner to ensure the test succesfully runs.
  * If you're not employing the use of sym links, instead make sure that the
    memcached/.libs/default_engine.so and
    bucket_engine/.libs/bucket_engine.so
    created when building the for_release northscale memcached
    and bucket_engine are in the same directory as the memcached executable 
    either by copying or by soft links. 
    For the buildbot machines, these shared libraries are not installed
    system-wide because they could intefere with the state of the build
    machine.
  * Just a general note, if you are making changes to the priv/config file
    and these changes don't appear to be reflected in the start up
    procedures, try deleting the <REPO_ROOT>/config dir.

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

## Development
  Note: there were previously directions here instructing one to 
  update submodules. Both emoxi and menelaus are now part of 
  ns_server and there is no need to treat them as submodules.

### Updating the dependencies (deps subdirectory)

   make clean
   make
   git commit -m "updated emoxi & menelaus"
   git push


* * * * *
Copyright (c) 2010, NorthScale, Inc.
