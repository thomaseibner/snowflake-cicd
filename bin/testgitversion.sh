#!/bin/bash

if [ `git --version | awk '{ print $3 }' | sed -e 's/\.[0-9]$//' | sed -e 's/\.//g'` -gt 228 ] 
	then
		echo "git version is larger than 2.28"
	else
		exit -1
fi
