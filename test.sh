#!/bin/bash

stack build
stack install

distributed slave --port=8081 &
distributed slave --port=8082 &
distributed slave --port=8083 &
distributed slave --port=8084 &
distributed slave --port=8085 &
distributed slave --port=8086 &
distributed slave --port=8087 &
distributed slave --port=8088 &
distributed slave --port=8089 &
distributed slave --port=8090 &

echo slaves started
echo
sleep 1

distributed master --send-for=10 --wait-for=5 --with-seed=987654
