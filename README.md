# lib-lxd.sh

Library for bash script to use Incus or LXD.

## Prerequisite

- Setup Incus or LXD.
- Setup yq

### When using Incus

Install and setup Incus.

- https://linuxcontainers.org/incus/docs/main/installing/#installing
- https://github.com/zabbly/incus

### When using LXD

Install and setup LXD.

```
### example
sudo snap refresh lxd --channel=5.19/stable
sudo snap restart lxd
lxd init
 :
```

### Setup yq

- Setup yq (yaml parser)
  - snap
  - or docker
  - or podman
- About yq
  - https://github.com/mikefarah/yq

- Using snap (Ubuntu, etc.)

```
sudo snap install yq
```

config-lxd.conf (Described later)

```
YQ=yq
```

- Using docker

config-lxd.conf (Described later)

```
YQ=yq_docker
```

- Using podman

config-lxd.conf (Described later)

```
YQ=yq_docker
```

## Install lib-lxd.sh

Example:

```
cp lib-lxd.sh /.../my-app-dir/

### If necessary
cp default-*.sh /.../my-app-dir/
```

## File structure

- my-app-dir (any your directory)
  - lib-lxd.sh (copy from git working directory)
  - config-lxd.sh (your settings)
  - config-instance.yaml (your settings)
  - ssh_authorized_keys (your ssh public keys)
  - LAUNCH.sh (any your script)
  - START.sh (any your script)
  - RESTART.sh (any your script)
  - STOP.sh (any your script)
  - DELETE.sh (any your script)
  - LIST.sh (any your script)

To use default (simple example) scripts.

```
cd /.../my-app-dir/
ln -s default-launch.sh LAUNCH.sh
ln -s default-start.sh START.sh
ln -s default-restart.sh START.sh
ln -s default-stop.sh STOP.sh
ln -s default-delete.sh DELETE.sh
ln -s default-list.sh LIST.sh
```

## Settings

### ssh_authorized_keys

Copy your ssh public keys to `ssh_authorized_keys`.

Example:

```
cd lib-lxd.sh
cat ~/.ssh/id_*.pub > ssh_authorized_keys
```

### config-instance.yaml

Format:

- NODENAME: any name, without LXD_NODENAME_PREFIX
- server.NODENAME.index: unique number, used as part of IP address. (1-200)
- server.NODENAME.image: image name (remote:alias)
- server.NODENAME.like: Similar distribution type (rhel, debian)
- server.NODENAME.vm: true=Virtual Machine, false=Container

Example:

```
server:
  test1:
    index: 1
    image: images:almalinux/8
    like: rhel
    vm: false
  test2:
    index: 2
    image: ubuntu-daily:24.04
    like: debian
    vm: false
  test3:
    index: 3
    image: images:rockylinux/8
    like: rhel
    vm: true
  test4:
    index: 4
    image: images:ubuntu/22.04
    like: debian
    vm: true
```

### Prepare storage pool

```
$ mkdir /mnt/storage1/lxd-mypool
$ lxc storage create mypool dir source=/mnt/storage1/lxd-mypool
```

### config-lxd.sh

Example:

```
YQ=yq_docker
USE_INCUS=0  # default: 1=enabled

LXD_PROFILE=myproject # LXD profile name (auto creation)
LXD_STORAGE=mypool     # existing LXD storage pool name
LXD_NODENAME_PREFIX="myproject-"  # prefix for LXD instance
LXD_NETWORK1_IPADDR_PREFIX="10.98.76."

#http_proxy=
#https_proxy=${http_proxy}
#no_proxy=
```

## SSH

TODO
