#!/bin/sh

emacs --no-init-file --script $(dirname $0)/indent_erl.el "$@"
