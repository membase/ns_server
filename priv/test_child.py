#!/usr/bin/env python

import sys
import time

if __name__ == '__main__':
    naptime = 5
    if len(sys.argv) > 1:
        naptime = float(sys.argv[1])
    time.sleep(naptime)
