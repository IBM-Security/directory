# IBM Security Directory

## Miscellaneous tools
ldif2csv - this script is currently only in python format. It is best used using python3. 
The decode option may have issues when used in python2.

This script is meant to convert any valid LDIF file into a corresponding CSV format. If you choose to create a CSV with a header - then the script parses the entire LDIF file into memory and assesses all the potential attributes for headers and then writes out a CSV file.
This is expected to be memory intensive for very large files.
