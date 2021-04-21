# IBM Security Directory

## Useful tools

This directory contains various useful tools for maintenance of data in directory server.

### Maintenance tools
reorg_minmal - this script assumes that runstats is current and uses that to determine tables
and indexes that need REORG. Then it can either generate the commands to execute or run the commands
itself. It has some smarts like assuming that REORG runs in the background and will wait for
completion before updating the reorg'ed objects with a runstat.

This tool can be used for regular DB2 databases - i.e., those not used by SDS.

dit_analysis - this script analyzes the entries in the Directory and creates a summary of
the data found in both a CSV format as well a visual Directory Information Tree. It runs directly against
the DB2 database underlying SDS - and assumes that the LDAP_ENTRY table is present.

The CSV output includes the max/min modify and create timestamps, the DIT simply
has the counts with the structure of the tree laid out.

Empty containers will not show up with this script, so if you just created a new OU
the script will not show it until it contains one object.
