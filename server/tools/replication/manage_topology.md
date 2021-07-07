# IBM Security Performance

## Identity and Access Management

### Useful tools

#### manage_topology

##### usage
```
usage: manage_topology.py [-h] [-f F] [-host HOSTNAME] [-p PORT] [-D D] [-w W]
                          [-sc {Z,Y}] [-K K] [-P P] [-op {search,delete,test}]
                          [-s S] [-r {n,y}] [-o {1,2}] [-d {n,no,y,yes}]
                          [-search SEARCH] [-delete DELETE] [-modify MODIFY]

Parse Replication topology from an output file or manage directly from LDAP Server.

Note: When connecting directly to LDAP server: 
    * Set env. variable IDS_LDAP_HOME to <SDS 6.x install path or SDS 6.x client library location> 
      to use idsldapsearch, idsldapmodify, idsldapdelete utilities.
      - eg. Unix/Linux: export IDS_LDAP_HOME=/opt/ibm/ldap/V6.4
            Windows:    set IDS_LDAP_HOME=<drive>:\Program Files\ibm\ldap\V6.4

      - If no value is found for IDS_LDAP_HOME then tool will default to:
            Unix/Linux: /opt/{IBM|ibm}/ldap/V6.4
            Windows: C:\Program Files\ibm\ldap\V6.4
    * When testing Topology: If Servers replicate over SSL port then -K and -P parameters are required.

optional arguments:
  -h, --help            show this help message and exit
  -f F                  File containing Replication Topology.
  -host HOSTNAME, --hostname HOSTNAME
                        LDAP Hostname.
  -p PORT, --port PORT  Port# where LDAP instance is listening on (eg. SSL 636 or Non-SSL 389) - (defaults to 389).
  -D D                  Bind DN of LDAP Instance (defaults to cn=root).
  -w W                  Password of Bind DN.
  -sc {Z,Y}             secure Protocol (Z for SSL or Y for TLS) - (defaults to Z).
  -K K                  SSL .kdb file to search over SSL port.
  -P P                  SSL .kdb password.
  -op {search,delete,test}
                        Operation: search/parse, delete, or test replication topology.
  -s S                  Suffix to manage (eg. cn=ibmpolicies). When deleting topology 'all' can be used 
                        to delete entire topology (for all suffixes).
  -r {n,y}              Replicate change - (defaults to n/No).
  -o {1,2}, --output {1,2}
                        Textual (1) or Graphical (2) display of Replication Topology (defaults to 1).
 -d {n,no,y,yes}, --details {n,no,y,yes}
                        Return more details of consumer servers (hostname, serverid, credential dn) -(defaults to no).
  -search SEARCH        idsldapsearch (defaults to /opt/ibm/ldap/V6.4/bin/idsldapsearch).
  -delete DELETE        idsldapdelete (defaults to /opt/ibm/ldap/V6.4/bin/idsldapdelete).
  -modify MODIFY        idsldapmodify (defaults to /opt/ibm/ldap/V6.4/bin/idsldapmodify).

*Output (-o) 1 will return agreements for all contexts at once and output (-o) 2 one context at a time.   

Examples:

  >>Parse Replication topology
  - It will return Replication contexts, credentials, groups, and subentries + Supplier->Consumer relationships/agreements per context.
    From file:
    python3 manage_topology.py -f <ReplicationTopology.ldif>
         
    From server:
    python3 manage_topology.py -host <hostname/IP> -p <port#> -D <bindD> -w <password>

  >>Test current Replication topology: one <context/suffix> at a time
  - A Test entry will be created, searched, and deleted on behalf of a Supplier on all its consumers using the replication credentials.
    python3 manage_topology.py -host <hostname/IP> -p <port#> -D <bindD> -w <password> -s <context/suffix> -op test
    
  >>Delete current Replication Topology: one <context/suffix> at a time or type 'all' to delete topology for all contexts
  - It will delete agreements, subentries, groups, credentials, and repl. context objectclass + referrals (if any) - in that order.
    python3 manage_topology.py -host <hostname/IP> -p <port#> -D <bindD> -w <password> -s <context/suffix> -op delete
```

manage_topology can parse, test, and delete replication topology.
During parsing all servers will be identified with their corresponding roles:
- Roles: (G)Gateway (M)Master (R)Replica (U)Undefined - missing subentry.

##### Parsing example
```
python3 manage_topology.py -D cn=root -w ? -host localhost -p 8389
[#]Replication Contexts: 
------------------------
[1] o=sample
[2] cn=ibmpolicies

[#]Replication Credentials: 
----------------DN-----------------USER_ID-------PASSWORD
[1] cn=replicabindcredentials,cn=ibmpolicies  cn=iamsupplier  !@msupplier123
[2] cn=replicabindcredentials,o=sample  cn=iamsupplier  !@msupplier123

[#]Replication Groups: 
----------------------
[1] ibm-replicaGroup=default,o=sample
[2] IBM-REPLICAGROUP=DEFAULT,CN=IBMPOLICIES

[#]Replication Subentries: 
--------------------------
[#] [*** Subentries for Context o=sample ***---------SERVER_ID-----SERVER_ROLE]
[1] cn=sdspeer4,ibm-replicaGroup=default,o=sample   sdspeer4  Master
[2] cn=sdspeer3,ibm-replicaGroup=default,o=sample   sdspeer3  Master
[3] cn=sds801gateway,ibm-replicaGroup=default,o=sample   sds801gateway  Gateway
[4] cn=sds64gateway,ibm-replicaGroup=default,o=sample   sds64gateway  Gateway


[#] [*** Subentries for Context cn=ibmpolicies ***---------SERVER_ID-----SERVER_ROLE]
[1] cn=sdspeer3,ibm-replicaGroup=default,cn=ibmpolicies   sdspeer3  Master
[2] cn=sdspeer4,ibm-replicaGroup=default,cn=ibmpolicies   sdspeer4  Master
[3] cn=sds801gateway,ibm-replicaGroup=default,cn=ibmpolicies   sds801gateway  Gateway
[4] cn=sds64gateway,ibm-replicaGroup=default,cn=ibmpolicies   sds64gateway  Gateway


[#]Replication Agreements: 
----------------------------------------------------------------------------             
Roles: (G)Gateway, (M)Master, (R)Replica, or (U)Undefined - missing subentry.             
----------------------------------------------------------------------------
[#][Context: o=sample (8 agreements)]
----------------------------------------------------------------------------
Supplier:     ⬐ (G)cn=sds801gateway
Consumer(1):  ⮑ (G)cn=sds64gateway 

Supplier:      ⬐ (M)cn=sdspeer3
Consumers(2):  ⮑ (G)cn=sds64gateway 
               ⮑ (M)cn=sdspeer4 

Supplier:      ⬐ (M)cn=sdspeer4
Consumers(2):  ⮑ (M)cn=sdspeer3 
               ⮑ (G)cn=sds64gateway 

Supplier:      ⬐ (G)cn=sds64gateway
Consumers(3):  ⮑ (M)cn=sdspeer4 
               ⮑ (G)cn=sds801gateway 
               ⮑ (M)cn=sdspeer3 
----------------------------------------------------------------------------
[#][Context: CN=IBMPOLICIES (8 agreements)]
----------------------------------------------------------------------------
Supplier:      ⬐ (G)cn=sds64gateway
Consumers(3):  ⮑ (M)cn=sdspeer3
               ⮑ (M)cn=sdspeer4 
               ⮑ (G)cn=sds801gateway 

Supplier:      ⬐ (M)cn=sdspeer3
Consumers(2):  ⮑ (M)cn=sdspeer4 
               ⮑ (G)cn=sds64gateway 

Supplier:     ⬐ (G)cn=sds801gateway
Consumer(1):  ⮑ (G)cn=sds64gateway 

Supplier:      ⬐ (M)cn=sdspeer4
Consumers(2):  ⮑ (M)cn=sdspeer3 
               ⮑ (G)cn=sds64gateway
----------------------------------------------------------------------------
```
##### Testing example
```
python3 manage_topology.py -D cn=root -w ? -K <name>.kdb -P <kdb_pwd> -host localhost -p 8636 -op test -s o=sample
--------------------------------------------------------------------------------------------------------------
Final Result can be:
(YES) or (NO) - meaning Supplier can or can't replicate to Consumer using the defined Replication Credentials.
(YES) is based on successful add, search, & delete of the Test user and (No) if any of those operations fails.
--------------------------------------------------------------------------------------------------------------
                              [Start] Testing for Replication context: o=sample.
--------------------------------------------------------------------------------------------------------------
Credential: cn=replicabindcredentials,o=sample 
Test user:  cn=sdspeer3 TestUser,o=sample
--------------------------------------------------------------------------------------------------------------
Testing Replication between  ⬐  Supplier (cn=sdspeer3)
                             ⮑  Consumer (cn=sdspeer4) -> (<hostname>:9636)
                             ⮑  Consumer (cn=sds64gateway) -> (<hostname>:10636)

Final Result:
Supplier:       ⬐  cn=sdspeer3
Consumers(2): (YES)cn=sdspeer4
              (YES)cn=sds64gateway
--------------------------------------------------------------------------------------------------------------
Credential: cn=replicabindcredentials,o=sample 
Test user:  cn=sdspeer4 TestUser,o=sample
--------------------------------------------------------------------------------------------------------------
Testing Replication between  ⬐  Supplier (cn=sdspeer4)
                             ⮑  Consumer (cn=sdspeer3) -> (<hostname>:8636)
                             ⮑  Consumer (cn=sds64gateway) -> (<hostname>:10636)

Final Result:
Supplier:       ⬐  cn=sdspeer4
Consumers(2): (YES)cn=sdspeer3
              (YES)cn=sds64gateway
--------------------------------------------------------------------------------------------------------------
Credential: cn=replicabindcredentials,o=sample 
Test user:  cn=sds64gateway TestUser,o=sample
--------------------------------------------------------------------------------------------------------------
Testing Replication between  ⬐  Supplier (cn=sds64gateway)
                             ⮑  Consumer (cn=sdspeer3) -> (<hostname>:8636)
                             ⮑  Consumer (cn=sdspeer4) -> (<hostname>:9636)

Final Result:
Supplier:       ⬐  cn=sds64gateway
Consumers(2): (YES)cn=sdspeer3
              (YES)cn=sdspeer4
--------------------------------------------------------------------------------------------------------------
                              [End] Testing for Replication context: o=sample.
--------------------------------------------------------------------------------------------------------------
```
#### Deleting example
```
python3 manage_topology.py -D cn=root -w ? -host localhost -p 8389 -op delete -s all 
Are you sure you want to delete the entire Replication topology?[y/Yes - n/No]: Yes

***Deleting Replication agreements for: o=sample***
Deleting entry cn=sds64gateway,cn=sdspeer3,ibm-replicagroup=default,o=sample
Deleting entry cn=sdspeer4,cn=sdspeer3,ibm-replicagroup=default,o=sample
Deleting entry cn=sdspeer3,cn=sdspeer4,ibm-replicagroup=default,o=sample
Deleting entry cn=sds64gateway,cn=sdspeer4,ibm-replicagroup=default,o=sample
Deleting entry cn=sdspeer4,cn=sds64gateway,ibm-replicagroup=default,o=sample
Deleting entry cn=sdspeer3,cn=sds64gateway,ibm-replicagroup=default,o=sample

***Deleting Replication agreements for: cn=ibmpolicies***
Deleting entry cn=sdspeer3,cn=sds64gateway,ibm-replicagroup=default,cn=ibmpolicies
Deleting entry cn=sdspeer4,cn=sdspeer3,ibm-replicagroup=default,cn=ibmpolicies
Deleting entry cn=sds64gateway,cn=sdspeer3,ibm-replicagroup=default,cn=ibmpolicies
Deleting entry cn=sdspeer4,cn=sds64gateway,ibm-replicagroup=default,cn=ibmpolicies
Deleting entry cn=sdspeer3,cn=sdspeer4,ibm-replicagroup=default,cn=ibmpolicies
Deleting entry cn=sds64gateway,cn=sdspeer4,ibm-replicagroup=default,cn=ibmpolicies

***Deleting Replication subentries for: o=sample***
Deleting entry  cn=sdspeer4,ibm-replicaGroup=default,o=sample
Deleting entry  cn=sdspeer3,ibm-replicaGroup=default,o=sample
Deleting entry  cn=sds64gateway,ibm-replicaGroup=default,o=sample

***Deleting Replication subentries for: cn=ibmpolicies***
Deleting entry  cn=sdspeer3,ibm-replicaGroup=default,cn=ibmpolicies
Deleting entry  cn=sdspeer4,ibm-replicaGroup=default,cn=ibmpolicies
Deleting entry  cn=sds64gateway,ibm-replicaGroup=default,cn=ibmpolicies

***Deleting Replication group for: o=sample***
Deleting entry ibm-replicaGroup=default,o=sample

***Deleting Replication group for: cn=ibmpolicies***
Deleting entry IBM-REPLICAGROUP=DEFAULT,CN=IBMPOLICIES

***Deleting Replication credential for: all***
Deleting entry cn=replicabindcredentials,cn=ibmpolicies
Deleting entry cn=replicabindcredentials,o=sample

***Deleting ibm-replicationcontext from: o=sample***
Operation 0 modifying entry o=sample

***Deleting ibm-replicationcontext from: cn=ibmpolicies***
Operation 0 modifying entry cn=ibmpolicies
```

Pre-requisites:
- pip3 install networkx
- pip3 install matplotlib
