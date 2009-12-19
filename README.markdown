# The NorthScale Server

This application represents the top of the hierarchy of all memcached
smart services.

![ns_server](http://img.skitch.com/20091219-87hsq67tmxkh7tr1uggb6bpdys.png)

## Starting

The application is started as any other OTP app:

    application:start(ns_server).

Starting the `sasl` app first will provide more detailed logging on
the progress and potential failures of this app.
