#!/bin/sh
#
# Traffic logging tool for OpenWRT-based routers
#
# Created by Emmanuel Brucy (emmanuel.brucy@gmail.com)
#
# Based on work from Fredrik Erlandsson (erlis@linux.nu)
# Based on traff_graph script by twist - http://wiki.openwrt.org/RrdTrafficWatch

formatnumber()
{
    kilo=$(echo $1 | sed 's/[^0-9]//g')
    if [ -z "$kilo" ]; then
		echo 0 >> $2
	else
	    mega=$(($kilo/1024))
	    giga=$(($kilo/1048576))
	    if [ $mega -lt 1 ] ; then
		    echo "${kilo} k" >> $2
	    elif [ $giga -lt 1 ] ; then
		    echo "${mega} M" >> $2
	    else
		    megafrac=$(((($kilo-$(($giga\*1048576))))/1024))
		    echo "${giga}.${megafrac} G" >> $2
	    fi
   fi
}

lock()
{
	while [ -f /tmp/wrtbwmon.lock ]; do
		sleep 1
	done
	echo $$ > /tmp/wrtbwmon.lock
}

unlock()
{
	rm -f /tmp/wrtbwmon.lock
}

case $1 in

"setup" )

	[ -z "$2" ] && echo "Missing argument 2" && exit 1

	touch /tmp/arpfile.log

	#Create the RRDIPT CHAIN (it doesn't matter if it already exists).
	iptables -N RRDIPT 2> /dev/null

	#Add the RRDIPT CHAIN to the FORWARD chain (if non existing).
	iptables -L FORWARD -n | grep RRDIPT > /dev/null
	if [ $? -ne 0 ]; then
		echo "iptables chain not found, creating it..."
		iptables -I FORWARD -j RRDIPT
	fi

	#For each host in the ARP table
	grep $2 /proc/net/arp | while read IP TYPE FLAGS MAC MASK IFACE
	do
		if [ ! $IP ]; then 
			continue
		fi

		CURRHOST="$MAC $IP"

		lock
		#Is MAC is assigned to the same IP as last time ?
		grep "$CURRHOST" /tmp/arpfile.log > /dev/null
		if [ $? -ne 0 ]; then
			echo "DEBUG : New/modified entity : $MAC / $IP"
			
			#Add iptable rules (if non existing).
			iptables -nL RRDIPT | grep $IP > /dev/null
			if [ $? -ne 0 ]; then
				iptables -I RRDIPT -d $IP -j RETURN
				iptables -I RRDIPT -s $IP -j RETURN
			fi

			#Update the ARP file
			grep -v "$MAC" /tmp/arpfile.log | grep -v $IP > /tmp/arpfile.new
			mv /tmp/arpfile.new /tmp/arpfile.log
			echo ${CURRHOST} >> /tmp/arpfile.log
		fi
		unlock
	done	
	;;
	
"update" )
	[ -z "$2" ] && echo "Missing argument 2" && exit 1
	touch $2

	lock

	#Read and reset counters
	iptables -L RRDIPT -vnxZ -t filter > /tmp/traffic.tmp

	cat /tmp/arpfile.log| while read MAC IP
	do
		#Add new data to the graph. Count in Kbs to deal with 16 bits signed values (up to 2G only)
		#Have to use temporary files because of crappy busybox shell
		grep $IP /tmp/traffic.tmp | while read PKTS BYTES TARGET PROT OPT IFIN IFOUT SRC DST
		do
			[ "$SRC" = "$IP" ] && echo $(($BYTES/1024)) > /tmp/in.tmp
			[ "$DST" = "$IP" ] && echo $(($BYTES/1024)) > /tmp/out.tmp
		done
		
		IN=$(cat /tmp/in.tmp)
		OUT=$(cat /tmp/out.tmp)
		
		if [ $IN -gt 0 -o $OUT -gt 0 ];  then
			echo "New traffic for $MAC since last update : $IN:$OUT"
		
			PEAKUSAGE_IN=$(grep $MAC $2 | cut -f2 -s -d, )
			PEAKUSAGE_OUT=$(grep $MAC $2 | cut -f3 -s -d, )
			OFFPEAKUSAGE_IN=$(grep $MAC $2 | cut -f4 -s -d, )
			OFFPEAKUSAGE_OUT=$(grep $MAC $2 | cut -f5 -s -d, )		

			if [ "$3" = "offpeak" ]; then
				OFFPEAKUSAGE_IN=$(($OFFPEAKUSAGE_IN+$IN))
				OFFPEAKUSAGE_OUT=$(($OFFPEAKUSAGE_OUT+$OUT))
			else
				PEAKUSAGE_IN=$(($PEAKUSAGE_IN+$IN))
				PEAKUSAGE_OUT=$(($PEAKUSAGE_OUT+$OUT))
			fi

			grep -v "$MAC" $2 > /tmp/db.new
			mv /tmp/db.new $2
			echo $MAC,$PEAKUSAGE_IN,$PEAKUSAGE_OUT,$OFFPEAKUSAGE_IN,$OFFPEAKUSAGE_OUT,$(date "+%d-%m-%Y %H:%M") >> $2
		fi
	done
	
	#Free some memory
	rm -f /tmp/traffic.tmp
	rm -f /tmp/in.tmp
	rm -f /tmp/out.tmp
	unlock
	;;
	
"publish" )

	[ -z "$2" ] && echo "Missing argument 2" && exit 1
	[ -z "$3" ] && echo "Missing argument 3" && exit 1
	[ -z "$4" ] && USERSFILE="/dev/null" || USERSFILE=$4

	lock
	# create HTML page
	echo "<html><head><title>Traffic</title></head><body>" > $3
	echo "<h1>Total Usage :</h1>" >> $3
	echo "<table border="1"><tr bgcolor=silver><td>User</td><td>Peak download</td><td>Peak upload</td><td>Offpeak download</td><td>Offpeak upload</td><td>Last seen</td></tr>" >> $3
	cat $2 | while IFS=, read MAC PEAKUSAGE_IN PEAKUSAGE_OUT OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT LASTSEEN
	do
		USER=$(grep $MAC $USERSFILE | cut -f2 -s -d= )
		[ -z "$USER" ] && USER=$MAC
		echo "<tr><td>$USER</td><td>" >> $3
		formatnumber "$PEAKUSAGE_IN" $3
		echo "</td><td>" >> $3
		formatnumber "$PEAKUSAGE_OUT" $3
		echo "</td><td>" >> $3
		formatnumber "$OFFPEAKUSAGE_IN" $3
		echo "</td><td>" >> $3
		formatnumber "$OFFPEAKUSAGE_OUT" $3
		echo "</td><td>" >> $3
		echo "$LASTSEEN" >> $3
		echo "</td></tr>" >> $3
	done
	echo "</table>" >> $3
	echo "<br /><small>This page was generated on `date`</small>" >> $3
	echo "</body></html>" >> $3
	unlock
	;;

*)
	echo "Usage : $0 {setup|update|publish} [options...]"
	echo "Options : "
	echo "   $0 setup lan_interface"
	echo "   $0 update database_file [offpeak]"
	echo "   $0 publish database_file path_of_html_report [user_file]"
	echo "Examples : "
	echo "   $0 setup br0"
	echo "   $0 update /jffs/wrtbwmon.db offpeak"
	echo "   $0 publish /jffs/wrtbwmon.db /www/user/usage.htm /jffs/wrtdwmonusers.txt"
	exit
	;;
esac
