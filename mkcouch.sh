#!/bin/sh
#usage mkcouch pathname portnum
if [ ! -d couch ]; then
    mkdir couch
fi
mkdir couch/$1
echo "[httpd]" > couch/$1_conf.ini
echo "port=$2" >> couch/$1_conf.ini
echo "[couchdb]" >> couch/$1_conf.ini
echo "database_dir="`pwd`"/couch/$1" >> couch/$1_conf.ini
echo "view_index_dir="`pwd`"/couch/$1" >> couch/$1_conf.ini
echo "[log]" >> couch/$1_conf.ini
echo "file="`pwd`"/couch/$1.log" >> couch/$1_conf.ini

echo ok
