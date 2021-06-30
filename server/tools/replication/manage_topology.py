import os
import subprocess
import datetime
import time
import sys
import re
import networkx as nx
import matplotlib.pyplot as plt
import argparse
import textwrap

allcontexts = dict()
allcontext_creds = dict()
allrepl_groups = dict()
allrepl_subentries = dict()
allrepl_agreements = dict()
allsupplierconsumer = dict()
allsupplierconsumer_percontext = dict()
allsupplierconsumer_creds = dict()
allreplica_urls = dict()
allconsumer_ids = dict()
allsubentry_details = dict()
allserver_roles = dict()

def check_wrapped_lines(cleanstanza):
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

def get_object_dn(myobject):
    objectdn = []
    for mo in myobject:
        for o in mo:
            for key, value in o.items():
                if (key == "dn"):
                    objectdn.append(value.strip())
    return objectdn

def get_topology_details():
    print("[#]Replication Contexts: \n------------------------")
    if len(allcontexts) == 0:
        print("No Replication Contexts found!")
    else:
        for num, context in enumerate(allcontexts, start=1):
            if len(allcontexts[context]) > 1:
                print("[{0}] {1} (referral)->{2}".format(num, context, allcontexts[context][1]))
            else:
                print("[{0}] {1}".format(num, context))

    time.sleep(1)
    print("\n[#]Replication Credentials: \n----------------DN-----------------USER_ID-------PASSWORD")
    if len(allcontext_creds) ==0:
        print("No Replication Credentials found!")
    else:
        for num, creds in enumerate(allcontext_creds, start=1):
            print("[{0}] {1} {2} {3}".format(num, creds, allcontext_creds[creds][0][0], allcontext_creds[creds][0][1]))

    time.sleep(1)
    print("\n[#]Replication Groups: \n----------------------")
    if len(allrepl_groups) == 0:
        print("No Replication Groups found!")
    else:
        for num, group in enumerate(allrepl_groups, start=1):
            print("[{0}] {1}".format(num, allrepl_groups[group][0]))

    time.sleep(1)
    print("\n[#]Replication Subentries: \n--------------------------")
    if len(allsubentry_details) == 0:
        print("No Replication Subentries found!\n")
    else:
        for con in allsubentry_details:
            print("[#] [*** Subentries for Context {0} ***---------SERVER_ID-----SERVER_ROLE]".format(con))
            for num, subentry in enumerate(allsubentry_details[con], start=1):
                    server = subentry['dn'].split(",", 1)[0]
                    if allserver_roles[server.strip()] == 'G':
                        role = "Gateway"
                    elif allserver_roles[server.strip()] == 'M':
                        role = "Master"
                    else:
                        role = "Replica"
                    print("[{0}]{1}  {2}  {3}".format(num, subentry['dn'].strip('\n'), subentry['ibm-replicaserverid'].strip('\n'), role.strip('\n')))
            print("\n")

def parse_replication_contexts(lContext):
    for context in lContext:
        for co in context:
            for key, value in co.items():
                nkey = key.strip().lower()
                nvalue = value.strip().lower()
                if (nkey == "dn"):
                    if nvalue not in allcontexts:
                        allcontexts[nvalue] = ["objectclass: ibm-replicationcontext"]
                        oldv = nvalue
                    else:
                        allcontexts[nvalue].append("objectclass: ibm-replicationcontext")
                        oldv = nvalue
                if(nkey == "ibm-replicareferralurl"):
                    allcontexts[oldv].append(nkey+":"+value)

def parse_replication_credentials(listCredentials):
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
        dn = '{dn}'.format(**newDictCredentials).strip().lower()
        binddn = '{replicabinddn}'.format(**newDictCredentials)
        password = '{replicacredentials}'.format(**newDictCredentials)

        if (dn not in allcontext_creds):
            allcontext_creds[dn] = [(binddn, password)]
        else:
            allcontext_creds[dn].append((binddn, password))

def parse_replication_groups(listGroups):
    groups = get_object_dn(listGroups)

    for num, group in enumerate(groups, start=1):
        context = group.split(',', 1)[1].lower()
        if (context not in allrepl_groups):
            allrepl_groups[context] = [group]
        else:
            allrepl_groups[context].append(group)

def process_subentries(subentry):
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

def get_agreementsubentry_dn(newListContext, replobject):
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
                if (currentContext in replContext.strip().lower()):
                    finalreplobject.append(dict([(currentContext, replob)]))
    return finalreplobject

def parse_replication_subentries(lContext, lSubentry):
    newListContext = get_object_dn(lContext)
    newlSubentry = check_wrapped_lines(lSubentry)
    replContextSubentry = get_agreementsubentry_dn(newListContext, newlSubentry)

    for context in newListContext:
        for num, sub in enumerate(replContextSubentry, start=1):
            for keycontext, subentry in sub.items():
                subentrydn = "{dn}".format(**process_subentries(subentry))
                ccontext = context.strip().lower()
                ckeycontext = keycontext.strip().lower()
                if (ccontext == ckeycontext):
                    if ("ibm-replicaGateway" in process_subentries(subentry)):
                        dn = process_subentries(subentry)['dn'].split(",", 1)[0]
                        allserver_roles[dn.strip()] = "G"
                    else:
                        dn = process_subentries(subentry)['dn'].split(",", 1)[0]
                        role = process_subentries(subentry)['ibm-replicationserverismaster'].strip().lower()
                        if role.strip() == "true":
                            allserver_roles[dn.strip()] = "M"
                        else:
                            allserver_roles[dn.strip()] = "R"
                    if(ckeycontext not in allrepl_subentries):
                        allrepl_subentries[ckeycontext] = [subentrydn]
                        allsubentry_details[ckeycontext] = [process_subentries(subentry)]
                    else:
                        allrepl_subentries[ckeycontext].append(subentrydn)
                        allsubentry_details[ckeycontext].append(process_subentries(subentry))

def process_agreements(listAgreements):
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


def visualize_repltopology(ConsumersPerSupplier):
    args = get_arguments()
    G = nx.DiGraph()

    if args.op == "search":

        get_topology_details()

        print("[#]Replication Agreements: \n----------------------------------------------------------------------------\
             \nRoles: (G)Gateway, (M)Master, (R)Replica, or (U)Undefined - missing subentry.\
             \n----------------------------------------------------------------------------")
        if len(ConsumersPerSupplier) == 0:
            print("No Replication agreements found!")
        else:
            for context, consumerlist in ConsumersPerSupplier.items():
                print("[#][Context: {0}]".format(context))
                print("----------------------------------------------------------------------------")
                time.sleep(2)
                for supplier, consumers in consumerlist.items():
                    if supplier in allserver_roles:
                        roleS = allserver_roles[supplier.strip()]
                    else:
                        roleS = "U"

                    if (len(consumers) == 1):
                        print("Supplier:     ⬐ ({0}){1}".format(roleS, supplier))
                    else:
                        print("Supplier:      ⬐ ({0}){1}".format(roleS, supplier))
                    for num, con in enumerate(consumers, start=1):
                        if con in allserver_roles:
                            roleC = allserver_roles[con.strip()]
                        else:
                            roleC = "U"

                        if (args.details == 'y' or args.details == 'yes'):
                            server_details = "->({0}, {1})".format(allreplica_urls[con], allconsumer_ids[con])
                        else:
                            server_details = ""

                        if (args.output and args.output == '2'):
                            supp= "(" + roleS + ")" + supplier.split('=')[1]
                            cons= "(" + roleC + ")" + con.split('=')[1]
                            G.add_node(supp, role = roleS)
                            G.add_node(cons, role = roleC)
                            G.add_edge(supp,cons)

                        if (len(consumers) == 1):
                            print("Consumer({2}):  ⮑ ({0}){1} {3}\n".format(roleC, con, len(consumers),server_details))
                        else:
                            if num < len(consumers):
                                if len(consumers) > 9:
                                    if num == 1:
                                        print("Consumers({2}): ⮑ ({0}){1} {3}".format(roleC, con, len(consumers),server_details))
                                    else:
                                        print("               ⮑ ({0}){1} {2}".format(roleC, con,server_details))
                                else:

                                    if num == 1:
                                        print("Consumers({2}):  ⮑ ({0}){1} {3}".format(roleC, con, len(consumers),server_details))
                                    else:
                                        print("               ⮑ ({0}){1} {2}".format(roleC, con, server_details))
                            else:
                                print("               ⮑ ({0}){1} {2}\n".format(roleC, con, server_details))
                print("----------------------------------------------------------------------------")

                if (args.output == '2'):
                    if G.number_of_nodes() > 10:
                        rwith = 1
                        nsize = 500
                        fsize = 10
                        font_size='small'
                    else:
                        rwith = 2
                        nsize = 1000
                        fsize = 12
                        font_size='medium'

                    color_map = nx.get_node_attributes(G,'role')

                    for key in color_map:
                        if color_map[key] == "M":
                            color_map[key] = "green"
                        if color_map[key] == "R":
                            color_map[key] = "red"
                        if color_map[key] == "G":
                            color_map[key] = "blue"
                        if color_map[key] == "U":
                            color_map[key] = "grey"

                    edge_colors=[]
                    for key in G.edges():
                        if key[0] in color_map:
                            edge_colors.append(color_map[key[1]])

                    node_colors = [color_map.get(node) for node in G.nodes()]
                    options = {
                        "horizontalalignment": 'center',
                        "font_size": fsize,
                        "font_color": "black",
                        "node_size": nsize,
                        "node_color": node_colors,
                        "linewidths": 3,
                        "width": rwith,
                        "arrowsize": 20,
                        "arrowstyle": '<->',
                        "arrowcolor": "skyblue",
                        "with_labels": 1,
                        "edge_color": edge_colors
                    }

                    mapping = dict(zip(G, range(1,G.number_of_nodes()+1)))
                    G = nx.relabel_nodes(G, mapping)

                    node_d= {}
                    for v in mapping.values():
                        node_d[v]=[n for n in G.neighbors(v)]


                    server_agreements = ["{0}-{1} -> {2}".format(v, k, tuple(node_d[v])) for k, v in mapping.items() if len(node_d[v])> 0 ]
                    servers = ["{0}-{1}".format(v, k) for k, v in mapping.items()]

                    all_agreements = '\n'.join(server_agreements)
                    all_servers = '\n'.join(servers)
                    final_server_agreements = "****Servers****\n{0}\n\n****Agreements****\nSupplier     ->   (Consumers)\n{1}\n".format(all_servers,all_agreements)
                    try:
                        plt.figure(num=context)
                        nx.draw_circular(G,**options)

                        agreements = "\n".join(["{0} -> {1}".format(supplier, tuple(consumers)) for supplier, consumers in node_d.items() if len(consumers) >0])

                        first_legend = plt.legend(title="Agreements\nSupplier -> (Consumers)\n"+agreements,loc="upper right", fontsize=font_size, title_fontsize=font_size)
                        plt.gca().add_artist(first_legend)
                        frame1 = first_legend.get_frame()
                        frame1.set_edgecolor('yellow')

                        replservers = ["{0}-{1}".format(v, k) for k, v in mapping.items()]
                        servers_title = '\n'.join(replservers)
                        second_legend = plt.legend(title="Servers:\n"+servers_title, loc="upper left",fontsize=font_size, title_fontsize=font_size)
                        plt.gca().add_artist(second_legend)
                        frame2 = second_legend.get_frame()
                        frame2.set_edgecolor('yellow')

                        roles_title = "Roles:\n(M)Master - Green, (R)Replica - Red, (G)Gateway - Blue\n(U)Undefined - Missing subentry - Grey"
                        third_legend=plt.legend(title=roles_title, loc="lower left",fontsize=font_size, title_fontsize=font_size)
                        plt.gca().add_artist(third_legend)
                        frame3 = third_legend.get_frame()
                        frame3.set_edgecolor('yellow')
                        print("Summmary of Servers and Agreements for: {0}\n----------------------------------------------------------------------------\n{1}\
----------------------------------------------------------------------------".format(context, final_server_agreements))
                        plt.show()
                    except:
                        print("❌ Can't render graph! You might be running this in a non-GUI environment.\n----------------------------------------------------------------------------")
                        print("Summmary of Servers and Agreements for: {0}\n----------------------------------------------------------------------------\n{1}\
----------------------------------------------------------------------------".format(context, final_server_agreements))
                    G.clear()

def execute_command(command):
    return subprocess.Popen(command, shell=True, encoding='utf-8', stderr=subprocess.STDOUT, stdout=subprocess.PIPE).stdout.read()

def repltest_result(user, supplierresult):
    print("\nFinal Result:")
    successfulops = []
    failedops= []
    for supplier, consumerresult in supplierresult.items():
        if (len(consumerresult) == 1):
            print("Supplier:      ⬐  {0}".format(supplier))
        else:
            print("Supplier:       ⬐  {0}".format(supplier))

        for num, consumer in enumerate(consumerresult, start=1):
            if "ldap_" in consumerresult[consumer][0]:
                failedops.append("add")
            else:
                successfulops.append("add")

            if user.strip() == consumerresult[consumer][1].strip():
                successfulops.append("search")
            else:
                failedops.append("search")

            if consumerresult[consumer][2] == "None":
                failedops.append("delete")
            else:
                successfulops.append("delete")

            if len(failedops) > 0:
                replicated = "NO"
            else:
                replicated = "YES"

            if (len(consumerresult) == 1):
                print("Consumer({0}): ({1}){2}".format(len(consumerresult), replicated, consumer))
            else:
                if num < len(consumerresult):
                    if num == 1:
                        print("Consumers({0}): ({1}){2}".format(len(consumerresult), replicated, consumer))
                    else:
                        print("              ({0}){1}".format(replicated, consumer))
                else:
                    print("              ({0}){1}".format(replicated,consumer))

            successfulops=list()
            failedops=list()

def test_replication(context, args):
    myPath = os.getcwd()
    wFile = '\create_entry.ldif'
    xFile = '/create_entry.ldif'
    if (sys.platform == "win32"):
        myfile = myPath + wFile
    elif (sys.platform == "darwin"):
        myfile = myPath + wFile
    else:
        myfile = myPath + xFile

    if args.K:
        commanda = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -l -c -a -i {8}'
        commands = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -s base -b "cn={8} TestUser, {9}" objectclass=* dn'
        commandd = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -l "{8}"'
    else:
        commanda = '{0} -h {1} -p {2} -D {3} -w "{4}" -l -c -a -i {5}'
        commands = '{0} -h {1} -p {2} -D {3} -w "{4}" -s base -b "cn={5} TestUser, {6}" objectclass=* dn'
        commandd = '{0} -h {1} -p {2} -D {3} -w "{4}" -l  "{5}"'

    consumeropresult = dict()
    supplierop = dict()
    c = context.lower()

    if c not in allcontexts:
        print("No Replication topology was found for: {0}.".format(c))
        sys.exit()
    else:
        print("--------------------------------------------------------------------------------------------------------------")
        print("Final Result can be:\n(YES) or (NO) - meaning Supplier can or can't replicate to Consumer using the defined \
Replication Credentials.\n(YES) is based on successful add, search, & delete of the Test user and (No) if any of those operations fails.")
        print("--------------------------------------------------------------------------------------------------------------")
        print("                              [Start] Testing for Replication context: {0}.".format(context))
        print("--------------------------------------------------------------------------------------------------------------")

        for supplier, consumers in allsupplierconsumer_percontext[c].items():
            creddn = allsupplierconsumer_creds[supplier]
            user = ""
            pwd = ""
            currentcredndn=""
            for credobject in creddn:
                if c == credobject[0]:
                    currentcredndn = credobject[1]
                    if credobject[1] in allcontext_creds:
                        newcreds = allcontext_creds[credobject[1]]
                        user = newcreds[0][0].strip()
                        pwd = newcreds[0][1].strip()
                        break
                    else:
                        print("No Replication Credentials found - can't continue with testing!")
                        sys.exit()
            ldaptype, supplierhost, supplierport = allreplica_urls[supplier.strip()].split(":")

            if ldaptype == "ldaps" and args.K == None:
                print("Replication is configured over SSL (eg. {0}).\nIn order to continue with the test you need to \
pass in a value for -K <.kdb> and -P <.kdb pwd> parameters.".format(allreplica_urls[supplier.strip()]))
                sys.exit()

            suppliertestuser = supplier.split('=')[1].strip()
            with open(myfile, "w+") as mf:
                create_entry = "dn: cn={0} TestUser, {1}\nobjectclass: top\nobjectclass: person\nobjectclass: \
                organizationalPerson\ncn: {0}\nsn: TestUser\nuserpassword: secret\ndescription: Testing Replication.\n".format(suppliertestuser,context)
                mf.write(create_entry)

            print("Credential: {0} \nTest user:  cn={1} TestUser,{2}".format(currentcredndn,suppliertestuser,c))
            print("--------------------------------------------------------------------------------------------------------------")
            print("Testing Replication between  ⬐  Supplier ({0})".format(supplier.strip()))
            for consumer in consumers:
                ldaptype, consumerh, consumerport = allreplica_urls[consumer[0].strip()].split(":")
                consumerhost = consumerh.strip("//")
                print("                             ⮑  Consumer ({0}) -> ({1}:{2})".format(consumer[0].strip(),consumerhost,consumerport))
                if ldaptype == "ldaps":
                    create_result = execute_command(commanda.format(args.modify, args.sc, args.K, args.P, consumerhost, consumerport, user, pwd, "create_entry.ldif"))
                    if "ldap_" in create_result:
                        print("                                Add failed (no need to test search/delete):\n                                ❌",[res.strip() for res in create_result.split('\n') if len(res.strip()) > 0])
                        search_result = "None"
                        delete_result = "None"
                    else:
                        time.sleep(1)
                        search_result = execute_command(commands.format(args.search, args.sc, args.K, args.P, consumerhost, consumerport, user, pwd,suppliertestuser, c))
                        if "ldap_" in search_result:
                            delete_result = "None"
                            print("                                Search failed:\n                               ❌",[res.strip() for res in search_result.split('\n') if len(res.strip()) > 0])
                        else:
                            time.sleep(1)
                            delete_result = execute_command(commandd.format(args.delete, args.sc, args.K, args.P, consumerhost, consumerport, user, pwd,search_result))
                            if "ldap_" in delete_result:
                                print("                                Delete failed with:\n                           ❌",[res.strip() for res in delete_result.split('\n') if len(res.strip()) > 0])
                else:
                    create_result = execute_command(commanda.format(args.modify, consumerhost, consumerport, user, pwd, "create_entry.ldif"))
                    if "ldap_" in create_result:
                        print("                                Add failed (no need to test search/delete):\n                                ❌",[res.strip() for res in create_result.split('\n') if len(res.strip()) > 0])
                        search_result = "None"
                        delete_result = "None"
                    else:
                        time.sleep(1)
                        search_result = execute_command(commands.format(args.search, consumerhost, consumerport, user, pwd, suppliertestuser, c))
                        if "ldap_" in search_result:
                            delete_result = "None"
                            print("                                Search failed:\n                               ❌",[res.strip() for res in search_result.split('\n') if len(res.strip()) > 0])
                        else:
                            time.sleep(1)
                            delete_result = execute_command(commandd.format(args.delete, consumerhost, consumerport, user, pwd, search_result))
                            if "ldap_" in delete_result:
                                print("                                Delete failed with:\n                           ❌",[res.strip() for res in delete_result.split('\n') if len(res.strip()) > 0])

                consumeropresult[consumer[0].strip()] =[create_result.strip('\n'),search_result.strip('\n'),delete_result.strip('\n')]

            if supplier.strip() not in supplierop:
                supplierop[supplier.strip()] = consumeropresult
            else:
                supplierop[supplier.strip()].append(consumeropresult)

            consumeropresult = dict()
            testuser = 'cn={0} TestUser,{1}'.format(suppliertestuser,c)
            time.sleep(1)
            repltest_result(testuser,supplierop)
            supplierop = dict()
            time.sleep(1)
            print("--------------------------------------------------------------------------------------------------------------")
        print("                              [End] Testing for Replication context: {0}.".format(context))
        print("--------------------------------------------------------------------------------------------------------------")

def delete_replcontext(context, command, args):
    myPath = os.getcwd()
    wFile = '\delreplcontextobjectclass.ldif'
    xFile = '/delreplcontextobjectclass.ldif'
    if (sys.platform == "win32"):
        myfile = myPath + wFile
    elif (sys.platform == "darwin"):
        myfile = myPath + wFile
    else:
        myfile = myPath + xFile

    if context.lower() == 'all':
        for co in allcontexts:
            print("\n***Deleting ibm-replicationcontext from: {0}***".format(co))
            with open(myfile, "w+") as mf:
                if len(allcontexts[co]) > 1:
                    delreplcontext = "dn: {0}\nchangetype: modify\ndelete: objectclass\n{1}\n-\ndelete: ibm-replicareferralurl\n{2}\n".format(co,allcontexts[co][0],allcontexts[co][1])
                else:
                    delreplcontext = "dn: {0}\nchangetype: modify\ndelete: objectclass\n{1}\n".format(co, allcontexts[co][0])
                mf.write(delreplcontext)

            if args.K:
                delete_result = execute_command(command.format(args.modify, args.sc, args.K, args.P, args.hostname, args.port, args.D, args.w, "delreplcontextobjectclass.ldif"))
            else:
                delete_result = execute_command(command.format(args.modify, args.hostname, args.port, args.D, args.w, "delreplcontextobjectclass.ldif"))
            print(delete_result.strip('\n'))
    else:
        if context.lower() in allcontexts:
            print("\n***Deleting ibm-replicationcontext from: {0}***".format(context))
            with open(myfile, "w+") as mf:
                if len(allcontexts[context]) > 1:
                    delreplcontext = "dn: {0}\nchangetype: modify\ndelete: objectclass\n{1}\n-\ndelete: ibm-replicareferralurl\n{2}\n".format(context,allcontexts[context][0],allcontexts[context][1])
                else:
                    delreplcontext = "dn: {0}\nchangetype: modify\ndelete: objectclass\n{1}\n".format(context, allcontexts[context][0])
                mf.write(delreplcontext)
            if args.K:
                delete_result = execute_command(command.format(args.modify, args.sc, args.K, args.P, args.hostname, args.port, args.D, args.w,"delreplcontextobjectclass.ldif"))
            else:
                delete_result = execute_command(command.format(args.modify, args.hostname, args.port, args.D, args.w,"delreplcontextobjectclass.ldif"))
            print(delete_result.strip('\n'))

def purge_object(ob, context, command, replobject, args):
    print("\n***Deleting Replication {0} for: {1}***".format(ob, context))
    for ob in replobject:
        if args.K:
            delete_result = execute_command(command.format(args.delete, args.sc, args.K, args.P, args.hostname, args.port, args.D, args.w, ob))
        else:
            delete_result = execute_command(command.format(args.delete, args.hostname, args.port, args.D, args.w, ob))
        print(delete_result.strip('\n'))

def delete_topology(replcontext, replicatechange, args):
    context = replcontext.lower()

    if replicatechange =='n':
        if args.K:
            commando = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -c -l -k "{8}"'
            commandc = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -c -l -k -i {8}'
        else:
            commando = '{0} -h {1} -p {2} -D {3} -w "{4}" -c -l -k "{5}"'
            commandc = '{0} -h {1} -p {2} -D {3} -w "{4}" -c -l -k -i {5}'
    else:
        if args.K:
            commando = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -c -k "{8}"'
            commandc = '{0} -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -c -k -i {8s}'
        else:
            commando = '{0} -h {1} -p {2} -D {3} -w "{4}" -c -k "{5}"'
            commandc = '{0} -h {1} -p {2} -D {3} -w "{4}" -c -k -i {5}'

    if context == "all":
        for con in allrepl_agreements:
            purge_object('agreements', con, commando, allrepl_agreements[con], args)

        for con in allrepl_subentries:
            purge_object('subentries', con, commando, allrepl_subentries[con], args)

        for con in allrepl_groups:
            purge_object('group', con, commando, allrepl_groups[con], args)

        purge_object('credential', 'all', commando, allcontext_creds, args)

        delete_replcontext(context, commandc, args)
    else:
        if context in allrepl_agreements:
            purge_object('agreements', context, commando, allrepl_agreements[context], args)

        if context in allrepl_subentries:
            purge_object('subentries', context, commando, allrepl_subentries[context], args)

        if context in allrepl_groups:
            purge_object('group', context, commando, allrepl_groups[context], args)

        for con in allcontext_creds:
            if context in con:
                print("\n***Deleting Replication Credential for: {0}***".format(context))
                if args.K:
                    delete_result = execute_command(commando.format(args.delete, args.sc, args.K, args.P, args.hostname, args.port, args.D, args.w,con))
                else:
                    delete_result = execute_command(commando.format(args.delete, args.hostname, args.port, args.D, args.w, con))
                print(delete_result.strip('\n'))

        delete_replcontext(context, commandc, args)

def parse_replication_agreements(lContext, lAgreement):
    numAgreementsPerContext = 0
    dictSuppliers = dict()
    processAllAgreements = dict()
    newListContext = get_object_dn(lContext)
    newlAgreement = check_wrapped_lines(lAgreement)
    replContextAgreements = get_agreementsubentry_dn(newListContext, newlAgreement)

    for context in newListContext:
        for ra in replContextAgreements:
            for keycontext, agreement in ra.items():
                agreementdn = "{dn}".format(**process_agreements(agreement)).lower().strip()
                consumerurl= "{ibm-replicaurl}".format(**process_agreements(agreement)).lower().strip()
                consumerid = "{ibm-replicaconsumerid}".format(**process_agreements(agreement)).lower().strip()
                bindcreds = "{ibm-replicacredentialsdn}".format(**process_agreements(agreement)).lower().strip()
                consumer, supplier = agreementdn.split(",")[:2]
                ccontext = context.strip().lower()
                ckeycontext = keycontext.strip().lower()
                if (ccontext == ckeycontext):
                    numAgreementsPerContext += 1
                    if (supplier not in dictSuppliers):
                        dictSuppliers[supplier] = [consumer]
                        allsupplierconsumer[supplier]=[(consumer,consumerurl)]
                    else:
                        dictSuppliers[supplier].append(consumer)
                        allsupplierconsumer[supplier].append((consumer,consumerurl))

                    if(ckeycontext not in allrepl_agreements):
                        allrepl_agreements[ckeycontext] = [agreementdn]
                    else:
                        allrepl_agreements[ckeycontext].append(agreementdn)

                    if supplier not in allsupplierconsumer_creds:
                        allsupplierconsumer_creds[supplier] = [(ccontext, bindcreds)]
                    else:
                        if (ccontext,bindcreds) not in allsupplierconsumer_creds[supplier]:
                            allsupplierconsumer_creds[supplier].append((ccontext, bindcreds))

                    allreplica_urls[consumer.strip()] = consumerurl.lower().strip()
                    allconsumer_ids[consumer.strip()] = consumerid.lower().strip()

        processAllAgreements[context + " (" + str(numAgreementsPerContext) + " agreements)"] = dictSuppliers
        allsupplierconsumer_percontext[context]=allsupplierconsumer
        dictSuppliers = dict()
        numAgreementsPerContext = 0
    visualize_repltopology(processAllAgreements)

def identify_replobjectclasses(topology):
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

    parse_replication_contexts(lContext)
    parse_replication_credentials(lCredential)
    parse_replication_groups(lGroup)
    parse_replication_subentries(lContext, lSubentry)
    parse_replication_agreements(lContext, lAgreement)

def process_stanzas(stanza):
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

def get_sdshome():
    ldap_home_env = os.getenv('IDS_LDAP_HOME')

    if (sys.platform == "win32"):
        if (ldap_home_env  == None):
            ids_ldap_home = "C:\Program Files\ibm\ldap\V6.4\\bin\\"
        else:
            ids_ldap_home = ldap_home_env+"\\bin\\"
    elif (sys.platform =='aix6'):
        if (ldap_home_env  == None):
            ids_ldap_home = "/opt/IBM/ldap/V6.4/bin/"
        else:
            ids_ldap_home = ldap_home_env+"/bin/"
    else:
        if (ldap_home_env == None):
            ids_ldap_home = "/opt/ibm/ldap/V6.4/bin/"
        else:
            ids_ldap_home = ldap_home_env+"/bin/"

    return ids_ldap_home

def get_arguments():
    """
    Get the command-line arguments
    """
    ids_ldap_home = get_sdshome()
    if sys.platform == 'win32':
        search = "idsldapsearch.cmd"
        delete = "idsldapdelete.cmd"
        modify = "idsldapmodify.cmd"
    else:
        search = "idsldapsearch"
        delete = "idsldapdelete"
        modify = "idsldapmodify"

    desc = """
        Parse Replication topology from an output file or manage directly from LDAP Server.
        
        Note: When connecting directly to LDAP server: 
            * Set env. variable IDS_LDAP_HOME to <SDS 6.x install path or SDS 6.x client library location> 
              to use idsldapsearch, idsldapmodify, idsldapdelete utilities.
              - eg. Unix/Linux: export IDS_LDAP_HOME=/opt/ibm/ldap/V6.4
                    Windows:    set IDS_LDAP_HOME=<drive>:\Program Files\ibm\ldap\V6.4
                    
              - If no value is found for IDS_LDAP_HOME then tool will default to:
                    Unix/Linux: /opt/{IBM|ibm}/ldap/V6.4
                    Windows: C:\Program Files\ibm\ldap\V6.4
            * When testing Topology: If Servers replicate over SSL port then -K and -P parameters are required."""
    epilog = """
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
    python3 manage_topology.py -host <hostname/IP> -p <port#> -D <bindD> -w <password> -s <context/suffix> -op delete"""

    aparser = argparse.ArgumentParser(formatter_class=argparse.RawDescriptionHelpFormatter,description=textwrap.dedent(desc), epilog=epilog)
    aparser.add_argument('-f', help='File containing Replication Topology.', required=False)
    aparser.add_argument('-host', '--hostname', help='LDAP Hostname.', default='localhost', required=False)
    aparser.add_argument('-p', '--port',
                         help='Port# where LDAP instance is listening on (eg. SSL 636 or Non-SSL 389) - (defaults to 389).',
                         default="389", required=False)
    aparser.add_argument('-D', help='Bind DN of LDAP Instance (defaults to cn=root).', default='cn=root',
                         required=False)
    aparser.add_argument('-w', help='Password of Bind DN.', required=False)
    aparser.add_argument('-sc', help='secure Protocol (Z for SSL or Y for TLS) - (defaults to Z).',
                         default="Z", required=False, choices=['Z', 'Y'])
    aparser.add_argument('-K', help='SSL .kdb file to search over SSL port.', required=False)
    aparser.add_argument('-P', help='SSL .kdb password.', required=False)
    aparser.add_argument('-op', help='Operation: search/parse, delete, or test replication topology.', default="search", choices=['search', 'delete', 'test'], required=False)
    aparser.add_argument('-s', help="Suffix to manage (eg. cn=ibmpolicies). When deleting topology 'all' can be used as a value to delete topology for all suffixes.", required=False)
    aparser.add_argument('-r', help='Replicate change - (defaults to n/No).', required=False, choices=['n','y'], default='n')
    aparser.add_argument('-o', '--output',help='Textual (1) or Graphical (2) display of Replication Topology (defaults to 1).',required=False, default='1', choices=['1', '2'])
    aparser.add_argument('-d', '--details',help='Return more details of consumer servers (defaults to no).',required=False, default='n', choices=['n', 'no', 'y', 'yes'])
    aparser.add_argument('-search', help='idsldapsearch (defaults to '+ids_ldap_home+search+').', default=search, required=False)
    aparser.add_argument('-delete', help='idsldapdelete (defaults to '+ids_ldap_home+delete+').', default=delete, required=False)
    aparser.add_argument('-modify', help='idsldapmodify (defaults to '+ids_ldap_home+modify+').', default=modify, required=False)
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
                print("File {0} is empty or doesn't exist.".format(args.f))
                sys.exit()
        elif args.hostname and args.port and args.D and args.w:
            os.chdir(get_sdshome())
            if args.K and args.P and args.sc:
                command = '{0} -L -{1} -K {2} -P {3} -h {4} -p {5} -D {6} -w "{7}" -b "" -s sub objectclass=ibm-repl*'.format(args.search, args.sc, args.K, args.P, args.hostname, args.port, args.D, args.w)
            else:
                command = '{0} -L -h {1} -p {2} -D {3} -w "{4}" -b "" -s sub objectclass=ibm-repl*'.format(args.search,args.hostname,args.port,args.D, args.w)
            result = execute_command(command)
            if "ldap_" in result or result is None:
                print("{0}".format(result))
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
                topologystanza['Stanza' + str(counter)] = process_stanzas(tempreplines[bIndex:currentIndex])
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
            identify_replobjectclasses(listreplstanzas)
        else:
            print("No Replication Topology found!")
            sys.exit()

        if(args.op =="test"):
            test_replication(args.s, args)

        if(args.op=="delete"):
            delete_topology(args.s, args.r, args)

    except Exception as e:
        print("Pass in -h or --help for more details on how to use this tool.")
        sys.exit()