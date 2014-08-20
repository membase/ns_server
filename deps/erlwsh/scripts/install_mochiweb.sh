#! /bin/bash
# author: litaocheng@gmail.com
# date: 2009.10.16
# desc: get the mochiweb from the google code svn, and install 
#       it to the erlang otp lib directory(makesure you have install
#       the erlang otp).
#       1, get the erlang otp lib dir
#       2, check out the code from svn
#       3, compile the code


erl_exists()
{
    echo -n "check if Erlang/OTP exists... "
    if !(erl -version > /dev/null 2>&1); then
        echo "First, You must install the erlang otp"
        echo "http://www.erlang.org/download.html"
        exit 1
    fi
    echo "ok"
}

erl_lib()
{
    echo -n "get the erlang lib path... "
    ERL_RUN="erl -eval 'io:format(\"ERL_LIB|~s|\", [code:lib_dir()]), init:stop()'"
    ERL_OUTPUT=$(eval $ERL_RUN)
    ERL_LIB=`echo $ERL_OUTPUT | cut -d '|' -f 2`
    export ERL_LIB
    echo "ok"
}

svn_co()
{
    echo "checkout the mochiweb codes from the github..."
    if !(git clone https://github.com/mochi/mochiweb.git $MOCHI_DIR); then
        echo "git clone mochiweb codes error"
        exit 1
    fi
    echo "ok"
}

compile_mochi()
{
    if !(cd $MOCHI_DIR && make ); then
        echo "compile the mochiweb code error"
        exit 1
    fi
}

erl_exists
erl_lib
echo "ERL_TOP is " $ERL_LIB
MOCHI_DIR=$ERL_LIB/mochiweb
svn_co
compile_mochi


