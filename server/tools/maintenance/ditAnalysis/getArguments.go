// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
	"flag"
	"fmt"
	_ "github.com/ibmdb/go_ibm_db"
	log "github.com/sirupsen/logrus"
	"os"
	"strings"
)

type DatabaseInfo struct {
	hostname         string
	port             int
	userid           string
	password         string
	dbname           string
	schema           string
	connectionString string
}

type OutputInfo struct {
	format   string
	filename string
}

type ConfigInfo struct {
	databases      []DatabaseInfo
	logLevel       string
	outputInfo     OutputInfo
	consumerWriter ConsumerWriter
}

// getArguments parses and validates the command line arguments and builds a ConfigInfo structure with all the required information.
func getArguments(programName string) ConfigInfo {
	fs := flag.NewFlagSet(programName, flag.ContinueOnError)
	dbnameArg := fs.String("dbname", "", "DB2 Database Name underlying LDAP.")
	hostnameArg := fs.String("hostname", "localhost", "Hostname of LDAP server (defaults to localhost).")
	portArg := fs.Int("port", 50000, "Port# DB2 is listening on (defaults to 50000).")
	schemaArg := fs.String("schema", "", "DB2 Table name schema (defaults to userid).")
	useridArg := fs.String("userid", "", "Userid to connect to DB2 (defaults to dbname).")
	passwordArg := fs.String("password", "", "Password to connect to DB2.")
	loglevelArg := fs.String("loglevel", "CRITICAL", "Logging Level (defaults to CRITICAL).")
	outputFormatArg := fs.String("output_format", "CSV", "Text output, CSV format or PNG (defaults to CSV).")
	output_fileArg := fs.String("output_file", "", "Output CSV of DIT statistics (defaults to stdout).")
	helpArg := fs.Bool("help", false, "Display the full help text")

	if err := fs.Parse(os.Args[1:]); err != nil {
		os.Exit(1)
	}

	if *helpArg {
		doHelp(programName)
	}

	if *dbnameArg == "" || *passwordArg == "" {
		requiredArguments := ""
		if *dbnameArg == "" {
			requiredArguments += " --dbname"
		}
		if *passwordArg == "" {
			requiredArguments += " --password"
		}
		message := fmt.Sprintf("%s.go: error: the following arguments are required: %s\n", programName, requiredArguments)
		doUsage(programName, message)
	}

	userid := *useridArg
	if *useridArg == "" {
		userid = *dbnameArg
	}
	schema := *schemaArg
	if schema == "" {
		schema = *useridArg
	}

	switch strings.Title(*loglevelArg) {
	case "Trace":
		log.SetLevel(log.TraceLevel)
	case "Debug":
		log.SetLevel(log.DebugLevel)
	case "Info":
		log.SetLevel(log.InfoLevel)
	case "Warn":
		log.SetLevel(log.WarnLevel)
	case "Error":
		log.SetLevel(log.ErrorLevel)
	case "Fatal":
		log.SetLevel(log.FatalLevel)
	case "Panic":
		log.SetLevel(log.PanicLevel)
	default:
		log.SetLevel(log.ErrorLevel)
	}

	log.SetFormatter(&log.TextFormatter{
		DisableColors: true,
		FullTimestamp: true,
	})

	log.SetReportCaller(true)

	connectionString := fmt.Sprintf("HOSTNAME=%s;DATABASE=%s;PORT=%d;UID=%s;PWD=%s", *hostnameArg, *dbnameArg, *portArg, userid, *passwordArg)

	databaseInfo := DatabaseInfo{
		hostname:         *hostnameArg,
		port:             *portArg,
		userid:           userid,
		password:         *passwordArg,
		dbname:           *dbnameArg,
		schema:           schema,
		connectionString: connectionString,
	}

	outputInfo := OutputInfo{
		format:   *outputFormatArg,
		filename: *output_fileArg,
	}

	var consumerWriter ConsumerWriter
	switch strings.ToUpper(*outputFormatArg) {
	case "CSV":
		consumerWriter = &csvConsumerWriter{filename: *output_fileArg}

	case "Text":
		consumerWriter = &textConsumerWriter{filename: *output_fileArg}

	case "PNG":
		consumerWriter = &pngConsumerWriter{filename: *output_fileArg}
		
        default:
                consumerWriter = &textConsumerWriter{filename: *output_fileArg}

	}

	return ConfigInfo{
		databases:      []DatabaseInfo{databaseInfo},
		logLevel:       *loglevelArg,
		outputInfo:     outputInfo,
		consumerWriter: consumerWriter,
	}
}

// doUsage prints out abbreviated usage info.
func doUsage(programName, message string) {
	fmt.Println(strings.TrimSpace(`
usage: ` + programName + ` [-h] --dbname DBNAME [--hostname HOSTNAME] [--port PORT] 
                       [--schema SCHEMA] [--userid USERID] --password PASSWORD
                       [--loglevel {DEBUG,INFO,ERROR,CRITICAL}]
                       [--output_format {CSV,Text}]
                       [--output_file OUTPUT_FILE]
`))
	if message != "" {
		fmt.Println(message)
	}
	os.Exit(1)
}

// doHelp prints out usage and description of the accepted arguments.
func doHelp(programName string) {
	fmt.Println(strings.TrimSpace(`
usage: ` + programName + ` [-h] --dbname DBNAME [--hostname HOSTNAME] [--port PORT] 
                       [--schema SCHEMA] [--userid USERID] --password PASSWORD
                       [--loglevel {DEBUG,INFO,ERROR,CRITICAL}]
                       [--output_format {CSV, Text}]
                       [--output_file OUTPUT_FILE]

Provide DB2 connection details to analyze DIT statistics.

optional arguments:
  -h, --help           show this help message and exit
  --dbname DBNAME      DB2 Database Name underlying LDAP.
  --hostname HOSTNAME  Hostname of LDAP server (defaults to localhost).
  --port PORT          Port# DB2 is listening on (defaults to 50000).
  --schema SCHEMA      DB2 Table name schema (defaults to userid).
  --userid USERID      Userid to connect to DB2 (defaults to dbname).
  --password PASSWORD  Password to connect to DB2.
  --loglevel {DEBUG,INFO,ERROR,CRITICAL}
                       Logging Level (default CRITICAL).
  --outputcsv {true,y,yes,1,on,false,n,no,0,off}
  --output_format      CSV format or Text output (defaults to CSV).        
  --output_file OUTPUT_FILE
                        Output file for DIT statistics (Defaults to stdout).
`))
	os.Exit(1)
}
