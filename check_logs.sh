#!/bin/bash
log show --predicate 'process == "Hangyeol"' --last 15m > hangyeol_logs.txt
log show --predicate 'eventMessage CONTAINS "Hangyeol"' --last 15m >> hangyeol_logs.txt
grep -i "quarantine\|amfi\|crash\|killed\|prevent\|error\|fail" hangyeol_logs.txt | head -n 20
