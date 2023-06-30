# IBM Security Directory

## Miscellaneous tools
**ldif2csv** - this script is currently only in python format. It is best used using python3. 
The decode option may have issues when used in python2.

This script is meant to convert any valid LDIF file into a corresponding CSV format. If you choose to create a CSV with a header - then the script parses the entire LDIF file into memory and assesses all the potential attributes for headers and then writes out a CSV file.
This is expected to be memory intensive for very large files.

**mon_high_cpu_queries.sh** - this script is designed to dump sysibmadm.mon_current_sql when
CPU on the server exceeds a pre-determined limit. This data will allow for analysis of the DB2
queries that drive CPU usage to high values. There is a chance that high CPU could be driven by 
non-DB2 processes. Script could be run every minute - it has been tested running
every 5minutes.

One option for setting it up to run in crontab every 5mins as root follows (assuming instance owner and database are both idsldap and 50% is
the pre-determined CPU limit):

```*/5 * * * * /bin/su - idsldap -c "/home/idsldap/scripts/mon_high_cpu_queries.sh idsldap 50" >> /tmp/mhcq.log 2>&1```