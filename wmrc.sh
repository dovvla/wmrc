#!/bin/sh

WMRC_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export WMRC_DIR

_module='wmrc'
. "$WMRC_DIR/libwmrc.sh"

test_config_file() {
    debug 'Test configuration file' "$WMRC_CONFIG/rc.conf"
    if ! test -f "$WMRC_CONFIG/rc.conf"; then
        error 'Configuration file not found' "$WMRC_CONFIG/rc.conf"
        exit 1
    fi
}

module_exec() {
    if [ "$WMRC_CHECK_DEPS" != 'false' ]; then
        check_dependencies "$1"
    fi
    
    eval "call $*"

    debug 'Notifying subscribers module executed:' "$1"
    eval "publish_event $1"
}

publish_event() {
    _modules="$(find "$WMRC_CONFIG/modules" -type f -printf '%P\n')"
    handlers=""
    subscribes_to=""
    for m in $_modules; do
        # Prevent circular invocations, this can be changed to be configurable
        # Maybe circual invocations are fine, or even wanted in some cases
        if echo "$m" | grep -qi "$1"; then
            continue
        fi
        _subscribes_to "$m"
        if echo "$subscribes_to" | grep -qi "$1"; then
            handlers="$handlers $m"
        fi
    done
    # Remove duplicates, but in reality there should not be any 
    handlers="$(echo "$handlers" | sed 's| |\n|g' | sort | uniq)"
    echo "$handlers" | grep -v "^$" | while read -r h; do
        debug "Notifying $h"
        echo "module_exec $h handle_event $*" 
    done
}

module_list() {
    debug 'List modules'
    debug 'Test module directory' "$WMRC_CONFIG/modules"
    if ! test -d "$WMRC_CONFIG/modules"; then
        error 'Modules directory not found' "$WMRC_CONFIG/modules"
        exit 1
    fi
    modules="$(find "$WMRC_CONFIG/modules" -type f -printf '%P\n')"
    if [ -n "$modules" ]; then
        debug 'Found modules' "$(echo "$modules" | sed -z 's/\n/, /g;s/, $/\n/')"
    fi
}

library_list() {
    debug 'List libraries'
    debug 'Test library directory' "$WMRC_CONFIG/libs"
    if ! test -d "$WMRC_CONFIG/libs"; then
        error 'Libraries directory not found' "$WMRC_CONFIG/libs"
        exit 1
    fi
    libraries="$(find "$WMRC_CONFIG/libs" -type f -printf '%P\n')"
    if [ -n "$libraries" ]; then
        debug 'Found libraries' "$(echo "$libraries" | sed -z 's/\n/, /g;s/, $/\n/')"
    fi
}

get_dependencies() {
    if [ -z "$1" ]; then
        debug 'Get all dependencies'
        module_list
        library_list
    else
        debug 'Get dependencies' "$1"
        _module_libraries "$1"
        modules="$1"
    fi
    _missing=''
    _libs=''
    _mods=''
    if [ -n "$libraries" ]; then
        _libs="$(echo "$libraries" | sed 's/^/libs\//g')"
    fi
    if [ -n "$modules" ]; then
        _mods="$(echo "$modules" | sed 's/^/modules\//g')"
    fi
    for f in $_mods $_libs; do
        _deps="$(
            sh -c ". '$WMRC_CONFIG/$f' && echo \$WMRC_DEPENDENCIES" | sed 's/ \{1,\}/:/g'
        )"
        _missing="$_missing${_missing:+:}$_deps"
    done
    debug 'Found dependencies' "$(echo "$_missing" | sed 's|:|, |g')"
    dependencies="$(echo "$_missing" | sed 's|:|\n|g' | sort | uniq)"
}

get_libraries() {
    if [ -z "$1" ]; then
        debug 'Get all libraries'
        module_list
    else
        debug 'Get libraries' "$1"
        modules="$1"
    fi
    _libs=''
    for m in $modules; do
        _module_libraries "$m"
        _libs="$_libs${_libs:+:}$libraries"
    done
    libraries="$(echo "$_libs" | sed 's|:|\n|g' | sort | uniq)"
}

check_dependencies() {
    debug 'Check dependencies' "$1"
    _missing_libs=''
    get_libraries "$1"
    for l in $(echo "$_libs" | sed 's|:|\n|g' | sort | uniq); do
        if ! test -f "$WMRC_CONFIG/libs/$l"; then
            _missing_libs="$_missing_libs${_missing_libs:+:}$l"
        fi
    done
    get_dependencies "$1"
    module_list
    _missing_mods=''
    _missing_deps=''
    for d in $dependencies; do
        if echo "$d" | grep -qE '\w+/\w+'; then
            if ! echo "$modules" | grep -qF "$d"; then
                _missing_mods="$_missing_mods${_missing_mods:+, }$d"
            fi
        else
            if ! command -v "$d" 1>/dev/null; then
                _missing_deps="$_missing_deps${_missing_deps:+, }$d"
            fi
        fi
    done
    if [ -n "$_missing_libs" ]; then
        error 'Missing libraries' "$_missing_libs"
    fi
    if [ -n "$_missing_mods" ]; then
        error 'Missing modules' "$_missing_mods"
    fi
    if [ -n "$_missing_deps" ]; then
        error 'Missing dependencies' "$_missing_deps"
    fi
    if [ -n "$_missing_mods" ] || [ -n "$_missing_libs" ] || [ -n "$_missing_deps" ]; then
        exit 1
    fi
}

read_config_variables() {
    debug 'Read configuration variables'
    test_config_file
    _vars="$(
        awk 'match($0, /^%(\w+) *= *(.*)$/, line) {
            printf("export WMRC_%s=\"%s\"\n",line[1],line[2]);
        }' "$WMRC_CONFIG/rc.conf"
    )"
    debug 'Load variables'
    eval "$_vars"

}

config_unit_list() {
    debug 'List units'
    test_config_file
    units="$(awk 'match($0, /^\[(\w+)\]$/, line) {
        print line[1];
    }' "$WMRC_CONFIG/rc.conf")"
}

run_config_unit() {
    debug 'Run configuration unit'
    test_config_file
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
        'match($0, /^\[(.+)\]$/, line) {
            unit=line[1];
        }
        match($0, /^%.*$/) {
            unit="";
        }
        match($0, /^(\w+\/\w+)(::)?(\w+)?(\((.+)\))? *(\w+)?/, line) {
            if (unit == target) {
                module=line[1];
                method=line[3] ? line[3] : "init";
                args=line[5];
                call=sprintf("%s::%s(%s)", module, method, args);s
                if (line[6] != "crit") {
                    detach=(line[6] == "wait") ? "" : "&";
                    printf( \
                        "info \"Executing %s call\" \"%s\"\n", \
                        (detach == "") ? "blocking" : "detatched", call \
                    );
                    printf("module_exec \"%s\" \"%s\" %s %s\n", module, method, args, detach);
                } else {
                    printf("info \"Executing critical call\" \"%s\"\n", call);
                    printf("module_exec \"%s\" \"%s\" %s || \\\n", module, method, args);
                    printf("{\n\terror \"Critical task failed, aborting\"\n\twait; exit 1\n}\n");
                }
            }
        }
    ' "$WMRC_CONFIG/rc.conf")"
    info 'Executing unit' "$1"
    eval "$_unit"
    wait
}

run_method() {
    debug 'Call method'
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
    _params=''
    while [ -n "$1" ]; do
        _params="$_params${_params:+ }'$1'"
        shift 1
    done
    info 'Executing method' "$_callee::$_method($_params)"
    eval "module_exec $_callee $_method $_params"
}

print_variable() {
    debug 'Print variable'
    if [ -z "$1" ]; then
        error 'Variable name not provided'
        exit 1
    fi
    eval "echo \$WMRC_$1"
}

list_running_daemons() {
    debug 'List running daemons'
    module_list
    _running=''
    for m in $modules; do
        _pid="$(
            sh -c "_module='$m' && . '$WMRC_DIR/libwmrc.sh' && . '$WMRC_CONFIG/modules/$m' && daemon_get_pid && echo \$DAEMON_PID"
        )"
        if [ "$?" = 0 ]; then
            _running="$_running${_running:+:}$_pid\t$m"
        fi
    done
    if [ -n "$_running" ]; then
        printf 'PID\tMODULE\n'
        printf '%b\n' "$(echo "$_running" | sed 's|:|\n|g')"
    fi
}

read_config_variables || exit 1

case "$1" in
    '')
        error 'No command specified'
        ;;
    '-v'|'--version'|'version')
        debug 'Print version'
        echo "wmrc $WMRC_VERSION"
        ;;
    '-h'|'--help'|'help')
        debug 'Print version'
        printf 'wmrc %s\nFilip Parag <filip@parag.rs>\n\nCommands:\n' "$WMRC_VERSION"
        printf '\tcall <group>/<module> <method> [args...]\n'
        printf '\tstart|stop|restart|status <group>/<module>\n'
        printf '\tps\n'
        printf '\tvar <variable>\n'
        printf '\tunit <unit>\n'
        printf '\tunits\n'
        printf '\tmodules\n'
        printf '\tdeps\n'
        printf '\tcheck-deps\n'
        printf '\tpublish-event <event-identifier> [args...]\n'
        printf '\thelp\n'
        printf '\tversion\n'
        ;;
    'call')
        shift 1
        _params=''
        while [ -n "$1" ]; do
            _params="$_params${_params:+ }'$( printf '%q' "$1")'"
            shift 1
        done
        eval "run_method $_params"
        ;;
    'var')
        shift 1
        eval "print_variable $1"
        ;;
    'unit')
        shift 1
        eval "run_config_unit $1"
        ;;
    'units')
        config_unit_list
        echo "$units"
        ;;
    'modules')
        module_list
        echo "$modules"
        ;;
    'start'|'stop'|'restart'|'status')
         if [ -z "$2" ]; then
            error 'Module name not provided'
            exit 1
        fi
        module_exec "$2" "$1"
        ;;
    'ps')
        list_running_daemons
        ;;
    'deps')
        get_dependencies
        echo "$dependencies" | grep -vE '\w+/\w+'
        ;;
    'check-deps')
        export WMRC_CHECK_DEPS=true
        check_dependencies
        ;;
    'publish-event')
        shift 1
        publish_event "$1"
        ;;
    'logs')
        case "$2" in
            '')
                cat "$LOG_FILE";;
            '-f'|'--follow')
                tail -n 0 -f "$LOG_FILE";;
            '-'*)
                error 'Unknown option' "$2";;
            *)
                echo a
        esac
        ;;
    *)
        error 'Unknown command' "$1"
        ;;
esac

