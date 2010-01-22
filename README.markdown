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
  * Below, <REPO_ROOT> is where you checked out and built ns_server above.
  * Make sure the needed ports are not being used (these include
    8080, 11211, 11212, etc).
  * Build the genhash library that northscale memcache requires
    (git clone http://github.com/northscale/genhash.git &&
    cd genhash && make)
  * Build the "for_release" branch of northscale memcached that has isasl
    enabled (git clone git@github.com:northscale/memcached.git &&
    cd memcached &&
    git checkout --track origin/for_release &&
    ./config/autorun.sh &&
    ./configure --enable-isasl --with-genhash=/directory/to/genhash/ &&
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
    ./libs/default_engine.so to <REPOT_ROOT>/priv/engines/default_engine.so
  * If your sym links are correct, you should be able to cd <REPO_ROOT>/priv
    and run: ./memcached -E ./engines/default_engine.so -vvv
  * If you're not doing sym links, instead make sure that the
    ./libs/default_engine.so and ./libs/bucket_engine.so
    created when building the for_release northscale memcached
    and bucket_engine are on your LD_LIBRARY_PATH (in OS X
    this is the DYLD_LIBRARY_PATH).  Or...
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

### Pulling the latest dependencies

   git submodule update

### Updating the dependencies (deps subdirectory)

   cd deps/emoxi
   git pull origin master
   cd ../menelaus
   git pull origin master
   cd ../..
   git add deps/emoxi deps/menelaus
   make clean
   make
   git commit -m "updated emoxi & menelaus"
   git push


* * * * *
Copyright (c) 2010, NorthScale, Inc.
