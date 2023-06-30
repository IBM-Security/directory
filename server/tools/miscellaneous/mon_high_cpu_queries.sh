#!/bin/bash
#
# ==============================================================================
# Purpose:           Monitor for high CPU, in which case dump mon_current_sql
# Author:            Ram Sreerangam
# Notes:             The dumped out data is in CSV format. It is expected that 
#                    this data be consumed by NewRelic or Instana.
#                    select * has been used - it is upto user to figure out column
#                    sequence in output CSV and also differences between DB2 versions
# Parameters:        1. REQUIRED: Pass a valid DB Alias to connect to, it is
#                                 assumed instance owner will run this script.
#                                 Connect will be attempted with no id/password!
#                    2. OPTIONAL: Pass a percentage value to use for CPU threshold
#                                 (defaults to 50%)
# Revision:          2023-03-28: Initial version
#                    2023-03-30: Converted to using top from /proc/loadavg
#                    2023-03-30: Added logic to stop when HADR STANDBY is detected
#                                (may need to be reconsidered if STANDBYs are READONLY)
# ==============================================================================
#
SECONDS=0
outputdir='/tmp'
echo "Starting script $0 at $(date +%Y-%m-%d_%H:%M:%S.%N)"
if [ "$#" -eq 0 ]; then
	echo "Please pass a valid database alias to connect to!" >&2
	echo "  Usage: $0 <DB Alias> <CPU% Threshold (default 50)>" >&2
	exit 1
fi
dbalias=${1}

HADR_ROLE_STR=$(db2 get db cfg for $dbalias | grep "HADR database role")
if [ $? -gt 0 ]; then
        echo "Unable to determine HADR Role - probably an invalid DB Alias, please try with a valid one!" >&2
        exit 3
fi

HADR_ROLE=$(echo $HADR_ROLE_STR | awk '{print($5)}')
if [ "$HADR_ROLE" = "STANDBY" ]; then
        echo "HADR STANDBY detected, unable to do anything useful - quitting script!" >&2
        exit 4
fi

# CPU percentage that will trigger the dump of mon_current_sql
if [ "$#" -gt 1 ]; then
	re='^[0-9]+$'
	if ! [[ ${2} =~ $re ]] || [ ${2} -lt 0 ] || [ ${2} -gt 100 ] ; then
		echo "Please pass a valid CPU% threshold - a value between 0-100." >&2
		exit 2
	fi
	CPU_THRESHOLD=${2}
else
	# Defaulting value
	CPU_THRESHOLD=50
fi

# This extracts loadavg which is not CPU% - there might be another proc to get CPU...
#CUR_CPU_FLOAT=`/usr/bin/cat /proc/loadavg | awk '{print $1}'`
# Extract the current idle CPU usage level in the server
IDLE_CPU_FLOAT=$(top -bn1 | awk '/Cpu/ { print $8 }') 
# Converting to rounded integer - and convert idle CPU%
CUR_CPU=`echo "(100-$IDLE_CPU_FLOAT+0.5)/1" | bc`

if [ $CUR_CPU -ge $CPU_THRESHOLD ]; then
	echo "Current CPU ${CUR_CPU}% matches/exceeded threshold of ${CPU_THRESHOLD}% - dumping mon_current_sql."
	db2 connect to ${dbalias}
	if [ $? -gt 0 ]; then
		echo "Invalid DB Alias, please try with a valid one!" >&2
		exit 3
	fi
	dump_file="${outputdir}/mon_current_sql_${dbalias}_$(date +%Y%m%d%H%M%S).csv"
	db2 "export to ${dump_file} of del select * from sysibmadm.mon_current_sql"
	echo "Check ${dump_file} for extracted data."
else
	echo "Current CPU ${CUR_CPU}% does not exceed threshold of ${CPU_THRESHOLD}%."
	echo "Removing logs older than 1 month - cleanup done during lower CPU usage."
	find ${outputdir} -name "mon_current_sql_${dbalias}_*" -mtime +30 -exec rm {} \; 2>&1 | grep -v "Permission denied"
fi

echo "Ending script, ${SECONDS}secs execution, at $(date +%Y-%m-%d_%H:%M:%S.%N)."

