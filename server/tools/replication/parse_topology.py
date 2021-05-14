import os
import subprocess
import datetime
import sys
import re
import networkx as nx
import matplotlib.pyplot as plt
import argparse
import textwrap

ServerRoles = dict()

def CheckForWrappedLines(cleanstanza):
    goodObj = dict()
    oldK = ""
    oldV = ""
    for i in range(len(cleanstanza)):
        for object in cleanstanza[i]:
            for key, value in list(object.items()):
                if (len(value) > 0):
                    oldK = key
                    oldV = value.strip("\n")
                    goodObj = object
                else:
                    goodObj.update({oldK: (oldV + key.strip())})
                    del object[key]
    return cleanstanza

def GetReplObjectDN(myobject):
    objectdn = []
    for mo in myobject:
        for o in mo:
            for key, value in o.items():
                if (key == "dn"):
                    objectdn.append(value.strip())
    return objectdn

def GetReplicationContexts(lContext):
    newListContext = []
    for context in lContext:
        for co in context:
            for key, value in co.items():
                if (key == "dn"):
                    newListContext.append(value.strip())
    return newListContext

def ParseReplicationContexts(listContexts):
    print("[#]Replication Contexts: \n------------------------")
    contexts = GetReplObjectDN(listContexts)
    for num, context in enumerate(contexts, start=1):
        print("[{0}]{1}".format(num, context))

def ParseReplicationCredentials(listCredentials):
    print("\n[#]Replication Credentials: \n----------------DN-----------------USER_ID-------PASSWORD")
    newDictCredentials = {}
    for num, credential in enumerate(listCredentials, start=1):
        for line in credential:
            for key, value in line.items():
                nKey = key.lower()
                if (nKey == "dn"):
                    newDictCredentials[nKey] = value
                elif (nKey == "replicabinddn"):
                    newDictCredentials[nKey] = value
                elif (nKey == "replicacredentials"):
                    newDictCredentials[nKey] = value
        print("[{0}]{dn} {replicabinddn} {replicacredentials}".format(num, **newDictCredentials))


def ParseReplicationGroups(listGroups):
    print("\n[#]Replication Groups: \n----------------------")
    groups = GetReplObjectDN(listGroups)
    for num, group in enumerate(groups, start=1):
        print("[{0}]{1}".format(num, group))

def ProcessContextSubentries(subentry):
    newDictSubentries = {}
    for line in subentry:
        for key, value in line.items():
            if (key == "dn"):
                newDictSubentries[key] = value
            elif (key == "ibm-replicationserverismaster"):
                newDictSubentries[key] = value
            elif (key == "objectclass" and value.strip() == "ibm-replicaGateway"):
                newDictSubentries[value.strip()] = "true"
            elif (key == "ibm-replicaserverid"):
                newDictSubentries[key] = value
    return newDictSubentries

def GetServerRole(server):
    return ServerRoles[server]

def GetReplAgreementSubentryDN(newListContext, replobject):
    newreplobject = []
    finalreplobject = []

    for ro in replobject:
        for o in ro:
            for key, value in o.items():
                if (key == "dn"):
                    newreplobject.append(dict([(value, ro)]))

    for context in newListContext:
        currentContext = context.strip().lower()
        for ro in newreplobject:
            for replContext, replob in ro.items():
                if (currentContext in replContext.strip()):
                    finalreplobject.append(dict([(currentContext, replob)]))
    return finalreplobject

def ParseSubentryPerContext(lContext, lSubentry):
    newListContext = GetReplObjectDN(lContext)
    newlSubentry = CheckForWrappedLines(lSubentry)
    replContextSubentry = GetReplAgreementSubentryDN(newListContext, newlSubentry)

    numSubentry = 0
    print("\nReplication Subentries: \n-----------------------")
    for context in newListContext:
        print(
            "[#] [*** Subentries for Context {0} ***---------SERVER_ID-----IS MASTER?-----IS GATEWAY?]".format(context))
        for num, sub in enumerate(replContextSubentry, start=1):
            for keyContext, subentry in sub.items():
                if (context.strip().lower() == keyContext.strip().lower()):
                    numSubentry += 1
                    if ("ibm-replicaGateway" in ProcessContextSubentries(subentry)):
                        dn = ProcessContextSubentries(subentry)['dn'].split(",", 1)[0]
                        ServerRoles[dn.strip()] = "G"
                        print("[{0}][{1}]{dn} {ibm-replicaserverid} {ibm-replicationserverismaster} {ibm-replicaGateway}".format(num, numSubentry, **ProcessContextSubentries(subentry)))
                    else:
                        dn = ProcessContextSubentries(subentry)['dn'].split(",", 1)[0]
                        role = ProcessContextSubentries(subentry)['ibm-replicationserverismaster'].strip().lower()
                        if role.strip() == "true":
                            ServerRoles[dn.strip()] = "M"
                        else:
                            ServerRoles[dn.strip()] = "R"
                        print("[{0}][{1}]{dn} {ibm-replicaserverid} {ibm-replicationserverismaster} False".format(num,numSubentry,**ProcessContextSubentries(subentry)))
        numSubentry = 0
        print("\n")

def ProcessContextAgreements(listAgreements):
    newDictAgreements = {}
    for g in listAgreements:
        for key, value in g.items():
            if (key == "dn"):
                newDictAgreements[key] = value
            elif (key == "ibm-replicaconsumerid"):
                newDictAgreements[key] = value
            elif (key == "ibm-replicaurl"):
                newDictAgreements[key] = value
            elif (key == "ibm-replicacredentialsdn"):
                newDictAgreements[key] = value
    return newDictAgreements

def VisualizeReplTopology(ConsumersPerSupplier):
    args = get_arguments()
    G = nx.DiGraph()
    print(
        "[#]Replication Agreements: \n--------------------------------------\nRoles: (G)Gateway (M)Master (R)Replica\n--------------------------------------")
    for context, consumerlist in ConsumersPerSupplier.items():
        print("[#][Context: {}]".format(context))
        for supplier, consumers in consumerlist.items():
            roleS = GetServerRole(supplier.strip())
            if (len(consumers) == 1):
                print("Supplier:    ⬐ ({0}) {1}".format(roleS, supplier))
            else:
                print("Supplier:     ⬐ ({0}) {1}".format(roleS, supplier))
            for num, con in enumerate(consumers, start=1):
                roleC = GetServerRole(con.strip())
                if (args.output and args.output == '2'):
                    G.add_edge("(" + roleS + ")" + supplier.split('=')[1], "(" + roleC + ")" + con.split('=')[1])
                if (len(consumers) == 1):
                    print("Consumer({2}): ⮑ ({0}){1}\n".format(roleC, con, len(consumers)))
                else:
                    if num < len(consumers):
                        if num == 1:
                            print("Consumers({2}): ⮑ ({0}){1}".format(roleC, con, len(consumers)))
                        else:
                            print("              ⮑ ({0}){1}".format(roleC, con))
                    else:
                        print("              ⮑ ({0}){1}\n".format(roleC, con))

        if (args.output == '2'):
            nx.draw(G, arrowsize=20, arrowstyle='<->', node_color='skyblue', node_size=1000, edge_color='red',width=3.0, edge_cmap=plt.cm.Blues, with_labels=1)
            plt.legend(title=context + "\n Roles:\n (G)Gateway\n (M)Master\n (R)Replica")
            plt.show()
            G.clear()

def ParseAgreementPerContext(lContext, lAgreement):
    numAgreementsPerContext = 0
    dictSuppliers = dict()
    processAllAgreements = dict()
    newListContext = GetReplObjectDN(lContext)
    newlAgreement = CheckForWrappedLines(lAgreement)
    replContextAgreements = GetReplAgreementSubentryDN(newListContext, newlAgreement)

    for context in newListContext:
        for ra in replContextAgreements:
            for key, agreement in ra.items():
                consumer, supplier = "{dn}".format(**ProcessContextAgreements(agreement)).split(",")[:2]
                if (context.strip().lower() == key.strip().lower()):
                    numAgreementsPerContext += 1
                    if (supplier not in dictSuppliers):
                        dictSuppliers[supplier] = [consumer]
                    else:
                        dictSuppliers[supplier].append(consumer)
        processAllAgreements[context + " (" + str(numAgreementsPerContext) + " agreements)"] = dictSuppliers
        dictSuppliers = dict()
        numAgreementsPerContext = 0
    VisualizeReplTopology(processAllAgreements)

def IdentifyReplObjectclasses(topology):
    rAgreement = 'ibm-replicationagreement'
    rContext = 'ibm-replicationcontext'
    rGroup = 'ibm-replicagroup'
    rSubentry = 'ibm-replicasubentry'
    rCredential = 'ibm-replicationcredentialssimple'

    lAgreement = []
    lContext = []
    lGroup = []
    lSubentry = []
    lCredential = []

    for stanza in topology:
        for classobjects in stanza:
            for key, value in classobjects.items():
                newValue = value.strip().lower()
                if (newValue == rAgreement):
                    lAgreement.append(stanza)
                elif (newValue == rContext):
                    lContext.append(stanza)
                elif (newValue == rGroup):
                    lGroup.append(stanza)
                elif (newValue == rSubentry):
                    lSubentry.append(stanza)
                elif (newValue == rCredential):
                    lCredential.append(stanza)

    ParseReplicationContexts(lContext)
    ParseReplicationCredentials(lCredential)
    ParseReplicationGroups(lGroup)
    ParseSubentryPerContext(lContext, lSubentry)
    ParseAgreementPerContext(lContext, lAgreement)

def ProcessListStanza(stanza):
    finalstanza = []

    if ("dn:" in stanza[0]):
        delimiterOption = ":"
    else:
        delimiterOption = "="

    if (delimiterOption == ":"):
        for i in range(len(stanza)):
            key = ''.join(stanza[i].split(":")[0]).strip("\n").lower()
            value = ''.join(stanza[i].split(":", 1)[1:]).strip("\n")
            finalstanza.append(dict([(key, value)]))
    else:
        for i in range(len(stanza)):
            key = ''.join(stanza[i].split("=")[0]).strip("\n").lower()
            value = ''.join(stanza[i].split("=", 1)[1:]).strip("\n")
            if (i == 0):
                finalstanza.append(dict([("dn", stanza[i])]))
            else:
                finalstanza.append(dict([(key, value)]))
    return finalstanza

def get_arguments():
    """
    Get the command-line arguments
    """
    desc = """
         Parse replication topology from an output file or directly from LDAP Server.
         Example:
                 python3 parse_topology.py -f <ReplicationTopology.ldif>
                  ---or---
                 python3  parse_topology.py -search <path/idsldapsearch> -host <hostname/IP> -p <port#> -D <bindD> -w <password>"""
    aparser = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter,
    description=textwrap.dedent(desc), epilog="Output (-o) 1 will return agreements for all contexts and output (-o) 2 will return agreements one context at a time.")
    aparser.add_argument('-f', help='File containing Replication Topology.', required=False)
    aparser.add_argument('-search', help='idsldapsearch (defaults to /opt/ibm/ldap/V6.4/bin/idsldapsearch).',
                         default='/opt/ibm/ldap/V6.4/bin/idsldapsearch', required=False)
    aparser.add_argument('-host', '--hostname', help='LDAP Hostname.', default='localhost', required=False)
    aparser.add_argument('-p', '--port',
                         help='Port# where LDAP instance is listening on (eg. SSL 636 or Non-SSL 389) - (defaults to 389).',
                         default="389", required=False)
    aparser.add_argument('-D', help='Bind DN of LDAP Instance (defaults to cn=root).', default='cn=root',
                         required=False)
    aparser.add_argument('-w', help='Password of Bind DN.', required=False)
    aparser.add_argument('-sc', help='use a secure LDAP connection (Z for SSL or Y for TLS) - (defaults to Z).',
                         default="Z", required=False, choices=['Z', 'Y'])
    aparser.add_argument('-K', help='SSL .kdb file to search over SSL port.', required=False)
    aparser.add_argument('-P', help='SSL .kdb password.', required=False)
    aparser.add_argument('-o', '--output',
                         help='Textual (1) or Graphical (2) display of Replication Topology (defaults to 1).',
                         required=False, default='1', choices=['1', '2'])
    try:
        return aparser.parse_args()
    except IOError as msg:
        aparser.error(str(msg))

if __name__ == '__main__':
    repldata = []
    replines = []
    args = get_arguments()
    counter = 1
    tempreplines = []
    entiretopology = {}
    indexstanza = []
    topologystanza = {}
    finaltopology = {}

    try:
        if args.f:
            if os.path.isfile(args.f):
                with open(args.f, 'r') as file:
                    repldata = file.readlines()
            else:
                print("File {} is empty or doesn't exist.".format(args.f))
                sys.exit()
        elif args.hostname and args.port and args.D and args.w:
            if args.K and args.P and args.sc:
                command = "{0} -L -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w {7} -b '' -s sub objectclass=ibm-repl*".format(args.search, args.sc, args.K, args.P, args.hostname, args.port, args.D, args.w)
            else:
                command = "{0} -L -h {1} -p {2} -D {3} -w {4} -b '' -s sub objectclass=ibm-repl*".format(args.search,args.hostname,args.port,args.D, args.w)
            result = subprocess.Popen(command, shell=True, encoding='utf-8', stdout=subprocess.PIPE).stdout.read()
            if "ldap_simple_bind:" in result or result is None:
                print("{}".format(result))
                sys.exit()
            else:
                replines.append(result.split("\n"))
                for line in replines:
                    for li in line:
                        repldata.append(li)
        else:
            raise Exception

        for line in repldata:
            tempreplines.append(line)

        if (tempreplines[-1] != '\n' and tempreplines[-1] != ""):
            tempreplines.append('\n')

        for r in range(len(tempreplines)):
            entiretopology[r] = tempreplines[r]

        for item in entiretopology.items():
            if (item[1] == '\n' or item[1] == ""):
                indexstanza.append(item[0])

        bIndex = 0
        for i in range(len(indexstanza)):
            currentIndex = indexstanza[i]
            if (currentIndex > bIndex):
                topologystanza['Stanza' + str(counter)] = ProcessListStanza(tempreplines[bIndex:currentIndex])
            finaltopology['FinalTopology'] = topologystanza
            bIndex = currentIndex + 1
            counter = counter + 1

        dictreplstanza = {}
        listreplstanzas = []
        for each in finaltopology:
            for stanza in finaltopology[each]:
                dictreplstanza = finaltopology[each][stanza]
                listreplstanzas.append(dictreplstanza)

        if len(dictreplstanza) != 0:
            IdentifyReplObjectclasses(listreplstanzas)

    except Exception as e:
        print("Pass in -h or --help for more details on how to use this tool.")
        sys.exit()