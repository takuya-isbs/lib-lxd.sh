#!/bin/bash

set -e
cd $(dirname $0)
source ./lib-lxd.sh

lxd_start_all
DONE
