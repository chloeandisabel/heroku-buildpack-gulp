error() {
  echo " !     $*" >&2
  echo ""
  return 1
}

head() {
  echo ""
  echo "-----> $*"
}

info() {
  #echo "`date +\"%M:%S\"`  $*"
  echo "       $*"
}

file_contents() {
  if test -f $1; then
    echo "$(cat $1)"
  else
    echo ""
  fi
}

assert_json() {
  local file=$1
  if test -f $file; then
    if ! cat $file | $bp_dir/vendor/jq '.' > /dev/null; then
      error "Unable to parse $file as JSON"
    fi
  fi
}

read_json() {
  local file=$1
  local node=$2
  if test -f $file; then
    cat $file | $bp_dir/vendor/jq --raw-output "$node // \"\"" || return 1
  else
    echo ""
  fi
}

get_modules_source() {
  local build_dir=$1
  if test -d $build_dir/node_modules; then
    echo "prebuilt"
  elif test -f $build_dir/npm-shrinkwrap.json; then
    echo "npm-shrinkwrap.json"
  elif test -f $build_dir/package.json; then
    echo "package.json"
  else
    echo ""
  fi
}

get_modules_cached() {
  local cache_dir=$1
  if test -d $cache_dir/node/node_modules; then
    echo "true"
  else
    echo "false"
  fi
}

read_current_state() {
  info "package.json..."
  assert_json "$build_dir/package.json"
  iojs_engine=$(read_json "$build_dir/package.json" ".engines.iojs")
  node_engine=$(read_json "$build_dir/package.json" ".engines.node")
  npm_engine=$(read_json "$build_dir/package.json" ".engines.npm")

  info "build directory..."
  modules_source=$(get_modules_source "$build_dir")

  info "cache directory..."
  npm_previous=$(file_contents "$cache_dir/node/npm-version")
  node_previous=$(file_contents "$cache_dir/node/node-version")
  modules_cached=$(get_modules_cached "$cache_dir")

  info "environment variables..."
  export_env_dir $env_dir
  export NPM_CONFIG_PRODUCTION=${NPM_CONFIG_PRODUCTION:-true}
  export NODE_MODULES_CACHE=${NODE_MODULES_CACHE:-true}
}

show_current_state() {
  echo ""
  if [ "$iojs_engine" == "" ]; then
    info "Node engine:         ${node_engine:-unspecified}"
  else
    achievement "iojs"
    info "Node engine:         $iojs_engine (iojs)"
  fi
  info "Npm engine:          ${npm_engine:-unspecified}"
  info "node_modules source: ${modules_source:-none}"
  info "node_modules cached: $modules_cached"
  echo ""

  printenv | grep ^NPM_CONFIG_ | indent
  info "NODE_MODULES_CACHE=$NODE_MODULES_CACHE"
}

install_node() {
  local node_engine=$1

  # Resolve non-specific node versions using semver.herokuapp.com
  if ! [[ "$node_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "Resolving node version ${node_engine:-(latest stable)} via semver.io..."
    node_engine=$(curl --silent --get --data-urlencode "range=${node_engine}" https://semver.herokuapp.com/node/resolve)
  fi

  # Download node from Heroku's S3 mirror of nodejs.org/dist
  info "Downloading and installing node $node_engine..."
  node_url="http://s3pository.heroku.com/node/v$node_engine/node-v$node_engine-linux-x64.tar.gz"
  curl $node_url -s -o - | tar xzf - -C /tmp

  # Move node (and npm) into .heroku/node and make them executable
  mv /tmp/node-v$node_engine-linux-x64/* $heroku_dir/node
  chmod +x $heroku_dir/node/bin/*
  PATH=$heroku_dir/node/bin:$PATH
}

install_iojs() {
  local iojs_engine=$1

  # Resolve non-specific iojs versions using semver.herokuapp.com
  if ! [[ "$iojs_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    info "Resolving iojs version ${iojs_engine:-(latest stable)} via semver.io..."
    iojs_engine=$(curl --silent --get --data-urlencode "range=${iojs_engine}" https://semver.herokuapp.com/iojs/resolve)
  fi

  # TODO: point at /dist once that's available
  info "Downloading and installing iojs $iojs_engine..."
  download_url="https://iojs.org/dist/v$iojs_engine/iojs-v$iojs_engine-linux-x64.tar.gz"
  curl $download_url -s -o - | tar xzf - -C /tmp

  # Move iojs/node (and npm) binaries into .heroku/node and make them executable
  mv /tmp/iojs-v$iojs_engine-linux-x64/* $heroku_dir/node
  chmod +x $heroku_dir/node/bin/*
  PATH=$heroku_dir/node/bin:$PATH
}

install_npm() {
  # Optionally bootstrap a different npm version
  if [ "$npm_engine" != "" ]; then
    if ! [[ "$npm_engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      info "Resolving npm version ${npm_engine} via semver.io..."
      npm_engine=$(curl --silent --get --data-urlencode "range=${npm_engine}" https://semver.herokuapp.com/npm/resolve)
    fi
    if [[ `npm --version` == "$npm_engine" ]]; then
      info "npm `npm --version` already installed with node"
    else
      info "Downloading and installing npm $npm_engine (replacing version `npm --version`)..."
      npm install --quiet -g npm@$npm_engine 2>&1 >/dev/null | indent
    fi
    warn_old_npm `npm --version`
  else
    info "Using default npm version: `npm --version`"
  fi
}

function build_dependencies() {
  if [ "$modules_source" == "" ]; then
    info "Skipping dependencies (no source for node_modules)"

  elif [ "$modules_source" == "prebuilt" ]; then
    info "Rebuilding any native modules for this architecture"
    npm rebuild 2>&1 | indent
    info "Installing any new modules"
    npm install --dev --quiet --userconfig $build_dir/.npmrc 2>&1 | indent

  else
    cache_status=$(get_cache_status)

    if [ "$cache_status" == "valid" ]; then
      info "Restoring node modules from cache"
      cp -r $cache_dir/node/node_modules $build_dir/
      info "Pruning unused dependencies"
      npm prune 2>&1 | indent
      info "Installing any new modules"
      npm install --dev --quiet --userconfig $build_dir/.npmrc 2>&1 | indent
    else
      info "$cache_status"
      info "Installing node modules"
      touch $build_dir/.npmrc
      npm install --dev --quiet --userconfig $build_dir/.npmrc 2>&1 | indent
    fi
  fi
}

clean_npm() {
  info "Cleaning npm artifacts"
  rm -rf "$build_dir/.node-gyp"
  rm -rf "$build_dir/.npm"
}

# Caching

create_cache() {
  info "Caching results for future builds"
  mkdir -p $cache_dir/node

  echo `node --version` > $cache_dir/node/node-version
  echo `npm --version` > $cache_dir/node/npm-version

  if test -d $build_dir/node_modules; then
    cp -r $build_dir/node_modules $cache_dir/node
  fi
}

clean_cache() {
  info "Cleaning previous cache"
  rm -rf "$cache_dir/node_modules" # (for apps still on the older caching strategy)
  rm -rf "$cache_dir/node"
}

get_cache_status() {
  local node_version=`node --version`
  local npm_version=`npm --version`

  # Did we bust the cache?
  if ! $modules_cached; then
    echo "No cache available"
  elif ! $NODE_MODULES_CACHE; then
    echo "Cache disabled with NODE_MODULES_CACHE"
  elif [ "$node_previous" != "" ] && [ "$node_version" != "$node_previous" ]; then
    echo "Node version changed ($node_previous => $node_version); invalidating cache"
  elif [ "$npm_previous" != "" ] && [ "$npm_version" != "$npm_previous" ]; then
    echo "Npm version changed ($npm_previous => $npm_version); invalidating cache"
  else
    echo "valid"
  fi
}

export_env_dir() {
  env_dir=$1
  if [ -d "$env_dir" ]; then
    whitelist_regex=${2:-''}
    blacklist_regex=${3:-'^(PATH|GIT_DIR|CPATH|CPPATH|LD_PRELOAD|LIBRARY_PATH)$'}
    if [ -d "$env_dir" ]; then
      for e in $(ls $env_dir); do
        echo "$e" | grep -E "$whitelist_regex" | grep -qvE "$blacklist_regex" &&
        export "$e=$(cat $env_dir/$e)"
        :
      done
    fi
  fi
}

# sed -l basically makes sed replace and buffer through stdin to stdout
# so you get updates while the command runs and dont wait for the end
# e.g. npm install | indent
indent() {
  c='s/^/       /'
  case $(uname) in
    Darwin) sed -l "$c";; # mac/bsd sed: -l buffers on line boundaries
    *)      sed -u "$c";; # unix/gnu sed: -u unbuffered (arbitrary) chunks of data
  esac
}
