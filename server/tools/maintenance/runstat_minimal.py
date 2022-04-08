import ibm_db
from datetime import datetime
import argparse
import logging.config
import logging
import sys

logger = logging.getLogger(__name__)


def get_version():
    # Please update every time a change is made, semantic conventions to be used
    return '1.0.0'


def gather_tabledata(conn, schema):
    # Query catalog table for all information on tables (includes real time data)
    if schema:
        schema_check = " and ST.CREATOR = '{}'".format(schema)
    else:
        schema_check = ""
    sql = ("Select ST.CREATOR, ST.NAME, ST.CTIME, ST.CARD, ST.STATS_TIME, ST.REFRESH_TIME"
           "     , ST.LAST_REGEN_TIME, ST.INVALIDATE_TIME, ST.ALTER_TIME, MGT.TABLE_SCANS"
           "     , MGT.ROWS_READ, MGT.ROWS_INSERTED, MGT.ROWS_UPDATED, MGT.ROWS_DELETED, MGT.STATS_ROWS_MODIFIED"
           "     , MGT.RTS_ROWS_MODIFIED"
           " from sysibm.systables ST, table(MON_GET_TABLE('','',-1)) as MGT"
           " where ST.type = 'T'"
           "   and ST.creator = MGT.tabschema"
           "   and ST.name = MGT.tabname"
           "{}"
           " order by ST.creator, ST.name  with UR").format(schema_check)
    logger.debug("Executing SQL: {}".format(sql))
    stmt = ibm_db.exec_immediate(conn, sql)
    catalog_data = []
    result = ibm_db.fetch_tuple(stmt)
    while (result):
        cdata = {}
        cdata['creator'] = result[0]
        cdata['name'] = result[1]
        cdata['ctime'] = result[2]
        cdata['card'] = result[3]
        cdata['stats_time'] = result[4]
        cdata['refresh_time'] = result[5]
        cdata['last_regen_time'] = result[6]
        cdata['invalidate_time'] = result[7]
        cdata['alter_time'] = result[8]
        cdata['table_scans'] = result[9]
        cdata['rows_read'] = result[10]
        cdata['rows_inserted'] = result[11]
        cdata['rows_updated'] = result[12]
        cdata['rows_deleted'] = result[13]
        cdata['stats_row_modified'] = result[14]
        cdata['rts_rows_modified'] = result[15]
        catalog_data.append(cdata)
        logger.debug(result)
        result = ibm_db.fetch_tuple(stmt)

    return catalog_data


def gather_dbdata(conn):
    # Get when instance was last started
    sql = ("Select MGI.DB2START_TIME, MGI.TIMEZONEOFFSET"
           " from table(MON_GET_INSTANCE(-1)) as MGI with UR")
    logger.debug("Executing SQL: {}".format(sql))
    stmt = ibm_db.exec_immediate(conn, sql)
    result = ibm_db.fetch_tuple(stmt)
    db_data = {}
    db_data['db2start_time'] = result[0]
    db_data['timezoneoffset'] = result[1]
    logger.debug("db2start_time: {}, timezoneoffset: {}".format(db_data['db2start_time'], db_data['timezoneoffset']))

    return db_data


def determine_runstat(tdata, dbdata, trigger_percent):
    runstat_tab_list = []
    for d in tdata:
        creator = d['creator'].strip()
        tab_name = "{}.{}".format(creator, d['name'])
        if not d['stats_time'] or d['stats_time'] < d['ctime']:
            runstat_tab_list.append(tab_name)
            logger.info("Statistics are not collected for this table: {}".format(tab_name))
        elif d['alter_time'] and d['stats_time'] < d['alter_time']:
            runstat_tab_list.append(tab_name)
            logger.info(
                "Statistics not collected since last ALTER for this table: {}, Stats: {} Alter: {}".format(
                    tab_name,
                    d['stats_time'],
                    d['alter_time']))
        elif d['refresh_time'] and d['stats_time'] < d['refresh_time']:
            runstat_tab_list.append(tab_name)
            logger.info(
                "Statistics not collected since last REFRESH for this table: {}, Stats: {} Alter: {}".format(
                    d['invalidate_time'],
                    d['stats_time'],
                    d['refresh_time']))
        elif d['last_regen_time'] and d['stats_time'] < d['last_regen_time']:
            runstat_tab_list.append(tab_name)
            logger.info(
                "Statistics not collected since last REGEN for this table: {}, Stats: {} Alter: {}".format(
                    d['invalidate_time'],
                    d['stats_time'],
                    d['last_regen_time']))
        elif d['invalidate_time'] and d['stats_time'] < d['invalidate_time']:
            runstat_tab_list.append(tab_name)
            logger.info(
                "Statistics not collected since last INVALIDATE for this table: {}, Stats: {} Alter: {}".format(
                    d['invalidate_time'],
                    d['stats_time'],
                    d['invalidate_time']))
        else:
            rows_modifed_since_dbstart = d['rows_inserted'] + d['rows_updated'] + d['rows_deleted']
            logger.debug("rows_modifed_since_dbstart: {}".format(rows_modifed_since_dbstart))
            if d['stats_row_modified'] < d['rts_rows_modified']:
                rows_modified_since_runstat = d['rts_rows_modified']
            else:
                rows_modified_since_runstat = d['stats_row_modified']
            logger.debug("rows_modified_since_runstat: {}".format(rows_modified_since_runstat))
            x = datetime.now() - dbdata['db2start_time']
            y = datetime.now() - d['stats_time']
            # Assumed constant rate of change - which maybe grossly off the mark, but should still be effective
            r = rows_modifed_since_dbstart * y.total_seconds() / x.total_seconds()
            logger.debug("Pro-rated since last stats of rows_modifed_since_dbstart: {}".format(r))
            # No need to prorate if last stats gathered was after latest DB2 start
            if d['stats_time'] > dbdata['db2start_time']:
                mr = rows_modified_since_runstat
            else:
                # Use largest of the pro-rated versus modified count since stats
                if r < rows_modified_since_runstat:
                    mr = rows_modified_since_runstat
                else:
                    mr = r
            logger.debug("Largest 'rows modified' to use: {}".format(mr))
            # If cardinality is indicating new table, any modified count will trigger runstat
            if d['card'] == 0 or d['card'] == -1:
                if mr:
                    rate_of_change = 100
                else:
                    rate_of_change = 0
            else:
                rate_of_change = mr * 100 / d['card']
            logger.debug("Rate of change determined: {}%".format(rate_of_change))
            if rate_of_change > trigger_percent:
                runstat_tab_list.append(tab_name)
                logger.info(
                    "Recommend Stats since modify rate is {}% > {}% for this table: {}.{}".format(rate_of_change,
                                                                                                  trigger_percent,
                                                                                                  creator,
                                                                                                  d['name']))
    return runstat_tab_list


def execute_runstats(conn, rdata, exec_cmds, fout):
    for t in rdata:
        sql = "RUNSTATS ON TABLE {} WITH DISTRIBUTION AND DETAILED INDEXES ALL ALLOW WRITE ACCESS;".format(t)
        print(sql, file=fout)
        if exec_cmds == 'R':
            logger.debug("Executing SQL: {}".format(sql))
            stmt = ibm_db.exec_immediate(conn, "CALL SYSPROC.ADMIN_CMD('{}')".format(sql[:-1]))
            # For now ibm_db does not support querying stmt to get results of command executed


def get_arguments():
    """
    Get the command-line arguments
    """
    aparser = argparse.ArgumentParser(description='Provide DB2 connection details to execute minimal runstat.')
    aparser.add_argument('--dbname', help='DB2 Database Name.', required=True)
    aparser.add_argument('--hostname', help='Hostname of server (defaults to localhost).', default='localhost')
    aparser.add_argument('--port', help='Port# DB2 is listening on (defaults to 50000).', default=50000)
    aparser.add_argument('--userid', help='Userid to connect to DB2 (defaults to dbname).', required=False)
    aparser.add_argument('--password', help='Password to connect to DB2.', required=True)
    aparser.add_argument('--loglevel', help='Logging Level (defaults to CRITICAL).', required=False, default='CRITICAL',
                         choices=['DEBUG', 'INFO', 'ERROR', 'CRITICAL'], type=str.upper)
    aparser.add_argument('--exec', help='Execute Runstat or Generate commands (defaults to G).', default='G',
                         choices=['R', 'G'], type=str.upper)
    aparser.add_argument('--schema',
                         help='Provide schema to restrict runstats execution to (defaults to None - all schemas).',
                         default=None, required=False)
    aparser.add_argument('--trigger_percent', choices=range(0, 101), metavar="[0-100]",
                         help='Modify records vs cardinality percentage used to trigger runstat (defaults to 10%).',
                         default=10, required=False)
    aparser.add_argument('--output_file',
                         help='Output file with commands to execute or executed details (defaults to stdout).',
                         required=False)
    aparser.add_argument('--serverCertificate', help='Server Certificate in .arm file.', required=False)
    aparser.add_argument('--clientKeystoredb', help='Client Keystore DB as .kdb file.', required=False)
    aparser.add_argument('--clientKeystash',
                         help='Client Keystore Stash as .sth file (required if keystoredb provided).', required=False)

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
        if args.serverCertificate:
            conn_str = "{}Security=ssl;SSLServerCertificate={};".format(conn_str, args.serverCertificate)
        elif args.clientKeystoredb:
            conn_str = "{}Security=ssl;SSLClientKeystoredb={};SSLClientKeystash={};".format(conn_str,
                                                                                            args.clientKeystoredb,
                                                                                            args.clientKeystash)
        logger.debug("DB2 Connection: {}".format(conn_str))
        conn = ibm_db.pconnect(conn_str, "", "")
        if args.output_file:
            fout = open(args.output_file, 'w')
        else:
            fout = sys.stdout

        print('--Executing Minimal Runstat v{}--'.format(get_version()), file=fout)
        print('------------------------------------', file=fout)
        tdata = gather_tabledata(conn, args.schema)
        dbdata = gather_dbdata(conn)
        rdata = determine_runstat(tdata, dbdata, args.trigger_percent)
        execute_runstats(conn, rdata, args.exec, fout)

        endtime = datetime.utcnow()
        logger.info("End of Script: {}".format(endtime))
        print("--Script v{} ran for: {}".format(get_version(), endtime - starttime), file=fout)
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
