#!/bin/bash
#
# Extract abstract syntax tree from a beam file compiled with
# debug_info flag.
#
#   ./ast.sh misc.beam

erl_file=$1
erl_script=$(cat <<EOF
    {ok, {_, [{abstract_code, {_, AST}}]}} =
        beam_lib:chunks("${erl_file}", [abstract_code]),
    io:format("~p~n", [AST]),
    init:stop(0).
EOF
)

erl -noinput -eval "${erl_script}"
