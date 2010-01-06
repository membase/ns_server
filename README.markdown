# The NorthScale Server

This application represents the top of the hierarchy of all memcached
smart services.  It is an applicaiton in the Erlang OTP sense.

![ns_server](https://github.com/northscale/ns_server/raw/master/doc/images/ns_server.png)

## Starting

The ns_server can be started through the start.sh script found in the 
main directory.  It starts under sasl, which will give you more detailed
logging on both progress and failures of the application and the 
heirarcy.

If you'd like to just start a shell, then interact with the running 
application, start just-shell.sh and then run `application:start(ns_server)`.


Copyright (c) 2010, NorthScale, Inc.
