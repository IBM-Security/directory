# IBM Security Directory

## Useful tools

This directory contains various useful tools for maintenance of data in directory server.

### Maintenance tools
reorg_minmal - this script assumes that runstats is current and uses that to determine tables
and indexes that need REORG. Then it can either generate the commands to execute or run the commands
itself. It has some smarts like assuming that REORG runs in the background and will wait for
completion before updating the reorg'ed objects with a runstat.

This tool can be used for regular DB2 databases - i.e., not used by SDS.
