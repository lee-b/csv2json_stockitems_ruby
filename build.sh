#!/bin/bash

if [ "$GOPATH" != "$(readlink -f $(dirname '$0'))" ]; then
    echo "ERROR: GOPATH is set to '$GOPATH', rather than this project's directory.  Dir you source profile.sh?"
    exit 20
fi

go test lbgotest.com/lb/stockdatalib
go install lbgotest.com/lb/stockdatalib
go install lbgotest.com/lb/csv2json

