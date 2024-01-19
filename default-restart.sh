#!/bin/bash

set -e
cd $(dirname $0)
source ./lib-lxd.sh

lxd_restart_all
DONE
