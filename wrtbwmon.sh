#!/bin/sh
#
# Traffic logging tool for OpenWRT-based routers
#
# Created by Emmanuel Brucy (e.brucy AT qut.edu.au)
#
# Based on work from Fredrik Erlandsson (erlis AT linux.nu)
# Based on traff_graph script by twist - http://wiki.openwrt.org/RrdTrafficWatch
# 
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# 
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.

LAN_IFACE=$(nvram get lan_ifname)

formatnumber()
{
    kilo=$(echo ${1} | sed 's/[^0-9]//g')
    if [ -z "${kilo}" ]; then
		echo 0 >> ${2}
	else
	    mega=$((${kilo}/1000))
	    if [ ${mega} -lt 1 ] ; then
		    echo "${kilo} k" >> ${2}
	    elif [ ${mega} -lt 1000 ] ; then
		    echo "${mega} M" >> ${2}
	    else
			giga=$((${kilo}/1000000))
			giga_frac=$(echo ${mega} | tail -c4)
		    echo "${giga}.${giga_frac} G" >> ${2}
	    fi
   fi
}

lock()
{
	while [ -f /tmp/wrtbwmon.lock ]; do
		if [ ! -d /proc/$(cat /tmp/wrtbwmon.lock) ]; then
			echo "WARNING : Lockfile detected but process $(cat /tmp/wrtbwmon.lock) does not exist !"
			rm -f /tmp/wrtbwmon.lock
		fi
		sleep 1
	done
	echo $$ > /tmp/wrtbwmon.lock
}

unlock()
{
	rm -f /tmp/wrtbwmon.lock
}

case ${1} in

"setup" )

	#Create the RRDIPT CHAIN (it doesn't matter if it already exists).
	iptables -N RRDIPT 2> /dev/null

	#Add the RRDIPT CHAIN to the FORWARD chain (if non existing).
	iptables -L FORWARD --line-numbers -n | grep "RRDIPT" | grep "1" > /dev/null
	if [ $? -ne 0 ]; then
		iptables -L FORWARD -n | grep "RRDIPT" > /dev/null
		if [ $? -eq 0 ]; then
			echo "DEBUG : iptables chain misplaced, recreating it..."
			iptables -D FORWARD -j RRDIPT
		fi
		iptables -I FORWARD -j RRDIPT
	fi

	#For each host in the ARP table
	grep ${LAN_IFACE} /proc/net/arp | while read IP TYPE FLAGS MAC MASK IFACE
	do
		#Add iptable rules (if non existing).
		iptables -nL RRDIPT | grep "${IP} " > /dev/null
		if [ $? -ne 0 ]; then
			iptables -I RRDIPT -d ${IP} -j RETURN
			iptables -I RRDIPT -s ${IP} -j RETURN
		fi
	done	
	;;
	
"update" )
	[ -z "${2}" ] && echo "ERROR : Missing argument 2" && exit 1
	
	# Uncomment this line if you want to abort if database not found
	# [ -f "${2}" ] || exit 1

	lock

	#Read and reset counters
	iptables -L RRDIPT -vnxZ -t filter > /tmp/traffic_$$.tmp

	grep -v "0x0" /proc/net/arp  | while read IP TYPE FLAGS MAC MASK IFACE
	do
		#Add new data to the graph. Count in Kbs to deal with 16 bits signed values (up to 2G only)
		#Have to use temporary files because of crappy busybox shell
		grep ${IP} /tmp/traffic_$$.tmp | while read PKTS BYTES TARGET PROT OPT IFIN IFOUT SRC DST
		do
			[ "${DST}" = "${IP}" ] && echo $((${BYTES}/1000)) > /tmp/in_$$.tmp
			[ "${SRC}" = "${IP}" ] && echo $((${BYTES}/1000)) > /tmp/out_$$.tmp
		done
		IN=$(cat /tmp/in_$$.tmp)
		OUT=$(cat /tmp/out_$$.tmp)
		rm -f /tmp/in_$$.tmp
		rm -f /tmp/out_$$.tmp
		
		if [ ${IN} -gt 0 -o ${OUT} -gt 0 ];  then
			echo "DEBUG : New traffic for ${MAC} since last update : ${IN}k:${OUT}k"
		
			LINE=$(grep ${MAC} ${2})
			if [ -z "${LINE}" ]; then
				echo "DEBUG : ${MAC} is a new host !"
				PEAKUSAGE_IN=0
				PEAKUSAGE_OUT=0
				OFFPEAKUSAGE_IN=0
				OFFPEAKUSAGE_OUT=0
			else
				PEAKUSAGE_IN=$(echo ${LINE} | cut -f2 -s -d, )
				PEAKUSAGE_OUT=$(echo ${LINE} | cut -f3 -s -d, )
				OFFPEAKUSAGE_IN=$(echo ${LINE} | cut -f4 -s -d, )
				OFFPEAKUSAGE_OUT=$(echo ${LINE} | cut -f5 -s -d, )
			fi
			
			if [ "${3}" = "offpeak" ]; then
				OFFPEAKUSAGE_IN=$((${OFFPEAKUSAGE_IN}+${IN}))
				OFFPEAKUSAGE_OUT=$((${OFFPEAKUSAGE_OUT}+${OUT}))
			else
				PEAKUSAGE_IN=$((${PEAKUSAGE_IN}+${IN}))
				PEAKUSAGE_OUT=$((${PEAKUSAGE_OUT}+${OUT}))
			fi

			grep -v "${MAC}" ${2} > /tmp/db_$$.tmp
			mv /tmp/db_$$.tmp ${2}
			echo ${MAC},${PEAKUSAGE_IN},${PEAKUSAGE_OUT},${OFFPEAKUSAGE_IN},${OFFPEAKUSAGE_OUT},$(date "+%d-%m-%Y %H:%M") >> ${2}
		fi
	done
	
	#Free some memory
	rm -f /tmp/*_$$.tmp
	unlock
	;;
	
"publish" )

	[ -z "${2}" ] && echo "ERROR : Missing argument 2" && exit 1
	[ -z "${3}" ] && echo "ERROR : Missing argument 3" && exit 1
	
	USERSFILE="/etc/dnsmasq.conf"
	[ -f "${USERFILE}" ] || USERSFILE="/tmp/dnsmasq.conf"
	[ -z "${4}" ] || USERFILE=${4}
	[ -f "${USERFILE}" ] || USERSFILE="/dev/null"

	# first do some number crunching - rewrite the database so that it is sorted
	lock
	touch /tmp/sorted_$$.tmp
	cat ${2} | while IFS=, read MAC PEAKUSAGE_IN PEAKUSAGE_OUT OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT LASTSEEN
	do
		echo ${PEAKUSAGE_IN},${PEAKUSAGE_OUT},${OFFPEAKUSAGE_IN},${OFFPEAKUSAGE_OUT},${MAC},${LASTSEEN} >> /tmp/sorted_$$.tmp
	done
	unlock

	# create HTML page
	echo "<html><head><title>Traffic</title></head><body>" > ${3}
	echo "<h1>Total Usage :</h1>" >> ${3}
	echo "<table border="1"><tr bgcolor=silver><td>User</td><td>Peak download</td><td>Peak upload</td><td>Offpeak download</td><td>Offpeak upload</td><td>Last seen</td></tr>" >> ${3}
	sort -n /tmp/sorted_$$.tmp | while IFS=, read PEAKUSAGE_IN PEAKUSAGE_OUT OFFPEAKUSAGE_IN OFFPEAKUSAGE_OUT MAC LASTSEEN
	do
		USER=$(grep "${MAC}" "${USERSFILE}" | cut -f2 -s -d, )
		[ -z "$USER" ] && USER=${MAC}
		echo "<tr><td>${USER}</td><td>" >> ${3}
		formatnumber "${PEAKUSAGE_IN}}" ${3}
		echo "</td><td>" >> ${3}
		formatnumber "${PEAKUSAGE_OUT}" ${3}
		echo "</td><td>" >> ${3}
		formatnumber "${OFFPEAKUSAGE_IN}" ${3}
		echo "</td><td>" >> ${3}
		formatnumber "${OFFPEAKUSAGE_OUT}" ${3}
		echo "</td><td>" >> ${3}
		echo "${LASTSEEN}" >> ${3}
		echo "</td></tr>" >> ${3}
	done
	echo "</table>" >> ${3}
	echo "<br /><small>This page was generated on `date`</small>" 2>&1 >> ${3}
	echo "</body></html>" >> ${3}
	
	#Free some memory
	rm -f /tmp/*_$$.tmp
	;;

*)
	echo "Usage : $0 {setup|update|publish} [options...]"
	echo "Options : "
	echo "   $0 setup"
	echo "   $0 update database_file [offpeak]"
	echo "   $0 publish database_file path_of_html_report [user_file]"
	echo "Examples : "
	echo "   $0 setup"
	echo "   $0 update /tmp/usage.db offpeak"
	echo "   $0 publish /tmp/usage.db /www/user/usage.htm /jffs/users.txt"
	echo "Note : [user_file] is an optional file to match users with their MAC address"
	echo "       Its format is : 00:MA:CA:DD:RE:SS,username , with one entry per line"
	exit
	;;
esac
