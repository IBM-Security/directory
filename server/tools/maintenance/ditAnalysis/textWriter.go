// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
        "fmt"
)

type textConsumerWriter struct {
       filename string
       sortColumn string
}

var DIT *ditNode

func (t *textConsumerWriter) writeHeader() {
        fmt.Println("Directory Information Tree (DIT) Visualization")
        fmt.Println("----------------------------------------------")
        DIT = newDIT()
}

func (t *textConsumerWriter) writeRow(dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid string) {
        //fmt.Printf("dn: %s count: %s min_mt: %s max_mt: %s min_ct: %s max_ct: %s\n", dn, count, min_mt, max_mt, min_ct, max_ct)
        DIT.add_node(dn, eid, peid, count)
}

func (t *textConsumerWriter) writeTrailer() {
        DIT.calculateCounts() 
        DIT.sortNodes(t.sortColumn)
        DIT.visualize("","")
}
