#!/bin/bash
#
# auto-nfs-backup
#
# Copyright (c) 2013-2014 FOXEL SA - http://foxel.ch
# Please read <http://foxel.ch/license> for more information.
#
# Author(s):
#
#      Luc Deschenaux <l.deschenaux@foxel.ch>
#
# This file is part of the FOXEL project <http://foxel.ch>.
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#
# Additional Terms:
#
#      You are required to preserve legal notices and author attributions in
#      that material or in the Appropriate Legal Notices displayed by works
#      containing it.
#
#      You are required to attribute the work as explained in the "Usage and
#      Attribution" section of <http://foxel.ch/license>.

[ -n "$DEBUG" ] && set -x
export PATH=/usr/sbin:/usr/bin:/sbin:$PATH

[ -n "$DEBUG" ] && set -x

SUBNET=192.168.1.0/24
PORT=2049
BACKUP_MOUNTPOINT=/media/rdiff-backup
BACKUP_MOUNTPOINT_IS_LOCAL=no
BACKUP_DIR=backup
BACKUP_GROUP=changeme
SHAREGEX='^\/'$BACKUP_GROUP
[ -n "$EXCLUDE_HOSTS" ] || EXCLUDE_HOSTS=""

hostlist() {
  _PORT=$1
  _ADDR=$2
  nmap -p$_PORT -Pn -oG - $_ADDR | awk '/open/{gsub("[\\(\\)]","",$3);print $2 " " $3}'
}

macaddr() {
  _ADDR=$1
  arp -n $_ADDR | awk '/[0-9a-f]+:/{gsub(":","-",$3);print $3}'
}

isParentOnOtherDevice() {
  _DIRECTORY=$1
  DEVICE=$(stat -c "%d" "$_DIRECTORY") || exit 1
  DEVICE2=$(stat -c "%d" "`dirname $_DIRECTORY`") || exit 1
  test "$DEVICE" != "$DEVICE2"
}

isMounted() {
  _MOUNTPOINT=$1
  grep -q " $(echo $_MOUNTPOINT | sed -e 's/ /\\\\040/g') " /proc/mounts || isParentOnOtherDevice "$_MOUNTPOINT"
}

assertMounted() {
  _MOUNTPOINT=$1
  if ! isMounted "$_MOUNTPOINT" ; then
    echo $_MOUNTPOINT not mounted >&2
    exit 1
  fi
}

backup_script() {
  _host_ip=$1
  _host_mac=$2
  _host_name=$3
  showmount --no-headers -e $_host_ip | grep -e "$SHAREGEX" | while read line ; do
    share=($line)
    SHARE_DIR=${share[0]#/}
    if ! echo $SHARE_DIR | grep -E -q '^'$BACKUP_GROUP'\-' ; then
      SHARE_DIR=${SHARE_DIR/$BACKUP_GROUP/$BACKUP_GROUP-$host_name}
    fi

    SHARE_MOUNTPOINT=/mnt/$_host_mac/$SHARE_DIR
    SHARE_BACKUP=$BACKUP_MOUNTPOINT/$BACKUP_DIR/$_host_mac/$SHARE_DIR
    SCRIPT=~/backup_${_host_mac}_${SHARE_DIR/\//_}.sh

    cat << 'EOF' > $SCRIPT
#!/bin/bash

set -e

PIDFILE=/var/run/$(basename $0 .sh).pid

if [ -f $PIDFILE ] ; then
  _PID=$(cat $PIDFILE)
  if kill -0 $_PID 2> /dev/null ; then
    if ps -p $_PID -o comm= | grep -q backup ; then
      SECONDS=$(expr $(date +%s) - $(stat -c %Y $PIDFILE))
      if [ $SECONDS -gt 86400 ] ; then
        echo WARNING: backup job $_PID still running after 1 day 1>&2
        exit 1
      else
        exit 0
      fi
    fi
  fi
fi

echo $$ > $PIDFILE

isParentOnOtherDevice() {
  _DIRECTORY=$1
  DEVICE=$(stat -c "%d" "$_DIRECTORY") || exit 1
  DEVICE2=$(stat -c "%d" "`dirname $_DIRECTORY`") || exit 1
  test "$DEVICE" != "$DEVICE2"
}

isMounted() {
  _MOUNTPOINT=$1
  grep -q " $(echo $_MOUNTPOINT | sed -e 's/ /\\\\040/g') " /proc/mounts || isParentOnOtherDevice "$_MOUNTPOINT"
}

EOF

    cat << EOF >> $SCRIPT
mkdir -p $SHARE_MOUNTPOINT
if ! isMounted "$SHARE_MOUNTPOINT" ; then 
  mount -o ro $_host_ip:${share[0]} $SHARE_MOUNTPOINT
fi

EOF
    if [ -f $SHARE_MOUNTPOINT/exclude ] ; then
      EXCLUDE="--exclude-globbing-filelist $SHARE_MOUNTPOINT/exclude"
    else
      EXCLUDE=
    fi

    cat <<EOF >> $SCRIPT
mkdir -p $SHARE_BACKUP

rdiff-backup $EXCLUDE \
--exclude-device-files \
--exclude-fifos \
--exclude-sockets \
$SHARE_MOUNTPOINT $SHARE_BACKUP

EOF
  echo $SCRIPT
  chmod +x $SCRIPT
  done
}

[ "$BACKUP_MOUNTPOINT_IS_LOCAL" = "yes" ] || assertMounted $BACKUP_MOUNTPOINT

#BATCH=$(mktemp)
#echo "#!/bin/sh" > $BATCH

hostlist $PORT $SUBNET | while read line ; do
  host=($line)
  host_ip=${host[0]}
  host_name=${host[1]}
  host_mac=$(macaddr $host_ip)
  if [ -z "$host_mac" ] ; then
    broadcast=$(ip addr | awk /\ $host_ip\\//'{print $4}')
    if [ -n "$broadcast" ] ; then
      IFACE=$(ip route get $broadcast | awk '/dev/ {f=NR} f&&NR-1==f' RS=" ")
      host_mac=$(cat /sys/class/net/$IFACE/address | tr ':' '-')
    fi
    if [ -z "$host_mac" ] ; then
      echo "WARNING: cannot retrieve $host_ip MAC address"
      host_mac=$host_ip
    fi
  fi
  for unwanted in "$EXCLUDE_HOSTS" ; do
    [ "$host_name" = "$unwanted" ] && continue 2
    [ "$host_ip" = "$unwanted" ] && continue 2
    [ "$host_mac" = "$unwanted" ] && continue 2
  done
  export COUNT=0
  backup_script $host_ip $host_mac $host_name | while read script ; do
#    echo $script >> $BATCH
    if [ $COUNT -eq 0 ] ; then
      [ -l "$BACKUP_MOUNTPOINT/$host_name" ] && rm $BACKUP_MOUNTPOINT/$host_name
      ln -s $BACKUP_DIR/$host_mac $BACKUP_MOUNTPOINT/$host_name
    fi
    ((++COUNT))
  done
done

#mv $BATCH ~/backup_all.sh

for script in backup_*.sh ; do
  echo ===== running $script
  ./$script
done
