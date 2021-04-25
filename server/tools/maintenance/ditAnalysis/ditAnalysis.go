// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
        "database/sql"
        "fmt"
        _ "github.com/ibmdb/go_ibm_db"
        log "github.com/sirupsen/logrus"
        "os"
        "strings"
)

type ConsumerWriter interface {
        writeHeader()
        writeRow(dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid string)
        writeTrailer()
}

func ditAnalysis(configInfo ConfigInfo) error {
        log.Debug("DB2 Connection: %s", configInfo.databases[0].connectionString)
        db := createConn(configInfo.databases[0].connectionString)
        if db == nil {
                fmt.Printf("Unable to connect successfully!")
                os.Exit(1)
        }
        configInfo.consumerWriter.writeHeader()
        schema := configInfo.databases[0].schema
        sqlQueryComponents := []string{
        "select lem.dn, t.count, t.min_mt, t.max_mt, t.min_ct, t.max_ct, lem.eid, lem.peid",
        "  from %s.ldap_entry as lem,",
        "       (select le.PEID as PEID, count(*) as count,",
        "               max(le.modify_timestamp) as max_mt, min(le.modify_timestamp) as min_mt,",
        "               max(le.create_timestamp) as max_ct, min(le.create_timestamp) as min_ct",
        "        from %s.ldap_entry le",
        "        group by le.PEID",
        "        ) as t ",
        "where lem.eid = t.PEID ",
        "order by lem.eid"}
        sqlQueryTemplate := strings.Join(sqlQueryComponents, "")
        sqlQuery := fmt.Sprintf(sqlQueryTemplate, schema, schema)
        log.Debug(fmt.Sprintf("Executing SQL: %s", sqlQuery))
        st, err := db.Prepare(sqlQuery)
        if err != nil {
                return err
        }
        rows, err := st.Query()
        if err != nil {
                return err
        }
        defer rows.Close()
        for rows.Next() {
                var dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid string
                err = rows.Scan(&dn, &count, &min_mt, &max_mt, &min_ct, &max_ct, &eid, &peid)
                if err != nil {
                        return err
                }
                log.Debug(fmt.Sprintf("dn: %s count: %s min_mt: %s max_mt: %s min_ct: %s max_ct: %s eid: %s peid: %s", dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid))
                configInfo.consumerWriter.writeRow(dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid)
        }
        configInfo.consumerWriter.writeTrailer()
        return nil
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

