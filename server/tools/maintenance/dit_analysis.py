import ibm_db
from datetime import datetime
import argparse
import logging.config
import logging
import csv
import sys
import distutils.util

logger = logging.getLogger(__name__)


class DIT(object):
    def __init__(self, dn=None, eid=-1, peid=None, count=None):
        self.dn = dn
        self.eid = eid
        self.peid = peid
        self.count = count
        self.nodes = []
        self.descendantCount = 0

    def add_node(self, dn, eid, peid, count):
        # Assume that Parent will be added first and be present always
        # based on EID being monotonically increasing and data sorted on it
        if self.eid == peid:
            logger.debug("Adding DN: {}, PEID: {} matched EID: {}".format(dn, peid, self.eid))
            self.nodes.append(DIT(dn, eid, peid, count))
            return True
        else:
            for n in self.nodes:
                if n.add_node(dn, eid, peid, count):
                    return True
        return False

    def visualize(self, prefix='', nodePrefix=''):
        if self.dn is None:
            print("/ ({} suffixes, {} total entries)".format(len(self.nodes), self.descendantCount))
        else:
            print("{}{}({}, {})".format(prefix, self.name_from_dn(), self.count, self.descendantCount))
        for i, n in enumerate(self.nodes, start=1):
            if i < len(self.nodes):
                n.visualize(nodePrefix + '├── ', nodePrefix + '│   ')
            else:
                n.visualize(nodePrefix + '└── ', nodePrefix + '    ')

    def name_from_dn(self):
        if self.peid == -1:
            return self.dn
        else:
            return self.dn.split(',', 1)[0]

    def calculateCounts(self):
        if self.count is None:
            self.descendantCount = len(self.nodes) # beginning of tree
        else:
            self.descendantCount = self.count
        for n in self.nodes:
            self.descendantCount += n.calculateCounts()

        return self.descendantCount


def print_legend(csvFile, outputcsv):
    """
    Print a legend describing what the CSV output looks like.
    """
    if outputcsv:
        print("Legend for output:")
        print("  dn - dn for the DIT node.")
        print("  count - number of objects in that node (same as numsubordinates count).")
        print("  min_mt - lowest modified timestamp of objects in that node.")
        print("  max_mt - highest modified timestamp of objects in that node.")
        print("  min_ct - lowest creation timestamp of objects in that node.")
        print("  max_ct - highest creation timestamp of objects in that node.")
        print("")
        print("Note: Timestamps are provided in UTC timezone. Uncommitted data will be analyzed.")
        print("")
        writer = csv.DictWriter(csvFile, ['dn', 'count', 'min_mt', 'max_mt', 'min_ct', 'max_ct'])
        writer.writeheader()
        return writer
    else:
        print('Directory Information Tree (DIT) Visualization')
        print('----------------------------------------------')
        return None


def processcsv_createdit(csvWriter, result, outputcsv, dit):
    if outputcsv:
        csvWriter.writerow({
            'dn': result[0],
            'count': result[1],
            'min_mt': result[2],
            'max_mt': result[3],
            'min_ct': result[4],
            'max_ct': result[5]
        })
    if dit.add_node(dn=result[0], eid=result[6], peid=result[7], count=result[1]):
        logger.debug("Added DN: to DIT".format(result[0]))
    else:
        logger.error("Unable to find parent for DN: {} EID: {}".format(result[0], result[6]))


def dit_analysis(schema, csvFile, outputcsv):
    writer = print_legend(csvFile, outputcsv)
    sql = (
        "select lem.dn, t.count, t.min_mt - current timezone, t.max_mt - current timezone,"
        "        t.min_ct - current timezone, t.max_ct - current timezone, lem.eid, lem.peid"
        "  from {}.ldap_entry as lem,"
        "       (select le.PEID as PEID, count(*) as count,"
        "               max(le.modify_timestamp) as max_mt, min(le.modify_timestamp) as min_mt,"
        "               max(le.create_timestamp) as max_ct, min(le.create_timestamp) as min_ct"
        "        from {}.ldap_entry le"
        "        group by le.PEID with UR) as t "
        "where lem.eid = t.PEID "
        "order by lem.eid with UR"
    ).format(schema, schema)
    logger.debug("Executing SQL: {}".format(sql))
    dit = DIT()
    stmt = ibm_db.exec_immediate(conn, sql)
    result = ibm_db.fetch_tuple(stmt)
    while (result):
        processcsv_createdit(writer, result, outputcsv, dit)
        logger.debug("result: {}".format(result))
        result = ibm_db.fetch_tuple(stmt)
    dit.calculateCounts()
    dit.visualize()


def get_arguments():
    """
    Get the command-line arguments
    """
    aparser = argparse.ArgumentParser(description='Provide DB2 connection details to analyze DIT for LDAP.')
    aparser.add_argument('--dbname', help='DB2 Database Name underlying LDAP.', required=True)
    aparser.add_argument('--hostname', help='Hostname of LDAP server (defaults to localhost).', default='localhost')
    aparser.add_argument('--port', help='Port# DB2 is listening on (defaults to 50000).', default=50000)
    aparser.add_argument('--schema', help='DB2 Table name schema (defaults to userid).', required=False)
    aparser.add_argument('--userid', help='Userid to connect to DB2 (defaults to dbname).', required=False)
    aparser.add_argument('--password', help='Password to connect to DB2.', required=True)
    aparser.add_argument('--loglevel', help='Logging Level (defaults to CRITICAL).', required=False, default='CRITICAL',
                         choices=['DEBUG', 'INFO', 'ERROR', 'CRITICAL'], type=str.upper)
    aparser.add_argument('--outputcsv', help='Visualize DIT or CSV format (defaults to True).', required=False,
                         default='true', choices=['true', 'y', 'yes', '1', 'on', 'false', 'n', 'no', '0', 'off'],
                         type=str.lower)
    aparser.add_argument('--output_file', help='Output CSV of DIT nodes (defaults to stdout).', required=False)

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
        if args.schema:
            schema = args.schema
        else:
            schema = userid
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
        outputcsv = bool(distutils.util.strtobool(args.outputcsv))
        dit_analysis(schema, fout, outputcsv)
        endtime = datetime.utcnow()
        logger.info("End of Script: {}".format(endtime))
        print("Script ran for: {}".format(endtime - starttime))
    except Exception as e:
        conn_error = ibm_db.conn_error()
        stmt_error = ibm_db.stmt_error()
        if conn_error != '':
            print("Error Code: {} Msg: {}".format(conn_error, ibm_db.conn_errormsg()))
        elif stmt_error != '':
            print("Error Code: {} Msg: {}".format(stmt_error, ibm_db.stmt_errormsg()))
        raise e
    finally:
        if fout and fout is not sys.stdout:
            fout.close()
        if conn:
            ibm_db.close(conn)
