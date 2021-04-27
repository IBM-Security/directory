# IBM Security Performance

## Identity and Access Management

### Useful tools

#### Replication analysis tools

This directory contains scripts for analyzing (IBM Security Directory Server) SDS replication.  They are built using the [go_ibm_db](https://github.com/ibmdb/go_ibm_db) and [python-ibmdb package](https://github.com/ibmdb/python-ibmdb) drivers.

Running the python versions will require having the [python-ibmdb package](https://github.com/ibmdb/python-ibmdb) installed in addition to a DB2 client. It is recommended to use python3.

Compiling the go versions will require having the [go_ibm_db](https://github.com/ibmdb/go_ibm_db) installed.  
The go binaries in bin/ will run on a Linux system with DB2 installed as they are just linked against libdb2.so.

#### repl_data -
will report on the number of pending changes and the age of the oldest pending change for each consumer of each replication context, based on reading the producer's database.
See [repl data README](repl_data) for more details

#### ldap_sdiff -
will compare all the entries in two SDS instance databases and report on any differences between them, whether missing entries or differences in modify timestamps for matching DNs.

---

Both utilities work by connecting to the underlying database and looking at specific tables, so you will need to run them on a system that has DB2 client installed and has the ability to connect to the database instance ports of the SDS servers.

### Notes:
* The scripts have been tested using a non-TLS enabled port of DB2, which is default for SDS deployments.

* Using the python scripts requires ibm_db python package to be installed. Like so:

`pip install ibm_db`

* If there is no existing DB2 Driver detected then `pip install ibm_db` will attempt a [minimal DB2 driver](https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/linuxx64_odbc_cli.tar.gz) install.

* There are [other DB2 drivers](https://www.ibm.com/support/pages/db2-odbc-cli-driver-download-and-installation-information) that can be installed ahead of the python ibm_db package in case the driver that is installed by it is not desirable or having issues.
