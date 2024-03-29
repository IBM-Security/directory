// repl_data calculates the number of pending changes and the age of the oldest pending change for each consumer of each replication context.
package main

import (
	"database/sql"
	"encoding/base64"
	"flag"
	"fmt"
	_ "github.com/ibmdb/go_ibm_db"
	log "github.com/sirupsen/logrus"
	"gopkg.in/asn1-ber.v1"
	"os"
	"strings"
	"time"
)

func getVersion() (string) {
    // Please update every time a change is made, semantic conventions to be used
    return "0.0.11"
}

// findModifytimestamp steps through the asn1-encoded controlPacket until it finds a modifyTimestamp and returns the value.
func findModifytimestamp(controlPacket ber.Packet) (string, error) {
	if controlPacket.TagType == ber.TypeConstructed && controlPacket.Tag == ber.TagSequence {
		if controlPacket.Children[0].TagType == ber.TypePrimitive && controlPacket.Children[0].Tag == ber.TagOctetString {
			if controlPacket.Children[0].Value == "modifyTimestamp" {
				if controlPacket.Children[1].TagType == ber.TypeConstructed && controlPacket.Children[1].Tag == ber.TagSet {
					if controlPacket.Children[1].Children[0].TagType == ber.TypePrimitive && controlPacket.Children[1].Children[0].Tag == ber.TagOctetString {
						return string(controlPacket.Children[1].Children[0].ByteValue), nil
					}
				}
			}
		} else {
			for _, v := range controlPacket.Children {
				timestamp, err := findModifytimestamp(*v)
				if err == nil {
					return timestamp, nil
				}
			}
		}
	}
	return "", fmt.Errorf("no modifyTimestamp found")
}

// decodeAndFindModifytimestamp base64 decodes the control string and returns the modifyTimestamp from it.
func decodeAndFindModifytimestamp(control string) (string, error) {
	log.Debug(fmt.Sprintf("Decoding: %s", control))
	decodedControl, err := base64.StdEncoding.DecodeString(control)
	if err != nil {
		return "", fmt.Errorf("Error on base64 decode: ", err)
	}
	controlPacket := ber.DecodePacket(decodedControl)
	return findModifytimestamp(*controlPacket)
}

// getUpdateCount returns the number of updates in the change table specified.
func getUpdateCount(db *sql.DB, tablename string, schema string) (int, error) {
	getUpdateCountSQL := fmt.Sprintf("select count(id) from %s.%s with UR", schema, tablename)
	log.Debug(fmt.Sprintf("Executing SQL: %s", getUpdateCountSQL))
	var countChangeID int
	err := db.QueryRow(getUpdateCountSQL).Scan(&countChangeID)
	if err != nil {
		if strings.Contains(err.Error(), "SQL0204N") {
			log.Debug(fmt.Sprintf("%s.%s replication table was missing, returning 0 for count(id)", schema, tablename))
			err = fmt.Errorf("  No replication data found.")
		} else {
			err = fmt.Errorf("Error on Query: ", err)
		}
		return 0, err
	}
	return countChangeID, nil
}

// getLatestUpdate returns the most recent update in the change table specified.
func getLatestUpdate(db *sql.DB, tablename string, schema string) (int, error) {
	getLatestUpdateSQL := fmt.Sprintf("select max(id) from %s.%s with UR", schema, tablename)
	log.Debug(fmt.Sprintf("Executing SQL: %s", getLatestUpdateSQL))
	var maxChangeID int
	err := db.QueryRow(getLatestUpdateSQL).Scan(&maxChangeID)
	if err != nil {
		if strings.Contains(err.Error(), "SQL0204N") {
			log.Debug(fmt.Sprintf("%s.%s was missing, returning 0 for max(id)", schema, tablename))
			err = fmt.Errorf("  No replication data found.")
		} else {
			err = fmt.Errorf("Error on Query: ", err)
		}
		return 0, err
	}
	return maxChangeID, nil
}

// getChanges finds either the last successful change or the oldest pending change for each consumer in the specified change table.
func getChanges(db *sql.DB, tablename string, schema string, successful bool, configInfo *ConfigInfo) error {
	var changeid int
	if successful {
		changeid = 0
	} else {
		changeid = 1
	}
	updateCount, err := getUpdateCount(db, tablename, schema)
	if err != nil {
		return err
	}
	if updateCount == 0 {
		if successful {
			configInfo.consumerWriter.noReplicationData()
		}
		return nil
	}

	maxChangeID, err := getLatestUpdate(db, tablename, schema)
	if err != nil {
		return err
	}
	getChangesForContext := []string{
		"select",
		" dn, CONTROL_LONG, LASTCHANGEID",
		" from %s.LDAP_ENTRY, %s.REPLSTATUS, %s.%s",
		" where REPLSTATUS.LASTCHANGEID+%d=%s",
		".id and ldap_entry.eid=REPLSTATUS.eid with UR"}
	getChangesForContextTemplate := strings.Join(getChangesForContext, "")
	getChangesForContextSQL := fmt.Sprintf(getChangesForContextTemplate, schema, schema, schema, tablename, changeid, tablename)
	log.Debug(fmt.Sprintf("Executing SQL: %s", getChangesForContextSQL))
	st, err := db.Prepare(getChangesForContextSQL)
	if err != nil {
		return fmt.Errorf("Error on Prepare: ", err)
	}
	rows, err := st.Query()
	if err != nil {
		if strings.Contains(err.Error(), "SQL0204N") {
			err = fmt.Errorf("  Table %s does not exist\n", tablename)
		} else {
			err = fmt.Errorf("Error on Query: ", err)
		}
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var consumerDN, controls string
		var lastChangeID int
		err = rows.Scan(&consumerDN, &controls, &lastChangeID)
		if err != nil {
			return fmt.Errorf("Error on Scan: ", err)
		}
		log.Debug(fmt.Sprintf("consumerDN: %s controlString: %s lastChangeID: %s",
			consumerDN, controls, lastChangeID))
		consumerComponents := strings.SplitN(consumerDN, ",", 2)
		rdnComponents := strings.SplitN(consumerComponents[0], "=", 2)
		consumer := rdnComponents[1]
		controlComponents := strings.SplitN(controls, "control: 1.3.18.0.2.10.19 false:: ", 2)
		if len(controlComponents) < 2 {
			log.Info("No data found!")
			continue
		}
		control := strings.Join(strings.Split(controlComponents[1], "\n "), "")
		deltaChangeID := maxChangeID - lastChangeID
                timestamp, _ := decodeAndFindModifytimestamp(control)
                t, _ := time.Parse("20060102150405.000000Z", timestamp)
		if successful {
                        configInfo.consumerWriter.writeLastSuccessfulChange(consumer, t)
                        configInfo.consumerWriter.writeQueueLength(consumer, lastChangeID, deltaChangeID)
		} else {
                        configInfo.consumerWriter.writeFirstPendingChangeAge(consumer, t)
                }
	}
	return nil
}

// reportChangesForContexts finds all the replication contexts and reports the last successful and oldest pending changes for all consumers in each.
func reportChangesForContexts(db *sql.DB, configInfo *ConfigInfo) error {
        configInfo.consumerWriter.writeHeader()
	schema := configInfo.databases[0].schema
	listReplContexts := []string{
		"select ldap_entry.eid, ldap_entry.dn ",
		"from %s.ldap_entry, %s.replicaConsumerId ",
		"where ldap_entry.eid=replicaConsumerId.eid with UR"}
//		"from %s.ldap_entry, %s.OBJECTCLASS ",
//		"where ldap_entry.eid=objectclass.eid ",
//		"and OBJECTCLASS='IBM-REPLICATIONCONTEXT' with UR"}
	listReplContextsTemplate := strings.Join(listReplContexts, "")
	listReplContextsSQL := fmt.Sprintf(listReplContextsTemplate, schema, schema)
	log.Debug(fmt.Sprintf("Executing SQL: %s", listReplContextsSQL))
	st, err := db.Prepare(listReplContextsSQL)
	if err != nil {
		return err
	}
	rows, err := st.Query()
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var eid, context string
		err = rows.Scan(&eid, &context)
		if err != nil {
			return err
		}
		log.Debug(fmt.Sprintf("eid: %s context: %s", eid, context))
                configInfo.consumerWriter.startContext(context)
		tablename := fmt.Sprintf("REPLCHG%s", eid)
		err = getChanges(db, tablename, schema, true, configInfo) // Successful changes
		if err != nil {
			log.Info(fmt.Sprintf("No replication data found for successful changes, perhaps no replication setup for %s?", context))
			configInfo.consumerWriter.noReplicationData()
			continue
		}
		err = getChanges(db, tablename, schema, false, configInfo) // Oldest Pending changes
		if err != nil {
			fmt.Println(err)
		}
	}
	return nil
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

type ConfigInfo struct {
	databases  []DatabaseInfo
	logLevel   string
	outputInfo OutputInfo
	consumerWriter ConsumerWriter
}

type ConsumerWriter interface {
        writeHeader()
        startContext(context string)
        noReplicationData()
        writeQueueLength(consumer string, lastChangeID, deltaChangeID int)
        writeLastSuccessfulChange(consumer string, timestamp time.Time)
        writeFirstPendingChangeAge(consumer string, timestamp time.Time)
}

type textConsumerWriter struct {
       filename string
}

func (t *textConsumerWriter) writeHeader() {
        fmt.Println("Reporting last successful change / oldest pending changes for all contexts")
        fmt.Println("--------------------------------------------------------------------------")
}

func (t *textConsumerWriter) noReplicationData() {
        fmt.Println("  No replication data found.")
}

func (t *textConsumerWriter) startContext(context string) {
        fmt.Printf("\n%s replication status:\n", context)
}

func (t *textConsumerWriter) writeQueueLength(consumer string, lastChangeID, deltaChangeID int) {
        if deltaChangeID==0 {
                fmt.Printf("  Congratulations! No pending replication entries found for %s\n", consumer)
        } else {
                fmt.Printf("  %s last successful change ID is %d (queue length %d)\n", consumer, lastChangeID, deltaChangeID)
        }
}

func (t *textConsumerWriter) writeLastSuccessfulChange(consumer string, timestamp time.Time) {
  fmt.Printf("  %s last successful change's modifyTimestamp age is %v\n", consumer, time.Since(timestamp))
}

func (t *textConsumerWriter) writeFirstPendingChangeAge(consumer string, timestamp time.Time) {
  fmt.Printf("  %s oldest pending change's modifyTimestamp age is %v\n", consumer, time.Since(timestamp))
}

type csvConsumerWriter struct {
       filename string
       context  string
       consumer string
       successfulTimestamp time.Time
       pendingTimestamp time.Time
       queueSize int
}

func (t *csvConsumerWriter) writeHeader() {
        fmt.Println("Legend for output:")
        fmt.Println("  context - suffix or context present in server (may or may not be replicated).")
        fmt.Println("  consumer - hostname or ip address of server data is being replicated to.")
        fmt.Println("  successfulTimestamp - last successful change that was replicated.")
        fmt.Println("  pendingTimestamp - oldest pending change that needs to be replicated.")
        fmt.Println("  queueSize - number of objects pending in replication queue.")
        fmt.Println("")
        fmt.Println("Note: Timestamps are provided in UTC timezone.")
        fmt.Println("")
        fmt.Println("context,consumer,successfulTimestamp,pendingTimestamp,queueSize")
}

func (t *csvConsumerWriter) startContext(context string) {
        t.context = context
}

func (t *csvConsumerWriter) noReplicationData() {
        fmt.Printf("%s,,,,\n", t.context)
}

func (t *csvConsumerWriter) writeQueueLength(consumer string, lastChangeID, deltaChangeID int) {
        t.queueSize = deltaChangeID
}

func (t *csvConsumerWriter) writeLastSuccessfulChange(consumer string, timestamp time.Time) {
        t.successfulTimestamp = timestamp
}

func (t *csvConsumerWriter) writeFirstPendingChangeAge(consumer string, timestamp time.Time) {
        t.consumer = consumer
        t.pendingTimestamp = timestamp
        fmt.Printf("%s,%s,%v,%v,%d\n", t.context, t.consumer, t.successfulTimestamp, t.pendingTimestamp, t.queueSize)
}


// getArguments parses and validates the command line arguments and builds a ConfigInfo structure with all the required information.
func getArguments() (*ConfigInfo, error) {
    var err error
	fs := flag.NewFlagSet("repl_data", flag.ContinueOnError)
	dbnameArg := fs.String("dbname", "", "DB2 Database Name underlying LDAP.")
	hostnameArg := fs.String("hostname", "localhost", "Hostname of LDAP server (defaults to localhost).")
	portArg := fs.Int("port", 50000, "Port# DB2 is listening on (defaults to 50000).")
	schemaArg := fs.String("schema", "", "DB2 Table name schema (defaults to userid).")
	useridArg := fs.String("userid", "", "Userid to connect to DB2 (defaults to dbname).")
	passwordArg := fs.String("password", "", "Password to connect to DB2.")
	loglevelArg := fs.String("loglevel", "CRITICAL", "Logging Level (defaults to CRITICAL).")
	outputcsvArg := fs.Bool("outputcsv", false, "Text output or CSV format (defaults to False).")
	output_fileArg := fs.String("output_file", "", "Output CSV of differences (defaults to stdout).")
	dbislocalArg := fs.Bool("dblocal", true, "Connect to local database without id/password (defaults to True).")
	helpArg := fs.Bool("help", false, "Display the full help text")

	if err = fs.Parse(os.Args[1:]); err != nil {
		return nil, err
	}

	if *helpArg {
		err = doHelp("")
		return nil, err
	}

	if *dbnameArg == "" || (*passwordArg == "" && !*dbislocalArg) {
		requiredArguments := ""
		if *dbnameArg == "" {
			requiredArguments += " --dbname"
		}
		if *passwordArg == "" && !*dbislocalArg {
			requiredArguments += " --password"
		}
		message := fmt.Sprintf("repl_data.go: error: the following arguments are required: %s\n", requiredArguments)
		err = doHelp(message)
		return nil, err
	}

	switch strings.Title(*loglevelArg) {
	case "TRACE":
		log.SetLevel(log.TraceLevel)
	case "DEBUG":
		log.SetLevel(log.DebugLevel)
	case "INFO":
		log.SetLevel(log.InfoLevel)
	case "WARN":
		log.SetLevel(log.WarnLevel)
	case "ERROR":
		log.SetLevel(log.ErrorLevel)
	case "FATAL":
		log.SetLevel(log.FatalLevel)
	case "PANIC":
		log.SetLevel(log.PanicLevel)
	default:
		log.SetLevel(log.ErrorLevel)
	}

	log.SetFormatter(&log.TextFormatter{
		DisableColors: true,
		FullTimestamp: true,
	})

	log.SetReportCaller(true)

	userid := *useridArg
	if *useridArg == "" {
		userid = *dbnameArg
		log.Debug("Userid being set to dbname: ", userid)
	}
	schema := *schemaArg
	if schema == "" {
		schema = userid
		log.Debug("Schema being set to userid: ", schema)
	}

	var connectionString string
	if *dbislocalArg {
		if *passwordArg == "" {
			connectionString = fmt.Sprintf("dsn=%s", *dbnameArg)
		} else {
			connectionString = fmt.Sprintf("dsn=%s;uid=%s;pwd=%s", *dbnameArg, userid, *passwordArg)
		}
	} else {
		connectionString = fmt.Sprintf("HOSTNAME=%s;DATABASE=%s;PORT=%d;UID=%s;PWD=%s", *hostnameArg, *dbnameArg, *portArg, userid, *passwordArg)
	}

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
		csv:      *outputcsvArg,
		filename: *output_fileArg,
	}

	var consumerWriter ConsumerWriter
	if *outputcsvArg {
            consumerWriter = &csvConsumerWriter{filename: *output_fileArg}
        } else {
	        consumerWriter = &textConsumerWriter{filename: *output_fileArg}
        }

	return &ConfigInfo{
		databases:  []DatabaseInfo{databaseInfo},
		logLevel:   *loglevelArg,
		outputInfo: outputInfo,
                consumerWriter: consumerWriter,
	}, nil
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

// doHelp prints out usage and description of the accepted arguments.
func doHelp(message string) error {
	fmt.Println(strings.TrimSpace(`
usage: repl_data.go [-h] --dbname DBNAME [--hostname HOSTNAME] [--port PORT]
                       [--schema SCHEMA] [--userid USERID] --password PASSWORD
                       [--loglevel {DEBUG,INFO,ERROR,TRACE,FATAL,PANIC}]
                       [--outputcsv {true,y,yes,1,on,false,n,no,0,off}]
                       [--output_file OUTPUT_FILE]
                       [--dblocal {true,y,yes,1,on,false,n,no,0,off}]
`))
// Print abbreviated help if a message needs to be posted
	if message != "" {
		fmt.Println(message)
    	return nil
	}
	fmt.Println(strings.TrimSpace(`
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
  --dblocal {true,y,yes,1,on,false,n,no,0,off}
                       Indicate if database is local, skip id details to use current user
`))
    err := fmt.Errorf("Please see help text above on how to use this tool.")
	return err
}

// Time the execution of a particular function
func timer(name string) func() {
    start := time.Now()
    return func() {
        fmt.Printf("%s took %v\n", name, time.Since(start))
    }
}

func main() {
    // Exit with return code
    code := 0
    defer func() {
      os.Exit(code)
    }()

    // Time execution of this function, which should be entire script
    defer timer(fmt.Sprintf("\nScript v%s", getVersion()))()

	configInfo, err := getArguments()
	log.Debug("DB2 Connection: ", configInfo.databases[0].connectionString)
	if configInfo != nil {
        conn := createConn(configInfo.databases[0].connectionString)
        if conn == nil {
            fmt.Printf("Unable to connect successfully!")
            code = 1
        } else {
            err = reportChangesForContexts(conn, configInfo)
            if err != nil {
                fmt.Println(err)
            }
        }
    } else {
        code = 1
    }
}