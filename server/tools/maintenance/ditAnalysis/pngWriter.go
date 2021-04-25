// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
	"fmt"
	"github.com/wcharczuk/go-chart"
        "os"
	"strconv"
        "strings"
)

type pngConsumerWriter struct {
	filename    string
	chartValues []chart.Value
}

func (t *pngConsumerWriter) writeHeader() {
	fmt.Println("Directory Information Tree (DIT) Visualization")
	fmt.Println("----------------------------------------------")
}

func (t *pngConsumerWriter) writeRow(dn, count, min_mt, max_mt, min_ct, max_ct, eid, peid string) {
        dnComponents := strings.Split(dn, ",")
        rdn := dnComponents[0]
	value, err := strconv.ParseFloat(count, 64)
	if err != nil {
		fmt.Println("Unable to convert %s to a number\n", count)
		return
	}
	chartValue := chart.Value{
		Label: rdn,
		Value: value,
	}
	t.chartValues = append(t.chartValues, chartValue)
	return
}

func (t *pngConsumerWriter) writeTrailer() {
	pie := chart.PieChart{
		Width:  512,
		Height: 512,
		Values: t.chartValues,
	}

	f, _ := os.Create(t.filename)
	defer f.Close()
	pie.Render(chart.PNG, f)
}
