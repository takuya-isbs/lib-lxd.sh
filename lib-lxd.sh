set -eu -o pipefail

SCRIPT_NAME=$(basename $0)
ARGV=("$@")
BASE_DIR=$(dirname $(realpath $0))
CONFIG_INSTANCE=${BASE_DIR}/config-instance.yaml

# default (overridable)
DEBUG=1  # 1 or 0
USE_INCUS=1  # 1 or 0

LXD_PROFILE="testenv"  # LXD profile name (auto creation)
LXD_STORAGE_POOL="testenv"  # existing LXD storage pool name
LXD_NODENAME_PREFIX="testenv-"  # prefix for LXD instance
LXD_NET1_IF="testenv1"
LXD_NET2_IF="testenv2"
LXD_NET1_IPADDR_PREFIX="10.98.76."
LXD_NET2_IPADDR_PREFIX="10.12.34."
LXD_NET1_IPADDR_START="101"
LXD_NET1_IPADDR_END="200"
LXD_NET2_IPADDR_START="101"
LXD_NET2_IPADDR_END="200"

LXD_ENABLE_MAP_UID=1  # 1 or 0

MAIN_USER=user1

YQ=yq  # yq or yq_docker or yq_podman

source ./config-lxd.sh

# unoverridable
SRC_DIR=/SRC
SSH_AUTHORIZED_KEYS=${BASE_DIR}/ssh_authorized_keys

if [ $DEBUG -eq 1 ]; then
    set -x
fi

if [ $USE_INCUS -eq 1 ]; then
    LXC=incus
else
    LXC=lxc
fi

INFO() {
    echo "INFO: $0"
}

ERROR() {
    echo >&2 "ERROR: $0"
}

DONE() {
    echo "DONE: $SCRIPT_NAME ${ARGV[@]}"
}

yq_common() {
    local CMD="$1"
    local DOCKER_OPT="-security-opt=no-new-privileges --cap-drop all --network none"

    $CMD run $DOCKER_OPT --rm -i -v "${PWD}":/workdir mikefarah/yq "$@"
}

yq_docker() {
  yq_common docker "$@"
}

yq_podman() {
  yq_common podman "$@"
}

lxd_list_all() {
    local INDEX
    local NODENAME
    local IMAGE
    local IS_VM

    $LXC list -c ns4t "$LXD_NODENAME_PREFIX"
}

yaml_bool() {
    local b="$1"
    if [ "$b" = "true" ]; then
        echo true
    else
        echo false
    fi
}

lxd_launch_all() {
    local INDEX
    local NODENAME
    local IMAGE
    local ID_LIKE
    local IS_VM=0
    local DISK="10GB"
    local KV
    local KEY
    local VAL

    set -e
    for NODENAME in $($YQ ".server.[] | key" < "$CONFIG_INSTANCE"); do
        IFS_OLD=$IFS
        IFS=$'\n'
        for KV in $($YQ ".server.${NODENAME}" < "$CONFIG_INSTANCE"); do
            KEY=$(echo "$KV" | awk -F": " '{print $1}')
            VAL=$(echo "$KV" | awk -F": " '{print $2}')
            case $KEY in
                index)
                    INDEX=$VAL
                    ;;
                image)
                    IMAGE=$VAL
                    ;;
                like)
                    ID_LIKE=$VAL
                    ;;
                vm)
                    IS_VM=$(yaml_bool $VAL)
                    ;;
                disk)
                    DISK=$VAL
                    ;;
            esac
        done
        IFS=$IFS_OLD
        echo INDEX=$INDEX
        echo IMAGE=$IMAGE
        echo ID_LIKE=$ID_LIKE
        echo IS_VM=$IS_VM
        echo DISK=$DISK
        lxd_launch "$INDEX" "${LXD_NODENAME_PREFIX}${NODENAME}" "$IMAGE" "$ID_LIKE" "$IS_VM" "$DISK" < /dev/null
    done
}

lxd_all_common() {
    local COMMAND="$1"
    local IF_FAIL="$2"
    local NODENAME

    set -e
    for NODENAME in $($YQ ".server.[] | key" < "$CONFIG_INSTANCE"); do
        $LXC $COMMAND "${LXD_NODENAME_PREFIX}${NODENAME}" < /dev/null || $IF_FAIL
    done
}

lxd_start_all() {
    lxd_all_common start false
}

lxd_restart_all() {
    lxd_all_common restart false
}

lxd_stop_all() {
    lxd_all_common stop true
}

lxd_delete_all() {
    lxd_all_common delete true
}

lxd_profile_init() {
    $LXC profile delete $LXD_PROFILE || true  # may be used by other instance
    # TODO support bridge (br0) of host
    $LXC network delete $LXD_NET1_IF || true
    $LXC network delete $LXD_NET2_IF || true
    if $LXC profile create $LXD_PROFILE; then
        $LXC network create $LXD_NET1_IF \
            ipv4.address=${LXD_NET1_IPADDR_PREFIX}1/24 \
            ipv4.dhcp.ranges=${LXD_NET1_IPADDR_PREFIX}${LXD_NET1_IPADDR_START}-${LXD_NET1_IPADDR_PREFIX}${LXD_NET1_IPADDR_END} \
            ipv4.nat=true \
            || true
        $LXC network create $LXD_NET2_IF \
             ipv4.address=${LXD_NET2_IPADDR_PREFIX}1/24 \
             ipv4.dhcp=false \
             ipv4.nat=false \
             ipv6.nat=false \
             ipv6.address=none \
            || true
        $LXC profile device add $LXD_PROFILE eth0 nic network=$LXD_NET1_IF || true
        $LXC profile device add $LXD_PROFILE eth1 nic network=$LXD_NET2_IF || true
        $LXC profile device add $LXD_PROFILE root disk path=/ pool=$LXD_STORAGE_POOL size=5GB || true
    else
        true  # may exist
    fi
}

lxd_launch() {
    local INDEX="$1"
    local NAME="$2"
    local IMAGE="$3"
    local ID_LIKE="$4"
    local IS_VM="$5"
    local DISK="$6"

    local IPADDR_1_INDEX=$((LXD_NET1_IPADDR_START + INDEX - 1))
    local IPADDR_2_INDEX=$((LXD_NET2_IPADDR_START + INDEX - 1))
    local IPADDR_1="${LXD_NET1_IPADDR_PREFIX}${IPADDR_1_INDEX}"
    local IPADDR_2="${LXD_NET2_IPADDR_PREFIX}${IPADDR_2_INDEX}"
    set -e  # func is called in func

    local OPT_VM=
    local OPT_SEC=
    local NET1_IF=eth0
    local NET2_IF=eth1
    if $IS_VM; then
        OPT_VM="--vm"
        NET1_IF=enp5s0
        NET2_IF=enp6s0
    else
        OPT_SEC="-c security.nesting=true"
        #OPT_SEC+=" -c security.privileged=true"
    fi

    $LXC launch $IMAGE $NAME $OPT_VM $OPT_SEC -p $LXD_PROFILE
    lxd_wait_for_wakeup $NAME
    lxd_get_ipv4_retry $NAME $NET1_IF

    $LXC config device override $NAME root size=$DISK

    case $ID_LIKE in
        debian)
            lxd_exec $NAME apt-get update
            lxd_exec $NAME apt-get install -y openssh-server
            lxd_exec $NAME systemctl enable ssh
            lxd_exec $NAME systemctl restart ssh
            local CONF=/etc/netplan/50-init.yaml
            lxd_exec $NAME touch $CONF
            lxd_exec $NAME chmod 600 $CONF
            lxd_exec $NAME tee $CONF <<EOF
network:
  version: 2
  ethernets:
    ${NET1_IF}:
      dhcp4: true
      dhcp6: true
    ${NET2_IF}:
      addresses:
         - ${IPADDR_2}/24
      dhcp4: false
      dhcp6: false
      accept-ra: false
      link-local: []
EOF
            ;;
        rhel)
            lxd_exec $NAME yum install -y openssh-server
            lxd_exec $NAME systemctl restart sshd
            if $IS_VM; then
                # for NetworkManager
                lxd_exec $NAME nmcli connection add type ethernet con-name eth1 ifname $NET2_IF
                lxd_exec $NAME nmcli connection modify eth1 ipv4.method manual ipv4.addr ${IPADDR_2}/24
            else  # container
                # for network-scripts (NetworkManager(nmcli) is not installed)
                local CONF=/etc/sysconfig/network-scripts/ifcfg-eth1
                lxd_exec $NAME tee $CONF <<EOF
DEVICE=eth1
BOOTPROTO=no
IPADDR=${IPADDR_2}
NETMASK=255.255.255.0
ONBOOT=yes
USERCTL=no
EOF
            fi
            ;;
    esac

    $LXC stop $NAME
    # eth0: static IP address from DHCP
    $LXC config device override $NAME eth0 ipv4.address=${IPADDR_1}
    # eth1: DHCP is disabled
    #$LXC config device override $NAME eth1 ipv4.address=${IPADDR_2}
    if [ $LXD_ENABLE_MAP_UID -eq 1 ]; then
        local MYUID=$(stat -c %u "$BASE_DIR")
        # same owner
        $LXC config set $NAME raw.idmap "both $MYUID 0"  # 0 = root uid
    fi
    lxd_mount_hostdir $NAME SRC "$BASE_DIR" $SRC_DIR
    $LXC start $NAME

    lxd_wait_for_wakeup $NAME
    lxd_get_ipv4_retry $NAME $NET1_IF
    $LXC config show $NAME

    # User
    lxd_exec $NAME useradd $MAIN_USER
    SSHDIR="/home/${MAIN_USER}/.ssh"
    lxd_exec $NAME mkdir -p "$SSHDIR"
    $LXC file push $SSH_AUTHORIZED_KEYS ${NAME}"${SSHDIR}/authorized_keys"
    lxd_exec $NAME chown -R ${MAIN_USER}:${MAIN_USER} "$SSHDIR"
    lxd_exec $NAME chmod 700 "$SSHDIR"
    lxd_exec $NAME chmod 600 "${SSHDIR}/authorized_keys"

    case $ID_LIKE in
        debian)
            lxd_exec $NAME usermod -a -G sudo $MAIN_USER
            # automatic grow disk space
            ;;
        rhel)
            lxd_exec $NAME usermod -a -G wheel $MAIN_USER
            if $IS_VM; then
                # grow disk space
                local DEVICE
                local PREFIX
                local SUFFIX
                # root partition
                lxd_exec $NAME yum install -y e2fsprogs cloud-utils-growpart gdisk
                DEVICE=$(lxd_exec $NAME mount | awk '$3 == "/" {print $1}')
                PREFIX="${DEVICE%%[0-9]*}"
                SUFFIX="${DEVICE#"$PREFIX"}"
                lxd_exec $NAME growpart $PREFIX $SUFFIX || true
                lxd_exec $NAME resize2fs $DEVICE || true
            fi
            ;;
    esac
}

lxd_exist() {
    local NAME="$1"
    $LXC info ${NAME} > /dev/null 2>&1
}

lxd_mount_hostdir() {
    local INSTANCE="$1"
    local DEVICE_NAME="$2"
    local SRCDIR="$3"
    local DSTDIR="$4"
    $LXC config device add $INSTANCE $DEVICE_NAME disk source="$SRCDIR" path="$DSTDIR"
}

lxd_get_ipv4() {
    local INSTANCE="$1"
    local NETWORK_IF="$2"

    $LXC list "$INSTANCE" -f json \
        | jq 'map(select(.name == "'$INSTANCE'"))' \
        | jq  .[].state.network.${NETWORK_IF}.addresses \
        | jq 'map(select(.family == "inet"))' \
        | jq -r .[].address
}

lxd_get_ipv4_retry() {
    local INSTANCE="$1"
    local NETWORK_IF="$2"

    while :; do
        IP=$(lxd_get_ipv4 $INSTANCE $NETWORK_IF || true)
        if [ -n "$IP" ]; then
            break
        fi
        echo  >&2 "lxd_get_ipv4_retry..."
        sleep 1
    done
    echo "$IP"
}

lxd_exec() {
    local NAME="$1"
    shift
    $LXC exec "${LXD_NODENAME_PREFIX}${NODENAME}" -- "$@"
}

lxd_exec_all() {
    local IGNORE_ERROR="$1"
    shift
    local INDEX
    local NODENAME
    local IMAGE
    local ID_LIKE
    local IS_VM

    set -e
    for NODENAME in $($YQ ".server.[] | key" < "$CONFIG_INSTANCE"); do
        lxd_exec "${LXD_NODENAME_PREFIX}${NODENAME}" "$@" < /dev/null || $IGNORE_ERROR
    done
}

lxd_print_ssh_host_fingerprint()
{
    set +x
    lxd_exec_all false sh -c 'echo -n "##### "; hostname; ls -1 /etc/ssh/ssh_host_*.pub | xargs -l ssh-keygen -l -f'
    if [ $DEBUG -eq 1 ]; then
        set -x
    fi
}

lxd_is_running() {
    local INSTANCE="$1"
    set -e
    lxd_exec $INSTANCE hostname > /dev/null
}

lxd_wait_for_wakeup() {
    local INSTANCE="$1"
    set -e
    while ! lxd_is_running $INSTANCE; do
        sleep 1
    done
}

my_ipv4_addr() {
    local IF="$1"
    ip -o -4 addr show $IF | awk '{print $4}' | cut -d'/' -f1
}

check_required() {
    echo "key: val" | $YQ ".key" > /dev/null
    echo '{"key": "val"}' | jq ".key" > /dev/null
}

check_required
