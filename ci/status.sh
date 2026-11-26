#!/usr/bin/env bash
if [ -f "$RUNNER_TEMP/failed" ]; then echo "some tests FAILED"; exit 1; fi
echo "all tests passed"
