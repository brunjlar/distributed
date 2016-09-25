#!/bin/bash

stack build
stack install

distributed slave localhost 8081 &
distributed slave localhost 8082 &
#distributed slave localhost 8083 &
#distributed slave localhost 8084 &
#distributed slave localhost 8085 &
#distributed slave localhost 8086 &
#distributed slave localhost 8087 &
#distributed slave localhost 8088 &
#distributed slave localhost 8089 &
#distributed slave localhost 8090 &

echo slaves started
echo
sleep 1

distributed master localhost 8091 123456 1 20
