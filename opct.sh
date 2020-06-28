#!/bin/bash
#Storage name in Proxmox for CT instance rootfs disk
ctStrg="local-lvm"
#Full path of Proxmox pct utility
CMD="/usr/sbin/pct"
#Path of Proxmox CT conf
ct_conf_path="/etc/pve/lxc"
#OpenWRT config backup filename
backup_filename="opctbak"
#bind mount MP in the CT instance 
guest_mp_path="/shared"
#bind mount dirname on host
host_share_dirname="ctshare"
#bind mount full path on host
host_mp_path="/run/$host_share_dirname"
#rootfs size for the new CT instance in GB
rf_size="0.2"
#memory size for the new CT instance in MB
mem_size="128"
#arch of the new CT instance
ctarch="amd64"
#num of cpu cores assigned to the new CT instance
cores="1"


check_oldct() {
	local oldstat=""
	oldstat=$("$CMD" list | grep "$oldct" | grep running)
	if test -z "$oldstat"; then
		echo "The old CT does not exist or is not running."
		exit 1
	fi

}

check_newct() {
	local newstat=""
	newstat=$("$CMD" list | grep "$newct")
	if test -n "$newstat"; then
		return 1
	else
	return 0
	fi
}

create_newct() {
	local newstat=""
	ctname=$(basename "$ct_template" | cut -d'-' -f1)-$(basename "$ct_template" | cut -d'-' -f3)
	"$CMD" create "$newct" "$ct_template" --rootfs "$ctStrg":"$rf_size" --ostype unmanaged --hostname "$ctname" --arch "$ctarch" --cores "$cores" --memory "$mem_size" --swap 0 --unprivileged 1
	newstat=$("$CMD" list | grep "$newct")
	if test -z "$newstat"; then
		echo "Failed to Create CT"
		exit 1
	fi
	echo "New CT Created."
}

createshare_new(){
	#The CTs use a bind mount of host_mp_path on host to share files among them.
	echo "mp0: $host_mp_path/,mp=$guest_mp_path" >> "$ct_conf_path"/"$newct".conf
}

oldct_backup() {
	rm "$host_mp_path"/"$backup_filename"
	"$CMD" exec "$oldct" -- ash -c "sysupgrade -b $guest_mp_path/$backup_filename"
	local res=$?
	if test $res -eq 0; then
		echo "Old CT conf backup completed."
	else
		echo "Old CT conf backup failed."
		exit 1
	fi
}

newct_restore() {
	"$CMD" start "$newct"
	local newstat=""
	newstat=$("$CMD" status "$newct" | grep running)
	if test -n "$newstat"; then
		#Wait for the new CT init complete.
		sleep 5
		"$CMD" exec "$newct" -- ash -c "sysupgrade -r $guest_mp_path/$backup_filename"
		local res=$?
		if test $res -eq 0; then
			echo "New CT conf restored."
		else
			echo "New CT conf restoration failed."
			exit 1
		fi
	else
		echo "The new CT is not running. Failed to restore."
		exit 1
	fi

}

stop_oldct() {
	"$CMD" stop "$oldct"
	local oldstat=""
	oldstat=$("$CMD" status "$oldct" | grep stop)
	if test -z "$oldstat"; then
		echo "The old CT is not stopped."
		exit 1
	fi
	echo "The old CT stopped."
}

stop_newct() {
	"$CMD" stop "$newct"
	local newstat=""
	newstat=$("$CMD" status "$newct" | grep stop)
	if test -z "$newstat"; then
		echo "The new CT is not stopped."
		exit 1
	fi
	echo "The new CT stopped."
}

copyconf_old2new() {
	#Copy remaining bind mounts to the new ct. 10 bind mounts ought to be enough.
	grep "^mp[0-9]" "$ct_conf_path"/"$oldct".conf | grep -v "$host_share_dirname" >>"$ct_conf_path"/"$newct".conf
	#Copy nics to the new ct. 10 nics ought to be enough.
	grep "^net[0-9]" "$ct_conf_path"/"$oldct".conf >>"$ct_conf_path"/"$newct".conf
	#For the lxc settings.
	grep "^lxc" "$ct_conf_path"/"$oldct".conf >>"$ct_conf_path"/"$newct".conf
	#Hookscript
	grep "^hookscript" "$ct_conf_path"/"$oldct".conf >>"$ct_conf_path"/"$newct".conf
	#Set the new ct start onboot
	grep onboot "$ct_conf_path"/"$oldct".conf >>"$ct_conf_path"/"$newct".conf
	grep order "$ct_conf_path"/"$oldct".conf >>"$ct_conf_path"/"$newct".conf
	#Turn off start onboot for the old ct
	sed -e '/^onboot/s/^/#/' -i "$ct_conf_path"/"$oldct".conf
	echo "Conf from the old to the new one copied."

}

start_newct() {
	"$CMD" start "$newct"
	local newstat=""
	newstat=$("$CMD" status "$newct" | grep running)
	if test -z "$newstat"; then
		echo "The new CT is not started."
		exit 1
	fi
	echo "The new CT is started."
}

usage() {
    echo "$0 [new|upgrade|swap]"
    exit 1
}

if [ "$1" == "new" ] || [ "$1" == "ne" ] ; then
#The vmid of the new OpenWRT lxc instance to be created
declare -i newct=$2
#The path and filename of the OpenWRT plain template
ct_template=$3

if test -z "$ct_template" || [ "$newct" -le "0" ] ; then
echo "This command creates a new OpenWRT lxc instance based on a user-specified CT template."
echo "Usage: $0 [new|ne] [New_vmid] [CT_template]"
exit 1
fi

create_newct
createshare_new
echo "Please note that this new instance does NOT contain any nic. You may need to do the network configuration later via Proxmox VE GUI or CLI. "
exit 0
fi

if [ "$1" == "swap" ] || [ "$1" == "sw" ] ; then
#The old and running OpenWRT lxc instance vmid
declare -i oldct=$2
#The vmid of the new OpenWRT lxc instance to be created
declare -i newct=$3


if test -z "$newct" || [ "$oldct" -le "0" ] || [ "$newct" -le "0" ] || [ "$oldct" == "$newct" ] ; then
echo "This command stops the old OpenWRT lxc instance, then starts the new one, effectively does the swapping."
echo "Usage: $0 [swap|sw] [Old_vmid] [New_vmid]"
exit 1
fi

check_oldct
check_newct
retval=$?
if [ "$retval" -eq 0 ]; then 
echo "The new CT does not exist."
exit 1
fi
stop_oldct
start_newct
echo "OpenWRT CT instances swapping completed."
exit 0
fi

if [ "$1" == "upgrade" ] || [ "$1" == "up" ] ; then
#The old and running OpenWRT lxc instance vmid
declare -i oldct=$2
#The vmid of the new OpenWRT lxc instance to be created
declare -i newct=$3
#The path and filename of the OpenWRT plain template
ct_template=$4


if test -z "$ct_template" || [ "$oldct" -le "0" ] || [ "$newct" -le "0" ] || [ "$oldct" == "$newct" ] ; then
echo "This command creates an upgrade of the running OpenWRT lxc instance based on a user-specified CT template."
echo "Usage: $0 [upgrade|up] [Old_vmid] [New_vmid] [CT_template]"
exit 1
fi


check_oldct
check_newct
retval=$?
if [ "$retval" -eq 1 ]; then 
echo "The new CT already exists."
exit 1
fi
oldct_backup
create_newct
createshare_new
newct_restore
stop_newct
copyconf_old2new
echo "An upgraded instance of OpenWRT CT has been created successfully. "
exit 0
fi

usage