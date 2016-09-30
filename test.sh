#!/bin/bash

stack build
stack install

distributed slave --port=8081 &
distributed slave --port=8082 &
distributed slave --port=8083 &
distributed slave --port=8084 &
distributed slave --port=8085 &

echo slaves started
echo
sleep 1

distributed master --send-for=10 --wait-for=5 --with-seed=987654
