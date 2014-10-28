#!/bin/bash

## Collection of shared bpkg functions

## Init local config and set environmental defaults
bpkg_initrc() {
  local global_config=${BPKG_GLOBAL_CONFIG:-"/etc/bpkgrc"}
  [ -f "$global_config" ] && source "$global_config"
  local config=${BPKG_CONFIG:-"$HOME/.bpkgrc"}
  [ -f "$config" ] && source "$config"
  ## set defaults
  if [ ${#BPKG_REMOTES[@]} -eq 0 ]; then
    BPKG_REMOTES[0]=${BPKG_REMOTE-https://raw.githubusercontent.com}
    BPKG_GIT_REMOTES[0]=${BPKG_GIT_REMOTE-https://github.com}
  fi
  BPKG_USER="${BPKG_USER:-"bpkg"}"
  BPKG_INDEX=${BPKG_INDEX:-"$HOME/.bpkg/index"}
  BPKG_PREFIX=${BPKG_PREFIX:-"$HOME/.bpkg"}
}

## check parameter consistency
bpkg_validate () {
  if [ -z ${BPKG_GIT_REMOTES+is_set} ] && [ -z ${BPKG_REMOTES+is_set} ]; then
    bpkg_initrc
  fi
  if [ ${#BPKG_GIT_REMOTES[@]} -ne ${#BPKG_REMOTES[@]} ]; then
    mesg='BPKG_GIT_REMOTES[%d] differs in size from BPKG_REMOTES[%d] array'
    fmesg=$(printf "$mesg" "${#BPKG_GIT_REMOTES[@]}" "${#BPKG_REMOTES[@]}")
    error "$fmesg"
    return 1
  fi
  return 0
}

## format and output message
bpkg_message () {
  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term color "${1}"
  fi

  shift
  printf "    ${1}"
  shift

  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term reset
  fi

  printf ": "

  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term reset
    bpkg-term bright
  fi

  printf "%s\n" "${@}"

  if type -f bpkg-term > /dev/null 2>&1; then
    bpkg-term reset
  fi
}

## output error
bpkg_error () {
  {
    bpkg_message "red" "error" "${@}"
  } >&2
}

## output warning
bpkg_warn () {
  {
    bpkg_message "yellow" "warn" "${@}"
  } >&2
}

## output info
bpkg_info () {
  local title="info"
  if (( "${#}" > 1 )); then
    title="${1}"
    shift
  fi
  bpkg_message "cyan" "${title}" "${@}"
}

## Takes a remote and git-remote and sets global vars.
## 
## Globals Set:
##   BPKG_REMOTE: raw remote URI
##   BPKG_GIT_REMOTE: git remote for cloning
##   BPKG_AUTH_GIT_REMOTE: git remote with oauth info embedded,
##   BPKG_OAUTH_TOKEN: token for x-oauth-basic
##   BPKG_CURL_AUTH_PARAM: auth arguments for raw curl requests
##   BPKG_REMOTE_INDEX: location of local index for remote
bpkg_select_remote () {
  local remote="$1"
  local git_remote="$2"

  BPKG_REMOTE_HOST=$(echo -n "$git_remote" | sed 's/.*:\/\///' | sed 's/\/$//' | tr '/' '_')
  BPKG_REMOTE_INDEX="$BPKG_INDEX/$BPKG_REMOTE_HOST"
  BPKG_REMOTE_INDEX_FILE="$BPKG_REMOTE_INDEX/index.txt"
  BPKG_OAUTH_TOKEN=""
  BPKG_CURL_AUTH_PARAM=""
  BPKG_GIT_REMOTE=$git_remote
  BPKG_AUTH_GIT_REMOTE=$git_remote
  if [ "${remote:0:10}" == "raw-oauth|" ]; then
    OLDIFS="${IFS}"
    IFS="|"
    local remote_parts=($remote)
    IFS="${OLDIFS}"
    BPKG_OAUTH_TOKEN="${remote_parts[1]}"
    BPKG_CURL_AUTH_PARAM="-u $BPKG_OAUTH_TOKEN:x-oauth-basic"
    BPKG_REMOTE="${remote_parts[2]}"
    if [[ "$git_remote" == https://* ]] && [[ "$git_remote" != *x-oauth-basic* ]] && [[ "$git_remote" != *${BPKG_OAUTH_TOKEN}* ]]; then
      BPKG_AUTH_GIT_REMOTE=${git_remote/https:\/\//https:\/\/$BPKG_OAUTH_TOKEN:x-oauth-basic@}
    fi
  else
    BPKG_REMOTE="$remote"
  fi
}

## given a user and name, sets BPKG_RAW_PATH using the available
## BPKG_REMOTE and BPKG_OAUTH_TOKEN details
bpkg_select_raw_path () {
  local user=$1
  local name=$2
  if [ "$BPKG_OAUTH_TOKEN" == "" ]; then
    BPKG_RAW_PATH="${BPKG_REMOTE}/${user}/${name}"
  else
    BPKG_RAW_PATH="${BPKG_REMOTE}/${user}/${name}/raw"
  fi
  echo "RAW:$BPKG_RAW_PATH|"
  return 0
}

## Split output string into an array, using a newline as a separator
bpkg_lines_to_array() {
  local string="$1"
  local arrname="$2"

  bpkg_string_to_array "$string" $'\n' "$arrname"
  return 0
}

## Extract string into an array with a given field separator
## Args:
##   string:  The string to split
##   sep:     The field separator
##   arrname: Name of the array variable to write
bpkg_string_to_array() {
  local string="$1"
  local sep="$2"
  local arrname="$3"

  OLDIFS="$IFS"
  IFS="$sep"
  read -r -d '' -a $arrname <<< "$string" 2>/dev/null
  IFS="$OLDIFS"

  ## strip newline from end of last element of the array
  eval "local -i len=\"\${#$arrname[@]}\""
  local -i lastidx=$((len - 1))
  if ((lastidx > 0)); then
    eval "$arrname[$lastidx]=\$(echo \"\${$arrname[$lastidx]}\")"
  fi

  return 0
}

## Extract a single key-value from parsed json body.  Usage of parsed bodies is encouraged
## so that programs don't parse the same json string multiple times.
##
## Args:
##   parsed_json: Output of bpkg-json -b
##   key:         Key name
##   val:         Variable name which will hold the result value
bpkg_extract_json_value() {
  local parsed_json="$1"
  local key="$2"
  local val="$3"
  local result=$(echo "$parsed_json" | grep '\["'"$key"'"\]' | head -n 1 | awk '{ print $2 }' | tr -d '"')
  eval "$val=\"${result/"/\\"/}\""
}

## Extract an array of values from parsed json body.
## Args:
##   parsed_json: Output of bpkg-json -b
##   key:         Key name
##   arrname:     Array variable name
bpkg_extract_json_array() {
  local parsed_json="$1"
  local key="$2"
  local arrname="$3"
  local result=$(echo "$parsed_json" | grep '"'"$key"'"' | cut -f 2 | tr -d '"' )
  bpkg_lines_to_array "$result" "$arrname"
  return 0
}

## Extract a hash from parsed json body into key and value arrays
## Args:
##   parsed_json: Output of bpkg-json -b
##   key:         Key name
##   arr_key:     Variable name of array that will hold extracted keys
##   arr_val:     Variable name of array that will hold extracted values
bpkg_extract_json_hash () {
  local parsed_json="$1"
  local key="$2"
  local arr_key="$3"
  local arr_val="$4"
  local result=$(echo "$parsed_json" | grep '\["'$key'",' | awk -F '\t|,' '{ print $2 "::field_sep::" $3 }' | tr -d \"\[\])
  declare -a local lines=()
  bpkg_lines_to_array "$result" lines
  declare -i local i=0
  for line in "${lines[@]}"; do
    declare -a local fields
    bpkg_string_to_array "$line" '::field_sep::' fields
    eval "$arr_key[$i]=\"${fields[0]}\""
    eval "$arr_val[$i]=\"${fields[1]}\""
    i=$((i+1))
  done
  return 0
}

# Given a package and (opt) version, echo the full URI path
bpkg_raw_base_uri () {
  local pkg="$1"
  local version="${2:-master}"
  local uri=""
  if [ "$BPKG_OAUTH_TOKEN" == "" ]; then
    uri=$BPKG_REMOTE/$pkg/$version
  else
    uri=$BPKG_REMOTE/$pkg/$version/raw
  fi
  echo "$uri"
  return 0
}

## Given a package ("user/name") and filepath, echo the content of the file as fetched from the raw remote path
##
## Args:
##   pkg:       The package name, in user/name format
##   path:      The path to the file
##   [version]: Tagged version, master by default
##   [output_file]: Write output to file instead of stdout
##
## Return:
##    0:  success
##    1:  the http code is non-ok
##    >1: some other error occurred
##
## Globals Set:
##   BPKG_GET_FILE_ERROR: empty string if no error, or error message if one occurs
bpkg_get_file () {
  local pkg=$1
  local path=$2
  local version="${3:-master}"
  local output_file="$4"

  local uri=$(bpkg_raw_base_uri "$pkg" "$version")
  local full_uri="$uri/$path?`date +%s`"
  local tmpbase="/tmp"
  if [ ! -w "$tmpbase" ]; then
    tmpbase="$HOME/.tmp"
    mkdir -p "$tmpbase"
    if [ ! -w "$tmpbase" ]; then
      BPKG_GET_FILE_ERROR="tmp dir not writable: $tmpbase"
      return 2
    fi
  fi
  local tmp="/tmp/bpkg-get-file.$$.$RANDOM.tmp"

  local cmd="curl -sL"
  if [ "$BPKG_OAUTH_TOKEN" != "" ]; then
    local method='x-oauth-basic'
    cmd="$cmd -u $BPKG_OAUTH_TOKEN:x-oauth-basic"
  fi
  cmd="$cmd -o $tmp -w '%{http_code}'"
  cmd="$cmd '$full_uri'"
  BPKG_GET_FILE_ERROR=""
  echo "GET $full_uri" 1>&2
  declare -i local http_code=$(eval "$cmd" 2>/dev/null)
  if (( $http_code >= 200 )) && (( $http_code < 300 )); then
    if [ -n "$output_file" ]; then
      mv -f "$tmp" "$output_file"
    else
      cat $tmp
      rm -f $tmp &>/dev/null
    fi
    return 0
  else
    rm -f $tmp &>/dev/null
    BPKG_GET_FILE_ERROR="HTTP $http_code"
    return 1
  fi
}

## Given JSON string, parses fields into global vars
##
## Args:
##   json - JSON string
##
## Globals Set:
##  BPKG_PKG_NEEDS_GLOBAL: set to 1 if package must be installed globally
##  BPKG_PKG_SCRIPTS: array of script sources
##  BPKG_PKG_BIN_SRCS: array of bin srcs
##  BPKG_PKG_BIN_DESTS: array of bin destination corresponding to srcs
##  BPKG_PKG_INSTALL: installation script
##  BPKG_PKG_NAME: package name
##  BPKG_PKG_VERSION: package version
##  BPKG_PKG_AUTHOR: package author
##  BPKG_PKG_DESCRIPTION : package description
bpkg_parse_package_json () {
  local json=$1
  local parsed_json=$(echo -n "$json" | bpkg-json -b)

  # Determine if global install is required
  BPKG_PKG_NEEDS_GLOBAL=0
  if [ ! -z $(echo -n "$parsed_json" | grep '\["global"\]' | awk '{ print $2 }' | tr -d '"') ]; then
    BPKG_PKG_NEEDS_GLOBAL=1
  fi
  BPKG_PKG_SCRIPTS=()
  BPKG_PKG_BIN_SRCS=()
  BPKG_PKG_BIN_DESTS=()

  bpkg_extract_json_array "$parsed_json" scripts BPKG_PKG_SCRIPTS

  bpkg_extract_json_hash "$parsed_json" bin BPKG_PKG_BIN_DESTS BPKG_PKG_BIN_SRCS
  if [ ${#BPKG_PKG_SCRIPTS[@]} -gt 0 ] && [ ${#BPKG_PKG_BIN_SRCS[@]} -gt 0 ]; then
    bpkg_warn "scripts set, but \"bin\" spec will override scripts"
    BPKG_PKG_SCRIPTS=$BPKG_PKG_BIN_SRCS
  fi

  bpkg_extract_json_value "$parsed_json" 'install' BPKG_PKG_INSTALL
  bpkg_extract_json_value "$parsed_json" name BPKG_PKG_NAME
  bpkg_extract_json_value "$parsed_json" version BPKG_PKG_VERSION
  bpkg_extract_json_value "$parsed_json" author BPKG_PKG_AUTHOR
  bpkg_extract_json_value "$parsed_json" license BPKG_PKG_LICENSE
  bpkg_extract_json_value "$parsed_json" description BPKG_PKG_DESCRIPTION

  return 0
}

export -f bpkg_initrc
export -f bpkg_validate

export -f bpkg_message
export -f bpkg_warn
export -f bpkg_error
export -f bpkg_info

export -f bpkg_select_remote
export -f bpkg_select_raw_path

export -f bpkg_extract_json_value
export -f bpkg_extract_json_array
export -f bpkg_extract_json_hash

export -f bpkg_get_file
export -f bpkg_parse_package_json
