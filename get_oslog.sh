#!/bin/bash
log show --predicate 'subsystem == "com.thlim.inputmethod.Hangyeol"' --last 15m > oslog.txt
grep -v "Finder" oslog.txt | tail -n 30
