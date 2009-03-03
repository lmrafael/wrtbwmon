#!/bin/sh
#
# Traffic logging tool for OpenWRT-based routers
#
# Created by Emmanuel Brucy (emmanuel.brucy@gmail.com)
#
# Based on work from Fredrik Erlandsson (erlis@linux.nu)
# Based on traff_graph script by twist - http://wiki.openwrt.org/RrdTrafficWatch

# TWEAKABLES

#Should graphs be generated ? Needs rrdtool (installed through ipkg)
USE_RRDTOOL="yes"

#Day of the month the billing period resets
BILLING_DAY=25

#Peak & Offpeak times - don't forget the 0s
BILLING_OFFPEAK_HOURS="04 05 06 07 08"

#Where the main database will be stored - written to very often and must be persistant across
#reboots in order for this tool to make sens. A cifs share is best suited.
DBFILE="/tmp/rrdbw.db"

#Where the RRD databases will be stored - written to very often and must be persistant across
#reboots in order for this tool to make sens. A cifs share is best suited.
RRD_DIR="/tmp/rrdbw"

#A symlink to the graphs will be placed there - choose a path the internal web server has access to
HTML_DIR="/tmp/rrdbw"

#Some temporary files, does not matter if they are lost. Get written to pretty often.
ARPFILE="/tmp/arpfile.log"

#Interface names
IF_LAN=`nvram get lan_ifname`


updatefilters()
{
	#Create the RRDIPT CHAIN (it doesn't matter if it already exists).
	iptables -N RRDIPT 2> /dev/null

	#Add the RRDIPT CHAIN to the FORWARD chain (if non existing).
	iptables -L FORWARD -n | grep RRDIPT > /dev/null
	if [ $? -ne 0 ]; then
		echo "iptables chain not found, creating it..."
		iptables -I FORWARD -j RRDIPT
	fi

	#For each host in the ARP table
	grep $IF_LAN /proc/net/arp | while read IP TYPE FLAGS MAC MASK IFACE
	do
		if [ ! $IP ]; then 
			continue
		fi

		CURRHOST="$MAC $IP"

		echo "Checking counters for $CURRHOST..."

		#Is MAC is assigned to the same IP as last time ?
		touch "$ARPFILE"
		grep "$CURRHOST" "$ARPFILE" > /dev/null
		if [ $? -ne 0 ]; then
			echo "New/modified entity : $MAC / $IP"
			
			#Add iptable rules (if non existing).
			iptables -nL RRDIPT | grep $IP > /dev/null
			if [ $? -ne 0 ]; then
				iptables -I RRDIPT -d $IP -j RETURN
				iptables -I RRDIPT -s $IP -j RETURN
			fi

			#Update the ARP file
			grep -v "$MAC" "$ARPFILE" | grep -v $IP > "$ARPFILE.new"
			mv "$ARPFILE.new" "$ARPFILE"
			echo ${CURRHOST} >> "$ARPFILE"
		fi
	done	
}


createDb()
{
	mkdir -p $RRD_DIR
	rrdtool create "$RRD_DIR/$1" \
		--start `date +%s` \
		--step 300 \
		DS:in_peak:ABSOLUTE:600:0:U \
		DS:out_peak:ABSOLUTE:600:0:U \
		DS:in_offpeak:ABSOLUTE:600:0:U \
		DS:out_offpeak:ABSOLUTE:600:0:U \
		RRA:AVERAGE:0.5:1:288 \
		RRA:AVERAGE:0.5:288:31
}

updategraphs()
{
	echo "Updating graphs..."
	touch $DBFILE

	#Read and reset counters
	iptables -L RRDIPT -vnxZ -t filter > /tmp/traffic.tmp

	cat "$ARPFILE"| while read MAC IP
	do
		#Add new data to the graph.
		IN=$(cat /tmp/traffic.tmp|awk "{if (\$8 == \"$IP\") print \$2}" | tr -d '\n')
		OUT=$(cat  /tmp/traffic.tmp|awk "{if (\$9 == \"$IP\") print \$2}" | tr -d '\n')
		echo "New traffic for $MAC since last update : $IN:$OUT"
		
		PEAKUSAGE_IN=$(grep $MAC $DBFILE | awk '{print $2}')
		PEAKUSAGE_OUT=$(grep $MAC $DBFILE | awk '{print $3}')
		OFFPEAKUSAGE_IN=$(grep $MAC $DBFILE | awk '{print $4}')
		OFFPEAKUSAGE_OUT=$(grep $MAC $DBFILE | awk '{print $5}')		
		
		if [ "$USE_RRDTOOL" = "yes" ]; then
			GRAPH="$RRD_DIR/$MAC.rrd"
			if [ ! -f "$GRAPH" ]; then
				echo "$GRAPH is missing, recreating it"
				createDb "$MAC.rrd"
			fi
		fi
		
		echo "$BILLING_OFFPEAK_HOURS" | grep `date +%H`  > /dev/null
		if [ $? -ne 0 ]; then
			#Peak hour
			PEAKUSAGE_IN=$(($PEAKUSAGE_IN+$IN))
			PEAKUSAGE_OUT=$(($PEAKUSAGE_OUT+$OUT))

			[ "$USE_RRDTOOL" = "yes" ] && rrdtool update "$GRAPH" N:$IN:$OUT:0:0
		else
			#Offpeak hour
			OFFPEAKUSAGE_IN=$(($OFFPEAKUSAGE_IN+$IN))
			OFFPEAKUSAGE_OUT=$(($OFFPEAKUSAGE_OUT+$OUT))

			[ "$USE_RRDTOOL" = "yes" ] && rrdtool update "$GRAPH" N:0:0:$IN:$OUT
		fi

		grep -v "$MAC" "$DBFILE" > /tmp/db.new
		mv /tmp/db.new "$DBFILE"
		echo $MAC $PEAKUSAGE_IN $PEAKUSAGE_OUT $OFFPEAKUSAGE_IN $OFFPEAKUSAGE_OUT >> "$DBFILE"

	done
	
	#Free some memory
	rm /tmp/traffic.tmp
}

# $1 = ImageFile, $2 = Start Time, $3 = End Time, $4 = RRDfile, $5 = GraphText
CreateGraph ()
{
	#Escape the : in the file name
	F=$(echo $4| sed 's/:/\\:/g')

        rrdtool graph "$1" -a PNG -s $2 -e $3 -w 550 -h 240 -v "bytes/s" -t "${5}" --lazy \
                DEF:in_peak="$F":in_peak:AVERAGE AREA:in_peak#FF0000:"Download (peak)" LINE1:in_peak#000000 \
                DEF:out_peak="$F":out_peak:AVERAGE AREA:out_peak#FFFF00:"Upload (peak)" LINE1:out_peak#000000 \
                DEF:in_offpeak="$F":in_offpeak:AVERAGE AREA:in_offpeak#00FF00:"Download (offpeak)" LINE1:in_offpeak#000000 \
                DEF:out_offpeak="$F":out_offpeak:AVERAGE AREA:out_offpeak#0000FF:"Upload (offpeak)" LINE1:out_offpeak#000000
}

draw_graphic()
{
	F=$(echo $6| sed 's/:/\\:/g')
	
	echo "Generating: $1"
	
	rrdtool graph "$1" -s $2 -e $3 -a PNG\
	-t "Net usage for $4" \
	-h 140 -w 600 \
	-l 1 \
	--logarithmic \
	-r \
	-v bits/sec \
	--lazy \
	DEF:in_="$RRD_DIR/$F.rrd":in:AVERAGE \
	DEF:out_="$RRD_DIR/$F.rrd":out:AVERAGE \
	CDEF:in=in_,8,* \
	CDEF:out=out_,8,* \
	CDEF:eth0_bytes_in=in_,$2,-1,*,* \
	CDEF:eth0_bytes_out=out_,$2,-1,*,* \
	CDEF:eth0_bytes=eth0_bytes_in,eth0_bytes_out,+ \
	AREA:in#32CD32:Incoming \
	LINE1:in#336600 \
	GPRINT:in:MAX:'Max\: %5.1lf %s' \
	GPRINT:in:AVERAGE:'Avg\: %5.1lf %S' \
	GPRINT:in:LAST:'Current\: %5.1lf %Sbits/sec' \
	GPRINT:eth0_bytes_in:AVERAGE:'Total\: %7.2lf %sB\\n' \
	LINE1:out#0033CC:Outgoing \
	GPRINT:out:MAX:'Max\: %5.1lf %s' \
	GPRINT:out:AVERAGE:'Avg\: %5.1lf %S' \
	GPRINT:out:LAST:'Current\: %5.1lf %Sbits/sec' \
	GPRINT:eth0_bytes_out:AVERAGE:'Total\: %7.2lf %sB\\n' \
	COMMENT:" \n" \
	GPRINT:eth0_bytes:AVERAGE:'Input + Output\: %7.2lf %sB' \
	COMMENT:" \n" \
	COMMENT:"$5\n"
	#CDEF:eth0_bytes_out=out_,0,12500000,LIMIT,UN,1,out_,IF,86400,* \
}

publishgraphs()
{
	#Values for the daily graph
	NOW=`date +%s`
	ONE_DAY_AGO=$(($NOW-86400))

	#Values for the billing graph
	MONTH=`date +%m`
	YEAR=`date +%Y`
	CLOSEST=`date -d ${MONTH}250000${YEAR} +%s`
	if [ $NOW -ge $CLOSEST ]; then
		#Second half
		MONTH=`awk 'BEGIN {printf("%0.2d\n", '$(expr $MONTH + 1)')}'` # Good thing date accepts 13th month !
		CURRENT_BILLING_START=$CLOSEST
		CURRENT_BILLING_STOP=`date -d ${MONTH}250000${YEAR} +%s`
	else
		#First half
		MONTH=`awk 'BEGIN {printf("%0.2d\n", '$(expr $MONTH - 1)')}'`  # Hopefully date accepts if month = 0 too !
		CURRENT_BILLING_START=`date -d ${MONTH}250000${YEAR} +%s`
		CURRENT_BILLING_STOP=$CLOSEST
	fi
	
	# create HTML page
	echo "<html><head><title>Traffic</title></head><body>" > $HTML_DIR/index.htm
	echo "<h1>Traffic</h1>" >> $HTML_DIR/index.htm
	echo "This page was generated on `date`" >> $HTML_DIR/index.htm

	if [ "$USE_RRDTOOL" = "yes" ]; then
		for FILE in $RRD_DIR/*.rrd
		do
			PREFIX=`basename $FILE .rrd`
	#		draw_graphic "${PREFIX}_last_day.png" $ONE_DAY_AGO $NOW "$PREFIX (last 24 hours)" "$TIMESTAMP" $FILE
			CreateGraph "$HTML_DIR/${PREFIX}_last_day.png" $ONE_DAY_AGO $NOW $FILE "Usage for the last 24 hours"
			CreateGraph "$HTML_DIR/${PREFIX}_billing.png" $CURRENT_BILLING_START $CURRENT_BILLING_STOP $FILE "Usage for the current billing period"
			echo "<br><h2>Usage for ${PREFIX} :</h2><br>" >> $HTML_DIR/index.htm
			echo "<img src='${PREFIX}_last_day.png' />" >> $HTML_DIR/index.htm
			echo "<img src='${PREFIX}_billing.png' />" >> $HTML_DIR/index.htm
		done
	fi
	echo "</body></html>" >> $HTML_DIR/index.htm
}

case $1 in
"updatefilters" )
	updatefilters
	;;
"updategraphs" )
	updategraphs
	;;
"publishgraphs" )
	publishgraphs
	;;
*)
	echo "TODO : help file"
	exit
	;;
esac
