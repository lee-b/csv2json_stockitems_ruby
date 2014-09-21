#!/bin/bash

echo -n "Running src/csv2json_ruby on the given example: "

src/csv2json_ruby test_scenarios/given_example/input.csv test_scenarios/given_example/output.json && echo "success." || echo "ERROR"

echo -e "\n\nOutput was:\n"

cat test_scenarios/given_example/output.json


