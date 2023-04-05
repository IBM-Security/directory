import csv

from datetime import datetime
import argparse
import logging.config
import logging
import sys
from ldif import LDIFParser
import distutils.util

logger = logging.getLogger(__name__)


def get_version():
    # Please update every time a change is made, semantic conventions to be used
    return '1.0.6'


class LDIF2CSV(LDIFParser):
    """
    Load existing DNs and CNs from ISV.
    """

    def __init__(self, inputf, csvWriter, header, decode):
        LDIFParser.__init__(self, inputf)
        # Counter's to keep track of counts
        self.entryCount = 0
        self.csvWriter = csvWriter
        self.header = header
        self.headers = ['dn']  # DN should be present for all LDIF entries
        self.decode = decode
        self.entries = []

    def handle(self, dn, entry):
        c = [dn]
        e = {'dn': dn}
        for k, v in entry.items():
            if not (k in self.headers):
                self.headers.append(k)
            vv = None  # Decoded and collapsed value of each attribute
            if len(v) == 1:
                vv = v[0].decode(self.decode)
                e[k] = v[0].decode(self.decode)
            else:
                vv = b'|'.join(v).decode(self.decode)
            c.append(vv)
            e[k] = vv
        if self.header:
            self.entries.append(e)  # Storing entries in memory ONLY if headers needed
        else:
            self.csvWriter.writerow(c)
        self.entryCount += 1


def get_arguments():
    # Get the command-line arguments
    aparser = argparse.ArgumentParser(description='Convert LDIF File into a CSV format.')
    aparser.add_argument('--input_file', help='LDIF File to process (include path if needed, defaults to stdin).',
                         required=False)
    aparser.add_argument('--csv_file', help='CSV File to output (include path if needed, defaults to stdout).',
                         required=False)
    aparser.add_argument('--header', help='TRUE/FALSE - do you want headers in output?', default='false',
                         choices=['true', 'y', 'yes', '1', 'on', 'false', 'n', 'no', '0', 'off'],
                         type=str.lower)
    aparser.add_argument('--decode', help='Output to be decoded? Provide target decode format (default is utf-8).',
                         default='utf-8', required=False)
    aparser.add_argument('--loglevel', help='Logging Level (defaults to CRITICAL).', required=False, default='CRITICAL',
                         choices=['DEBUG', 'INFO', 'ERROR', 'CRITICAL'], type=str.upper)

    try:
        return aparser.parse_args()
    except IOError as msg:
        aparser.error(str(msg))


if __name__ == '__main__':
    try:
        inp_f, csvFile = None, None
        starttime = datetime.utcnow()
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

        print('--Executing LDIF to CSV Conversions v{}--'.format(get_version()))
        print('-------------------------------------------')

        inp_f = sys.stdin
        if args.input_file:
            logger.debug("Using {} as input - instead of default stdin.".format(args.input_file))
            inp_f = open(args.input_file, 'r')

        if args.csv_file:
            logger.debug("Using {} as output - instead of default stdout.".format(args.csv_file))
            csvFile = open(args.csv_file, 'w')
        else:
            csvFile = sys.stdout

        header = bool(distutils.util.strtobool(args.header))
        logger.info(
            "Include headers: {} - note that LDIF will be parsed into memory for processing headers.".format(header))

        # Process LDIF file - will parse into memory if headers are needed
        parser = None
        with inp_f as fin:
            csvWriter = csv.writer(csvFile)
            parser = LDIF2CSV(fin, csvWriter, header, args.decode)
            parser.parse()
        inp_f.close()
        if header:  # check if CSV needs to be written with header
            logger.info("Writing CSV with headers")
            csvWriter = csv.DictWriter(csvFile, sorted(parser.headers))
            csvWriter.writeheader()
            # Writing out LDIF parsed into memory
            csvWriter.writerows(parser.entries)  # Parsed entries will be in memory!

        logger.info("Headers detected {}.".format(parser.headers))
        logger.info("Count of Records {} total.".format(parser.entryCount))
        print("Total records processed: {}".format(parser.entryCount))

    except IOError as fe:
        logger.critical("Please provide valid path of an existing input file: {}".format(args.input_file))
        logger.critical(fe)
    except Exception as e:
        raise e
    finally:
        endtime = datetime.utcnow()
        logger.info("End of Script: {}".format(endtime))
        print("--Script v{} ran for: {}".format(get_version(), endtime - starttime))

        if inp_f and inp_f is not sys.stdin:
            inp_f.close()
        if csvFile and csvFile is not sys.stdout:
            csvFile.close()
