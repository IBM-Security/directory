# Python Setup

Note: python2 is end-of-life. The provided code scripts have successfully worked in python2. There are no plans
to develop for it or run extensive tests.

* Using the python scripts requires ibm_db python package to be installed. Like so (if you face issues follow suggestions below and retry):

`pip install ibm_db`

* If there is no existing DB2 Driver detected then `pip install ibm_db` will attempt a [minimal DB2 driver](https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/linuxx64_odbc_cli.tar.gz) install.

* There are [other DB2 drivers](https://www.ibm.com/support/pages/db2-odbc-cli-driver-download-and-installation-information) that can be installed ahead of the python ibm_db package in case the driver that is installed by it is not desirable or having issues.

* Make sure you are using the latest pip version - upgrade if needed like so:

`python3 -m pip install --upgrade pip`
  
* Install python development package if you get compile errors and python.h is not found - like so:

`yum install python3-dev`

or

`yum install python3-devel`
  