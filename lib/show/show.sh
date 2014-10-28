#!/bin/bash

VERSION="0.0.1"

if ! type -f bpkg-utils &>/dev/null; then
  echo "error: bpkg-utils not found, aborting"
  exit 1
else
  source `which bpkg-utils`
fi

bpkg_initrc

usage () {
  mesg=$1
  if [ "$mesg" != "" ]; then
    echo "$mesg"
    echo
  fi
  echo "bpkg-show [-Vh]"
  echo "bpkg-show <user/package_name>"
  echo "bpkg-show readme <user/package_name>"
  echo "bpkg-show sources <user/package_name>"
  echo
  echo "Show bash package details.  You must first run \`bpkg update' to sync the repo locally."
  echo
  echo "Commands:"
  echo "  readme        Print package README.md file, if available, suppressing other output"
  echo "  sources       Print all sources listed in package.json scripts, in order. This"
  echo "                option suppresses other output and prints executable bash."
  echo
  echo "Options:"
  echo "  --help|-h     Print this help dialogue"
  echo "  --version|-V  Print version and exit"
}

show_package () {
  local pkg=$1
  local show_readme=$2
  local show_sources=$3

  local git_remote=$BPKG_GIT_REMOTE

  local json=$(bpkg_get_file "$pkg" package.json)

  local readme=$(bpkg_get_file "$pkg" README.md)

  local readme_len=$(echo "$readme" | wc -l | tr -d ' ')

  bpkg_parse_package_json "$json"

  if [ "$show_sources" == '0' ] && [ "$show_readme" == "0" ]; then
    echo "Name: $pkg"
    if [ "$BPKG_PKG_AUTHOR" != "" ]; then
      echo "Author: $BPKG_PKG_AUTHOR"
    fi
    echo "Description: $BPKG_PKG_DESCRIPTION"
    echo "Current Version: $BPKG_PKG_VERSION"
    echo "Remote: $git_remote"
    if [ "$BPKG_PKG_INSTALL" != "" ]; then
      echo "Install: $BPKG_BPKG_INSTALL"
    fi
    if [ $readme_len -eq 0 ]; then
      echo "README.md: Not Available"
    else
      echo "README.md: ${readme_len} lines"
    fi
  elif [ "$show_readme" != '0' ]; then
    echo "$readme"
  else
    # Show Sources
    echo "json: $json"
    echo "scripts: ${BPKG_PKG_SCRIPTS[@]}"
    for src in "${BPKG_PKG_SCRIPTS[@]}"; do
      echo "SOURCE: $src"
      local content=$(bpkg_get_file "$pkg" "$src")
      if [ "$BPKG_GET_FILE_ERROR" == "" ]; then
        echo "#[$src]"
        echo "$content"
        echo "#[/$src]"
      else
        bpkg_warn "source not found [$BPKG_GET_FILE_ERROR]"
      fi
    done
  fi
}


bpkg_show () {
  declare -i local readme=0
  declare -i local sources=0
  local pkg=""
  for opt in "${@}"; do
    case "$opt" in
      -V|--version)
        echo "${VERSION}"
        return 0
        ;;
      -h|--help)
        usage
        return 0
        ;;
      readme)
        readme=1
        if [ "$sources" == "1" ]; then
          usage "Error: readme and sources are mutually exclusive options"
          return 1
        fi
        ;;
      source|sources)
        sources=1
        if [ "$readme" == "1" ]; then
          usage "Error: readme and sources are mutually exclusive options"
          return 1
        fi
        ;;
      *)
        if [ "${opt:0:1}" == "-" ]; then
          bpkg_error "unknown option: $opt"
          return 1
        fi
        if [ "$pkg" == "" ]; then
          pkg=$opt
        fi
    esac
  done

  if [ "$pkg" == "" ]; then
    usage
    return 1
  fi

  declare -i local i=0
  for remote in "${BPKG_REMOTES[@]}"; do
    local git_remote="${BPKG_GIT_REMOTES[$i]}"
    bpkg_select_remote "$remote" "$git_remote"
    if [ ! -f "$BPKG_REMOTE_INDEX_FILE" ]; then
      bpkg_warn "no index file found for remote: ${remote}"
      bpkg_warn "You should run \`bpkg update' before running this command."
      i=$((i+1))
      continue
    fi

    declare -a local lines=()
    bpkg_lines_to_array "$(cat $BPKG_REMOTE_INDEX_FILE)" lines
    for line in "${lines[@]}"; do
      local name=$(echo "$line" | cut -d\| -f1 | tr -d ' ')
      if [ "$name" == "$BPKG_USER/$pkg" ]; then
        pkg="$BPKG_USER/$pkg"
      fi
      if [ "$name" == "$pkg" ]; then
        show_package "$pkg" "$readme" "$sources"
        return 0
      fi
    done

    i=$((i+1))
  done

  bpkg_error "package not found: $pkg"
  return 1
}

if [[ ${BASH_SOURCE[0]} != $0 ]]; then
  export -f bpkg_show
elif bpkg_validate; then
  bpkg_show "${@}"
fi
