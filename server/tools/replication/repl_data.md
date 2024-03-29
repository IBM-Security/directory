# IBM Security Performance

## Identity and Access Management

### Useful tools

#### repl_data
##### usage

```
usage: repl_data [-h] --dbname DBNAME [--hostname HOSTNAME] [--port PORT]
                 [--schema SCHEMA] [--userid USERID] --password PASSWORD
                 [--loglevel {DEBUG,INFO,ERROR,CRITICAL}]
                 [--outputcsv {true,y,yes,1,on,false,n,no,0,off}]
                 [--output_file OUTPUT_FILE]

Provide DB2 connection details to determine replication status.

optional arguments:
  -h, --help            show this help message and exit
  --dbname DBNAME       DB2 Database Name underlying LDAP.
  --hostname HOSTNAME   Hostname of LDAP server (defaults to localhost).
  --port PORT           Port# DB2 is listening on (defaults to 50000).
  --schema SCHEMA       DB2 Table name schema (defaults to userid).
  --userid USERID       Userid to connect to DB2 (defaults to dbname).
  --password PASSWORD   Password to connect to DB2.
  --loglevel {DEBUG,INFO,ERROR,CRITICAL}
                        Logging Level (defaults to CRITICAL).
  --outputcsv {true,y,yes,1,on,false,n,no,0,off}
                        Test output or CSV format (defaults to False).
  --output_file OUTPUT_FILE
                        Output CSV of differences (defaults to stdout).
```

##### output formats
repl_data can produce either text or csv formatted output.  The columns in the csv format are described in its header:

```
Legend for output:
  context - suffix or context present in server (may or may not be replicated).
  consumer - hostname or ip address of server data is being replicated to.
  successfulTimestamp - last successful change that was replicated.
  pendingTimestamp - oldest pending change that needs to be replicated.
  queueSize - number of objects pending in replication queue.

Note: Timestamps are provided in UTC timezone.

```

##### example output

```
context         consumer        successfulTimestamp     pendingTimestamp        queueSize
CN=IBMPOLICIES  replica1         9/13/2016 1:41:48       9/23/2016 19:45:44      132
```

In this example:
- There are 132 changes pending to replicate
- The last last successful change replicated from the master to this consumer (replica1) was at 9/13/2016 1:41:48
- The time stamp of the first pending change is 9/23/2016 19:45:44


```
context         consumer        successfulTimestamp     pendingTimestamp        queueSize
CN=IBMPOLICIES  replica2        10/14/2016 20:15:14             
```

In this example:
-  there are no pending changes, so pendingTimestamp and queueSize were not populated


