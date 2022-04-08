// reorg_minimal calculates the number of pending changes and the age of the oldest pending change for each consumer of each replication context.
package main

import (
        "database/sql"
        "flag"
        "fmt"
        _ "github.com/ibmdb/go_ibm_db"
        log "github.com/sirupsen/logrus"
        "os"
        "strings"
        "time"
)

type ConfigInfo struct {
	databases  []DatabaseInfo
	logLevel   string
	outputInfo OutputInfo
	consumerWriter ConsumerWriter
}

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
	csv      bool
	filename string
}

type ConsumerWriter interface {
        writeHeader()
        startContext(context string)
        noReplicationData()
        writeQueueLength(consumer string, lastChangeID, deltaChangeID int)
        writeLastSuccessfulChange(consumer string, timestamp time.Time)
        writeFirstPendingChangeAge(consumer string, timestamp time.Time)
}

func main() {

        configInfo := getArguments()
        log.Debug("DB2 Connection: %s", configInfo.databases[0].connectionString)
        conn := createConn(configInfo.databases[0].connectionString)
        if conn == nil {
                fmt.Printf("Unable to connect successfully!")
                os.Exit(1)
        }
        err := reorgMinimal(conn, configInfo)
        if err != nil {
                fmt.Println(err)
        }
}

// getArguments parses and validates the command line arguments and builds a ConfigInfo structure with all the required information.
func getArguments() ConfigInfo {
        fs := flag.NewFlagSet("reorg_minimal", flag.ContinueOnError)
        dbnameArg := fs.String("dbname", "", "DB2 Database Name.")
        hostnameArg := fs.String("hostname", "localhost", "Hostname of LDAP server (defaults to localhost).")
        portArg := fs.Int("port", 50000, "Port# DB2 is listening on (defaults to 50000).")
	schemaArg := fs.String("schema", "", "DB2 Table name schema (defaults to userid).")
        useridArg := fs.String("userid", "", "Userid to connect to DB2 (defaults to dbname).")
        passwordArg := fs.String("password", "", "Password to connect to DB2.")
        loglevelArg := fs.String("loglevel", "CRITICAL", "Logging Level (defaults to CRITICAL).")
        scopeArg := fs.String("scope", "", "Specify the scope of the tables/indexes to be evaluated (T for Table / S for Schema).")
        criteriaArg := fs.String("criteria", "", "If scope is T, then provide fully qualified tablename/ALL/USER for all user defined tables/SYSTEM for system-defined tables *OR* scope is S provide schema name.")
        //execArg := fs.String("exec", "G", "Execute Reorg or Generate commands (defaults to G).")
        //IX_TBArg := fs.String("IX_TB", "B", "Process Tables, Indexes or Both (defaults to B).")
        //do_runstatsArg := fs.Bool("do_runstats", true, "Execute Runstats for tables/indexes that need reorg (defaults to True).")
        //check_intervalArg := fs.Int("check_interval", 5, "Check for reorg completion's interval time in seconds  (defaults to 5secs).")
        //timeoutArg := fs.Int("timeout", 600, "Check for reorg completion's timeout in seconds  (defaults to 600secs).")
        //output_fileArg := fs.String("output_file", "", "Output file with commands to execute or executed details (defaults to stdout).")
        helpArg := fs.Bool("help", false, "Display the full help text")
        
        if err := fs.Parse(os.Args[1:]); err != nil {
                os.Exit(1)
        }

        if *helpArg {
                doHelp()
        }

        requiredArguments := ""
        if *dbnameArg == "" {
                requiredArguments += " --dbname"
        }
        if *passwordArg == "" {
                requiredArguments += " --password"
        }
        if *scopeArg == "" {
                requiredArguments += " --scope"
        }
        if *criteriaArg == "" {
                requiredArguments += " --criteria"
        }
        if requiredArguments != "" {
                message := fmt.Sprintf("reorg_minimal.go: error: the following arguments are required: %s\n", requiredArguments)
                doUsage(message)
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

        //outputInfo := OutputInfo{
        //        csv:      *outputcsvArg,
        //        filename: *output_fileArg,
        //}

        //var consumerWriter ConsumerWriter
        //if *outputcsvArg {
        //        consumerWriter = &csvConsumerWriter{filename: *output_fileArg}
        //} else {
        //        consumerWriter = &textConsumerWriter{filename: *output_fileArg}
        //}
        
        return ConfigInfo{
                databases:  []DatabaseInfo{databaseInfo},
                logLevel:   *loglevelArg,
        //        outputInfo: outputInfo,
        //        consumerWriter: consumerWriter,
        }
}

// doHelp prints out usage and description of the accepted arguments.
func doHelp() {
	fmt.Println(strings.TrimSpace(`
usage: repl_data.go [-h] --dbname DBNAME [--hostname HOSTNAME] [--port PORT] 
                       [--schema SCHEMA] [--userid USERID] --password PASSWORD
                       [--loglevel {DEBUG,INFO,ERROR,CRITICAL}]
                       [--outputcsv {true,y,yes,1,on,false,n,no,0,off}]
                       [--output_file OUTPUT_FILE]

Provide DB2 connection details to determine replication status.

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
                       Test output or CSV format (Defaults to False).
  --output_file OUTPUT_FILE
                        Output CSV of differences (Defaults to stdout).
`))
	os.Exit(1)
}

// doUsage prints out abbreviated usage info.
func doUsage(message string) {
	fmt.Println(strings.TrimSpace(`
usage: repl_data.go [-h] --dbname DBNAME [--hostname HOSTNAME] [--port PORT] 
                       [--schema SCHEMA] [--userid USERID] --password PASSWORD
                       [--loglevel {DEBUG,INFO,ERROR,CRITICAL}]
                       [--outputcsv {true,y,yes,1,on,false,n,no,0,off}]
                       [--output_file OUTPUT_FILE]
`))
	if message != "" {
		fmt.Println(message)
	}
	os.Exit(1)
}

// createConn creates a database connection to the database using the specified connection string.
func createConn(con string) *sql.DB {
	db, err := sql.Open("go_ibm_db", con)
	if err != nil {
		fmt.Println(err)
		return nil
	}
	return db
}

func reorgMinimal(db *sql.DB, configInfo ConfigInfo) (err error) {
	return
}
