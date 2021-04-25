// dit_analysis calculates the statistics at each level of the directory information tree
package main

import (
	"fmt"
)

var programName = "ditAnalysis"

func main() {

	configInfo := getArguments(programName)
	err := ditAnalysis(configInfo)
	if err != nil {
		fmt.Println(err)
	}
}

