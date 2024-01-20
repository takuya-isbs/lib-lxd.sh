#!/bin/bash

set -e
cd $(dirname $0)
source ./lib-lxd.sh

lxd_profile_init
lxd_launch_all
lxd_list_all
lxd_print_ssh_host_fingerprint
DONE
