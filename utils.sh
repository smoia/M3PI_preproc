#!/usr/bin/env bash

version() {
	tag=$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; git describe --tags --always)
	echo "M3PI_vessels version ${tag}"
	echo ""
}

# Check input
checkreqvar() {
	reqvar=( "$@" )

	for var in "${reqvar[@]}"
	do
		if [[ -z ${!var+x} ]]
		then
			echo "${var} is unset, exiting program" && exit 1
		else
			echo "${var} is set to ${!var}"
		fi
	done
}

checkoptvar() {
	optvar=( "$@" )

	for var in "${optvar[@]}"
	do
		echo "${var} is set to ${!var}"
	done
}

removeniisfx() {
	echo ${1%.nii*}
}

if_missing_do() {
case $1 in
	mkdir )
		if [ ! -d $2 ]
		then
			echo "Create folder(s)" "${@:2}"
			mkdir -p "${@:2}"
		fi
		;;
	stop )
		if [ ! -e $2 ]
		then
			echo "$2 not found"
			exit 1
		fi
		;;
	* )
		if [ ! -e $3 ]
		then
			printf "%s is missing, " "$3"
			case $1 in
				copy ) echo "copying $2";		cp $2 $3 ;;
				move ) echo "moving $2";		mv $2 $3 ;;
				mask ) echo "binarising $2";	fslmaths $2 -bin $3 ;;
				* ) echo "and you shouldn't see this"; exit 2;;
			esac
		fi
		;;
esac
}

replace_and() {
case $1 in
	mkdir) if [ -d $2 ]; then echo "$2 exists already, removing first"; rm -rf $2; fi; mkdir -p "${@:2}" ;;
	touch) if [ -d $2 ]; then echo "$2 exists already, removing first"; rm -rf $2; fi; touch $2 ;;
	* ) echo "This is wrong"; exit 2;;
esac
}

parse_filename_from_json() {
	local bidslabels="task acq ce rec dir run mod echo part chunk recording suffix"
	if [[ -f ${2} ]]
	then
		if [[ $(jq .${1} ${2}) != "null" ]];
		then
			local bidsinfo=''
			local key
			for key in ${bidslabels};
			do
				local value
				value=$(jq -r .${1}.${key} ${2})
				[[ ${value} != "null" ]] && bidsinfo="${bidsinfo}_${key}-${value}"
			done
			echo "${bidsinfo}"
		else
			echo "none"
		fi
	else
		exit 1
	fi
}


# Copyright 2025, Stefano Moia

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
