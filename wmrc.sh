#!/bin/sh

WMRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export WMRC_DIR

_module='wmrc'
. "$WMRC_DIR/libwmrc.sh"

module_exec() {
    check_dependencies "$1"
    eval "call $*"
}

module_list() {
    debug 'List modules'
    debug 'Test module directory' "$WMRC_CONFIG/modules"
    if ! test -d "$WMRC_CONFIG/modules"; then
        error "Modules directory not found: $WMRC_CONFIG/modules"
        exit 1
    fi
    modules="$(find "$WMRC_CONFIG/modules" -type f -executable -printf '%P\n' | grep 'test/')"
    debug 'Found modules' "$(echo "$modules" | sed -z 's/\n/, /g;s/, $/\n/')"
}

get_dependencies() {
    if [ -z "$1" ]; then
        debug 'Get all dependencies'
        module_list
    else
        debug 'Get dependencies for' "$1"
        modules="$1"
    fi
    dependencies=""
    for m in $modules; do
        dependencies="$dependencies${dependencies:+:}$(call "$m" 'echo $WMRC_DEPENDENCIES' | sed 's/ \{1,\}/:/g')"
    done
    debug 'Found dependencies' "$(echo "$dependencies" | sed 's|:|, |g')"
    dependencies="$(echo "$dependencies" | sed 's|:|\n|g' | sort | uniq)"
}

check_dependencies() {
    debug 'Check dependencies'
    get_dependencies "$1" || return 1
    _missing=""
    for d in $dependencies; do
        if ! command -v "$d" 1>/dev/null; then
            _missing="$_missing${_missing:+, }$d"
        fi
    done
    if [ -n "$_missing" ]; then
        error 'Missing dependencies' "$_missing"
        exit 1
    fi
}

read_config_variables() {
    debug 'Read configuration variables'
    debug 'Test configuration file' "$WMRC_CONFIG/rc.conf"
    if ! test -f "$WMRC_CONFIG/rc.conf"; then
        error 'Configuration file not found' "$WMRC_CONFIG/rc.conf"
        exit 1
    fi
    _vars="$(
        awk 'match($0, /^%(\w+) *= *(.*)$/, line) {
            printf("export WMRC_%s=\"%s\"\n",line[1],line[2]);
        }' "$WMRC_CONFIG/rc.conf"
    )"
    debug 'Load variables'
    eval "$_vars"

}

config_unit_list() {
    debug 'Test configuration file' "$WMRC_CONFIG/rc.conf"
    if ! test -f "$WMRC_CONFIG/rc.conf"; then
        error 'Configuration file not found' "$WMRC_CONFIG/rc.conf"
        exit 1
    fi
    units="$(awk 'match($0, /^\[(\w+)\]$/, line) {
        print line[1];
    }' "$WMRC_CONFIG/rc.conf")"
}

run_config_unit() {
    debug 'Test configuration file' "$WMRC_CONFIG/rc.conf"
    if ! test -f "$WMRC_CONFIG/rc.conf"; then
        error 'Configuration file not found' "$WMRC_CONFIG/rc.conf"
        exit 1
    fi
    if [ -z "$1" ]; then
        error 'Unit name not provided'
        exit 1
    fi
    if ! grep -q "\[$1\]" "$WMRC_CONFIG/rc.conf"; then
        error 'Configuration unit not found' "$1"
        exit 1
    fi
    _unit="$(
        awk -v target="$1" \
        'match($0, /^\[(\w+)\]$/, line) {
            section=line[1];
        }
        match($0, /^%.*$/) {
            section="";
        }
        match($0, /^(\w+\/\w+)(::)?(\w+)?(\((.+)\))?/, line) {
            if (section == target) {
                module=line[1]
                method=line[3] ? line[3] : "init"
                args=line[5]
                printf("module_exec \"%s\" \"%s\" %s\n", module, method, args);
            }
        }
    ' "$WMRC_CONFIG/rc.conf")"
    debug 'Execute unit'
    eval "$_unit"
}

run_method() {
    if [ -z "$1" ]; then
        error 'Module name not provided'
        exit 1
    fi
    _callee="$1"
    if [ -z "$2" ]; then
        _method="init"
        shift 1
    else
        _method="$2"
        shift 2
    fi
    _args="$*"
    info 'Executing method' "$_callee::$_method($_args)"
    eval "module_exec $_callee $_method $_args"
}

case "$1" in
    "")
        error 'No command specified'
        ;;
    "-v"|"--version"|"version")
        echo 'wmrc 2.0.0'
        ;;
    "-h"|"--help"|"help")
        printf 'wmrc 2.0.0\nFilip Parag <filip@parag.rs>\n\nCommands:\n'
        printf '\tcall <group>/<module> <method> [args...]\n'
        printf '\tunit <unit>\n'
        printf '\tunits\n'
        printf '\tmodules\n'
        printf '\tdeps\n'
        printf '\tcheck-deps\n'
        printf '\thelp\n'
        printf '\tversion\n'
        ;;
    "call")
        shift 1
        eval "run_method $*"
        ;;
    "unit")
        shift 1
        eval "run_config_unit $1"
        ;;
    "units")
        config_unit_list
        echo "$units"
        ;;
    "modules")
        module_list
        echo "$modules"
        ;;
    "deps")
        get_dependencies
        echo "$dependencies"
        ;;
    "check-deps")
        check_dependencies
        ;;
    *)
        error 'Unknown command'
        ;;
esac

