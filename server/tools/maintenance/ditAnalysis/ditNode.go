// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
	"fmt"
	log "github.com/sirupsen/logrus"
        "sort"
	"strconv"
	"strings"
)

type ditNode struct {
	dn              string
	eid             string
	peid            string
	childCount      int
	descendantCount int
	nodes           []ditNode
}

func newDIT() *ditNode {
	var DIT ditNode = ditNode{"", "-1", "", 0, 0, []ditNode{}}
	DIT.eid = "-1"
	return &DIT
}

func (d *ditNode) add_node(dn, eid, peid, count string) (success bool) {
	// Assume that Parent will be added first and be present always
	// based on EID being monotonically increasing and data sorted on it
	if d.eid == peid {
		log.Debug(fmt.Sprintf("Adding DN: %s, PEID: %s matched EID: %s", dn, peid, d.eid))
		childCount, _ := strconv.Atoi(count)
		d.nodes = append(d.nodes, ditNode{dn, eid, peid, childCount, 0, []ditNode{}})
		//log.Debug(fmt.Sprintf("%s has %d child nodes", d.dn, len(d.nodes)))
		return true
	} else {
		//log.Debug(fmt.Sprintf("Adding DN: %s, PEID: %s as child of DN: %s, EID: %s", dn, peid, d.dn, d.eid))
		//log.Debug(fmt.Sprintf("%s has %d child nodes", d.dn, len(d.nodes)))
		for i, _ := range d.nodes {
			if d.nodes[i].add_node(dn, eid, peid, count) {
				//log.Debug(fmt.Sprintf("%s has %d child nodes", d.nodes[i].dn, len(d.nodes[i].nodes)))
				return true
			}
		}
	}
	return false
}

func (d *ditNode) calculateCounts() int {
	d.descendantCount = d.childCount
	for i, _ := range d.nodes {
		d.descendantCount += d.nodes[i].calculateCounts() - 1
	}
	return d.descendantCount
}

func (d *ditNode) sortNodes(column string) {
	for i, _ := range d.nodes {
		d.nodes[i].sortNodes(column)
	}
	switch column {

	case "DN":
		sort.Sort(ByDN(d.nodes))

	case "descendantCount":
		sort.Sort(ByDescendantCount(d.nodes))
	}
}

// ByDN implements Sort.Interface for []ditNode based on the dn field, alphabetical order
type ByDN []ditNode

func (b ByDN) Len() int      { return len(b) }
func (b ByDN) Swap(i, j int) { b[i], b[j] = b[j], b[i] }
func (b ByDN) Less(i, j int) bool {
	return b[i].dn < b[j].dn
}

// ByDescendantCount implements Sort.Interface for []ditNode based on the descendantCount field, largest first
type ByDescendantCount []ditNode

func (b ByDescendantCount) Len() int           { return len(b) }
func (b ByDescendantCount) Swap(i, j int)      { b[i], b[j] = b[j], b[i] }
func (b ByDescendantCount) Less(i, j int) bool { return b[i].descendantCount > b[j].descendantCount }

func (d *ditNode) visualize(prefix, nodePrefix string) {
	if d.dn == "" {
		fmt.Printf("/ (%d suffixes, %d total entries)\n", len(d.nodes), d.descendantCount)
	} else {
		fmt.Printf("%s%s(%d,%d)\n", prefix, d.name_from_dn(), d.childCount, d.descendantCount)
	}
	for i, n := range d.nodes {
		if i+1 < len(d.nodes) {
			n.visualize(nodePrefix+"├── ", nodePrefix+"│   ")
		} else {
			n.visualize(nodePrefix+"└── ", nodePrefix+"    ")
		}
	}
}

func (d *ditNode) name_from_dn() string {
	if d.peid == "-1" {
		return d.dn
	} else {
		return strings.Split(d.dn, ",")[0]
	}
}
