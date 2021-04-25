// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
        "fmt"
)

type csvConsumerWriter struct {
       filename string
       context  string
       consumer string
       queueSize int
}

func (t *csvConsumerWriter) writeHeader() {
        fmt.Println("Legend for output:")
        fmt.Println("  dn - dn for the DIT node.")
        fmt.Println("  count - number of objects in that node (same as numsubordinates count).")
        fmt.Println("  min_mt - lowest modified timestamp of objects in that node.")
        fmt.Println("  max_mt - highest modified timestamp of objects in that node.")
        fmt.Println("  min_ct - lowest creation timestamp of objects in that node.")
        fmt.Println("  max_ct - highest creation timestamp of objects in that node.")
        fmt.Println("")
        fmt.Println("Note: Timestamps are provided in UTC timezone.")
        fmt.Println("")
        fmt.Println("dn,count,min_mt,max_mt,min_ct,max_ct")
}

func (t *csvConsumerWriter) writeRow(dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid string) {
        fmt.Printf("%s, %s, %s, %s, %s, %s\n", dn, count, min_mt, max_mt, min_ct, max_ct)
}

func (t *csvConsumerWriter) writeTrailer() {
}