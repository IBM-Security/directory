# IBM Security Directory

## Useful tools

This directory contains various useful tools for analyzing data such as replication status and comparing replicas.

### [Replication tools](replication)
Use repl_data to get information on your replication queues - it includes queue length and date of last change 
replicated. The ldap_sdiff tool is a fast and efficient way to compare the contents between two directories.


### [Maintenance tools](maintenance)
The reorg_minimal script uses reorgchk to determine which tables and indexes need reorg - so
there is no need to do a brute force reorg of all objects in the database. dit_analysis provides 
data on your Directory Information Tree - both CSV and visualization supported.