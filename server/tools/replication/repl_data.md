# IBM Security Performance

## Identity and Access Management

### Useful tools

#### repl_data

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
