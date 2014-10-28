#!/bin/bash

if ! type -f bpkg-utils; then
  echo "bpkg-utils not found, aborting"
  exit 1
fi
source `which bpkg-utils`

bpkg_initrc

## outut usage
usage () {
  echo "usage: bpkg-install [-h|--help]"
  echo "   or: bpkg-install [-g|--global] <package>"
  echo "   or: bpkg-install [-g|--global] <user>/<package>"
}

## Install a bash package
bpkg_install () {
  local pkg=""
  local let needs_global=0
  declare -a args=( "${@}" )

  for opt in "${@}"; do
    if [ "-" = "${opt:0:1}" ]; then
      continue
    fi
    pkg="${opt}"
    break
  done

  for opt in "${@}"; do
    case "${opt}" in
      -h|--help)
        usage
        return 0
        ;;

      -g|--global)
        shift
        needs_global=1
        ;;

      *)
        if [ "-" = "${opt:0:1}" ]; then
          echo 2>&1 "error: Unknown argument \`${1}'"
          usage
          return 1
        fi
        ;;
    esac
  done

  ## ensure there is a package to install
  if [ -z "${pkg}" ]; then
    usage
    return 1
  fi

  echo

  ## Check each remote in order
  local let i=0
  for remote in "${BPKG_REMOTES[@]}"; do
    local git_remote=${BPKG_GIT_REMOTES[$i]}
    bpkg_install_from_remote "$pkg" "$remote" "$git_remote" $needs_global
    if [ "$?" == "0" ]; then
      return 0
    elif [ "$?" == "2" ]; then
      bpkg_error "fatal error occurred during install"
      return 1
    fi
    i=$((i+1))
  done
  bpkg_error "package not found on any remote"
  return 1
}

## try to install a package from a specific remote
## returns values:
##   0: success
##   1: the package was not found on the remote
##   2: a fatal error occurred
bpkg_install_from_remote () {
  local pkg="$1"
  local remote="$2"
  local git_remote="$3"
  local let needs_global=$4

  bpkg_select_remote "$remote" "$git_remote"

  local cwd=$(pwd)
  local url=""
  local uri=""
  local version=""
  local user=""
  local name=""
  local version=""
  local json=""
  local let has_pkg_json=1
  declare -a local pkg_parts=()
  declare -a local scripts=()

  ## get version if available
  bpkg_string_to_array "$pkg" @ pkg_parts

  if [ ${#pkg_parts[@]} -eq 1 ]; then
    version="master"
  elif [ ${#pkg_parts[@]} -eq 2 ]; then
    name="${pkg_parts[0]}"
    version="${pkg_parts[1]}"
  else
     bpkg_error "Error parsing package version"
    return 1
  fi

  bpkg_string_to_array "$pkg" '/' pkg_parts

  if [ ${#pkg_parts[@]} -eq 1 ]; then
    user="${BPKG_USER}"
    name="${pkg_parts[0]}"
  elif [ ${#pkg_parts[@]} -eq 2 ]; then
    user="${pkg_parts[0]}"
    name="${pkg_parts[1]}"
  else
    bpkg_error "Unable to determine package name"
    return 1
  fi

  ## clean up name of weird trailing
  ## versions and slashes
  name=${name/@*//}
  name=${name////}


  bpkg_select_raw_path "$user" "$name"

  url="$BPKG_RAW_PATH"

  bpkg_info "Install $url from remote $remote [$git_remote]"

  ## Ensure remote is reachable
  ## If a remote is totally down, this will be considered a fatal
  ## error since the user may have intended to install the package
  ## from the broken remote.
  {
    bpkg_get_file "$user/$name" "README.md" master >/dev/null
    if [ -n "$BPKG_GET_FILE_ERROR" ]; then
      bpkg_get_file "$user/$name" "package.json" master >/dev/null
      if [ -n "$BPKG_GET_FILE_ERROR" ]; then
        echo "$BPKG_GET_FILE_ERROR"
        bpkg_error "Remote unreachable: $remote"
        return 2
      fi
    fi
  }

  ## build url
  repo_url=$git_remote/$user/$name.git

  ## determine if `package.json' exists at url
  {
    json=$(bpkg_get_file "$user/$name" 'package.json' "$version")
    if [ -n "$BPKG_GET_FILE_ERROR" ]; then
      bpkg_warn "package.json doesn't exist"
      has_pkg_json=0
      # check to see if there's a Makefile. If not, this is not a valid package
      makefile=$(bpkg_get_file "$user/$name" 'Makefile' "$version")
      if [ -n "$BPKG_GET_FILE_ERROR" ]; then
        bpkg_warn "Makefile not found, skipping remote: $url"
        return 1
      fi
    fi

  }

  ## read package.json
  if (( 1 == $has_pkg_json )); then
    if [ -z "$json" ]; then
      bpkg_error "fatal" "package.json empty"
      return 2
    fi
    bpkg_parse_package_json "$json"
    if [ "$BPKG_PKG_NEEDS_GLOBAL" == "1" ]; then
      needs_global=1
    fi
    scripts=$BPKG_PKG_SCRIPTS
  fi

  ## build global if needed
  if (( 1 == $needs_global )); then

    if [ -z "${BPKG_PKG_INSTALL}" ] && [ ${#BPKG_PKG_BIN_SRCS[@]} -eq 0 ]; then
      bpkg_warn "Missing build script"
      bpkg_warn "Will attempt \`make install'..."
      BPKG_INSTALL="make install"
    fi

    {(
      # If bins not defined, git clone and make install
      if [ ${#BPKG_PKG_BIN_SRCS[@]} -eq 0 ]; then
        ## go to tmp dir
        cd $( [ ! -z $TMPDIR ] && echo $TMPDIR || echo /tmp) &&
          ## prune existing
        rm -rf ${name}-${version} &&
          ## shallow clone
        bpkg_info "Cloning $repo_url to $name-$version"
        git clone $repo_url ${name}-${version} &&
          (
        ## move into directory
        cd ${name}-${version} &&
          ## build
        bpkg_info "PREFIX=$PREFIX"
        bpkg_info "Performing install: \`${BPKG_INSTALL}'"
        build_output=$(eval "${BPKG_INSTALL}")
        echo "$build_output"
        ) &&
          ## clean up
        rm -rf ${name}-${version}
      else
        for (( i = 0; i < ${#BPKG_PKG_BIN_SRCS[@]} ; ++i )); do
          local bin_name="$(echo ${BPKG_PKG_BIN_SRCS[$i]} | xargs basename)"
          mkdir -p "${BPKG_PREFIX}/bin"
          local dest_path="${BPKG_PREFIX}/bin/${BPKG_PKG_BIN_DESTS[$i]}"
          bpkg_info "install" "${url}/${bin_name} -> $dest_path"
          bpkg_get_file "$user/$name" "$bin_name" "$version" "$dest_path"
          chmod 0755 "$dest_path"
        done
      fi
    )}
  elif [ "${#scripts[@]}" -gt "0" ]; then

    ## make `deps/' directory if possible
    mkdir -p "${cwd}/deps/${name}"

    ## copy package.json over
    bpkg_get_file "$user/$name" 'package.json' "$version" "${cwd}/deps/$BPKG_PKG_NAME/package.json"
    ## grab each script and place in deps directory
    for (( i = 0; i < ${#scripts[@]} ; ++i )); do
      (
        local script="$(echo ${scripts[$i]} | xargs basename )"
        bpkg_info "fetch" "${url}/${script}"
        bpkg_info "write" "${cwd}/deps/${BPKG_PKG_NAME}/${script}"
        bpkg_get_file "$user/$name" "${script}" "$version" -o "${cwd}/deps/${BPKG_PKG_NAME}/${script}"
      )
    done
  fi

  return 0
}

## Use as lib or perform install
if [[ ${BASH_SOURCE[0]} != $0 ]]; then
  export -f bpkg_install
elif bpkg_validate; then
  bpkg_install "${@}"
  exit $?
else
  #param validation failed
  exit $?
fi
