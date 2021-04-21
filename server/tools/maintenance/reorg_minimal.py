import ibm_db
from datetime import datetime
import argparse
import logging.config
import logging
import sys
import time

logger = logging.getLogger(__name__)


def identify_indexes(scope, criteria):
    # Execute reorgchk procedure to find indexes needing reorg
    sql = ("Call SYSPROC.REORGCHK_IX_STATS('{}', '{}');").format(scope, criteria)
    logger.debug("Executing SQL: {}".format(sql))
    stmt = ibm_db.exec_immediate(conn, sql)
    result = ibm_db.fetch_tuple(stmt)
    reorg_indexes = {}  # Contains tuples with table and index name
    while (result):
        tschema, tabname, ischema, ixname, reorgchk = result[0].strip(), result[1], result[2].strip(), result[3], \
                                                      result[21]
        if '*' in reorgchk[1:]:  # Ignore F4 that indicates alignment of data in table to index
            logger.info("Data indicating reorg needed for: {}".format(result))
            t = "{}.{}".format(tschema, tabname)
            i = "{}.{}".format(ischema, ixname)
            if t in reorg_indexes:
                reorg_indexes[t].append(i)
            else:
                reorg_indexes[t] = [i]
        result = ibm_db.fetch_tuple(stmt)

    return reorg_indexes


def process_indexes(ilist, exec_cmds, fout):
    if ilist:
        print("--Following indexes (all indexes on corresponding table) need reorg", file=fout)
        for i in ilist:
            logger.info("Indexes {}, need REORG - all indexes will be REORGED for table {}.".format(ilist[i], i))
            # Individual reorg of indexes cannot be done in all situations
            sql = "REORG INDEXES ALL FOR TABLE {} ALLOW WRITE ACCESS;".format(i)
            process_sql(sql, exec_cmds)
    else:
        print("--No indexes needed reorg", file=fout)


def identify_tables(scope, criteria):
    # Execute reorgchk procedure to find tables needing reorg
    sql = ("Call SYSPROC.REORGCHK_TB_STATS('{}', '{}');").format(scope, criteria)
    logger.debug("Executing SQL: {}".format(sql))
    stmt = ibm_db.exec_immediate(conn, sql)
    result = ibm_db.fetch_tuple(stmt)
    reorg_tables = []  # Contains fully qualified table names (with schema)
    while (result):
        schema, tabname, reorgchk = result[0].strip(), result[1], result[12]
        if '*' in reorgchk:
            logger.info("Data indicating reorg needed for: {}".format(result))
            reorg_tables.append("{}.{}".format(schema, tabname))
        result = ibm_db.fetch_tuple(stmt)

    return reorg_tables


def process_tables(tlist, exec_cmds, fout):
    if tlist:
        print("--Following tables need reorg", file=fout)
        for t in tlist:
            # Allowing DB2 to figure out what should be the cluster index on its own, if applicable
            sql = "REORG TABLE {} INPLACE ALLOW WRITE ACCESS;".format(t)
            process_sql(sql, exec_cmds)
    else:
        print("--No tables needed reorg", file=fout)


def process_runstats(ilist, tlist, exec_cmds, fout):
    if ilist:
        print("--Following tables need runstat - because of indexes needing it", file=fout)
        for t in ilist:
            sql = "RUNSTATS ON TABLE {} WITH DISTRIBUTION AND DETAILED INDEXES ALL ALLOW WRITE ACCESS;".format(t)
            process_sql(sql, exec_cmds)
    else:
        print("--No indexes needed runstat", file=fout)
    if tlist:
        print("--Following tables need runstat", file=fout)
        for t in tlist:
            sql = "RUNSTATS ON TABLE {} WITH DISTRIBUTION ALLOW WRITE ACCESS;".format(t)
            process_sql(sql, exec_cmds)
    else:
        print("--No tables needed runstat", file=fout)


def process_sql(sql, exec_cmds):
    # Print the DB2 SQL command, and follow up by executing it if that is what is required
    print(sql, file=fout)
    if exec_cmds == 'R':
        logger.debug("Executing SQL: {}".format(sql))
        stmt = ibm_db.exec_immediate(conn, "CALL SYSPROC.ADMIN_CMD('{}')".format(sql[:-1]))
        # For now ibm_db does not support querying stmt to get results of command executed


def wait_for_reorg_completion(check_interval, timeout, fout):
    # This function assumes that an online reorg is what is being run, it has not been tested for a mix of online and
    # offline reorg. It will check for ANY reorg in execution - regardless of ones initiated by this script.
    sql = "select tabschema, tabname, reorg_status, reorg_type from table(snap_get_tab_reorg('')) where reorg_status != 'COMPLETED'"
    time_waited = 0
    while time_waited < timeout:
        logger.debug("Executing SQL: {}".format(sql))
        stmt = ibm_db.exec_immediate(conn, sql)
        result = ibm_db.fetch_tuple(stmt)
        if result:
            time_waited += check_interval
            print("--*** Following REORG jobs still in progress ***", file=fout)
            while (result):
                tschema, tabname, reorg_stat, reorg_type = result[0], result[1], result[2], result[3]
                logger.debug(result)
                print("--  Table {}.{} REORG Type: {} Status: {}".format(tschema, tabname, reorg_type, reorg_stat),
                      file=fout)
                result = ibm_db.fetch_tuple(stmt)
            print("--***Waiting for {} seconds, so far waited for {} seconds***".format(check_interval, time_waited),
                  file=fout)
            time.sleep(check_interval)
        else:
            print("--*** Detecting REORG(s) are all COMPLETED! ***", file=fout)
            return True
    print("ERROR: REORGs still in progress or having issues, please check!", file=sys.stderr)
    return False


def get_arguments():
    """
    Get the command-line arguments
    """
    aparser = argparse.ArgumentParser(description='Provide DB2 connection details to execute minimal reorg.')
    aparser.add_argument('--dbname', help='DB2 Database Name.', required=True)
    aparser.add_argument('--hostname', help='Hostname of server (defaults to localhost).', default='localhost')
    aparser.add_argument('--port', help='Port# DB2 is listening on (defaults to 50000).', default=50000)
    aparser.add_argument('--userid', help='Userid to connect to DB2 (defaults to dbname).', required=False)
    aparser.add_argument('--password', help='Password to connect to DB2.', required=True)
    aparser.add_argument('--loglevel', help='Logging Level (defaults to CRITICAL).', required=False, default='CRITICAL',
                         choices=['DEBUG', 'INFO', 'ERROR', 'CRITICAL'], type=str.upper)
    aparser.add_argument('--scope', help=(
        'Specify the scope of the tables/indexes to be evaluated (T for Table / S for Schema).'), required=True,
                         choices=['T', 'S'], type=str.upper)
    aparser.add_argument('--criteria', help=(
        'If scope is T, then provide fully qualified tablename/ALL/USER for all user defined tables/'
        'SYSTEM for system-defined tables *OR* scope is S provide schema name.'), required=True)
    aparser.add_argument('--exec', help='Execute Reorg or Generate commands (defaults to G).', default='G',
                         choices=['R', 'G'], type=str.upper)
    aparser.add_argument('--IX_TB', help='Process Tables, Indexes or Both (defaults to B).', default='B',
                         choices=['T', 'I', 'B'], type=str.upper)
    aparser.add_argument('--do_runstats',
                         help='Execute Runstats for tables/indexes that need reorg (defaults to True).', required=False,
                         type=bool, default=True)
    aparser.add_argument('--check_interval',
                         help='Check for reorg completion\'s interval time in seconds  (defaults to 5secs).',
                         required=False, default=5, type=int)
    aparser.add_argument('--timeout',
                         help='Check for reorg completion\'s timeout in seconds  (defaults to 600secs).',
                         required=False, default=600, type=int)
    aparser.add_argument('--output_file',
                         help='Output file with commands to execute or executed details (defaults to stdout).',
                         required=False)

    try:
        return aparser.parse_args()
    except IOError as msg:
        aparser.error(str(msg))


if __name__ == '__main__':
    try:
        starttime = datetime.utcnow()
        conn, fout = None, None
        args = get_arguments()
        DEFAULT_LOGGING = {
            'version': 1,
            'disable_existing_loggers': False,
            'formatters': {
                'standard': {
                    'format': '[%(asctime)s] [PID:%(process)d TID:%(thread)d] [%(levelname)s] [%(name)s] [%(funcName)s():%(lineno)s] %(message)s'
                },
            },
            'handlers': {
                'default': {
                    'level': args.loglevel,
                    'formatter': 'standard',
                    'class': 'logging.StreamHandler',
                },
            },
            'loggers': {
                '': {
                    'level': args.loglevel,
                    'handlers': ['default'],
                    'propagate': True
                }
            }
        }
        logging.config.dictConfig(DEFAULT_LOGGING)
        logger.info("Start of Script: {}".format(starttime))

        # Get connection details to DB2 database underlying the LDAP server
        if args.userid:
            userid = args.userid
        else:
            userid = args.dbname
        conn_str = (
            "DATABASE={};"
            "HOSTNAME={};"
            "PORT={};"
            "PROTOCOL=TCPIP;"
            "UID={};"
            "PWD={};"
        ).format(args.dbname, args.hostname, args.port, userid, args.password)
        logger.debug("DB2 Connection: {}".format(conn_str))
        conn = ibm_db.pconnect(conn_str, "", "")
        if args.output_file:
            fout = open(args.output_file, 'w')
        else:
            fout = sys.stdout

        print('--Executing Minimal Reorg--', file=fout)
        print('---------------------------', file=fout)
        print('--***Assuming STATS are Current***', file=fout)
        if args.IX_TB == 'B' or args.IX_TB == 'I':
            ilist = identify_indexes(args.scope, args.criteria)
        if args.IX_TB == 'B' or args.IX_TB == 'T':
            tlist = identify_tables(args.scope, args.criteria)
        if args.IX_TB == 'B' or args.IX_TB == 'I':
            process_indexes(ilist, args.exec, fout)
        if args.IX_TB == 'B' or args.IX_TB == 'T':
            process_tables(tlist, args.exec, fout)
        if ilist or tlist:  # Runstats needed only when there is something to process
            if not args.do_runstats:
                print('--***Recommend RUNSTATS after REORG (which is asychronous)***', file=fout)
                print('--***-----------------------------------------------------***', file=fout)
            else:
                reorg_success = True
                if args.exec == 'R':
                    print('--***Waiting for REORG to complete before executing RUNSTATS***', file=fout)
                    reorg_success = wait_for_reorg_completion(args.check_interval, args.timeout, fout)
                    print('--*** REORG(s) complete! Now on to RUNSTATS... ***', file=fout)
                else:
                    print(
                        '--***Executing RUNSTATS right after REORG (which is ansychronous, so might not be effective)***',
                        file=fout)
                if reorg_success:
                    process_runstats(ilist, tlist, args.exec, fout)
                else:
                    print("--Use following RUNSTATS commands after REORG completes or issues resolved:")
                    process_runstats(ilist, tlist, 'G', fout)

        endtime = datetime.utcnow()
        logger.info("End of Script: {}".format(endtime))
        print("--Script ran for: {}".format(endtime - starttime), file=fout)
    except Exception as e:
        conn_error = ibm_db.conn_error()
        stmt_error = ibm_db.stmt_error()
        if conn_error != '':
            print("Error Code: {} Msg: {}".format(conn_error, ibm_db.conn_errormsg()), file=sys.stderr)
        elif stmt_error != '':
            print("Error Code: {} Msg: {}".format(stmt_error, ibm_db.stmt_errormsg()), file=sys.stderr)
        raise e
    finally:
        if fout and fout is not sys.stdout:
            fout.close()
        if conn:
            ibm_db.close(conn)
