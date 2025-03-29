#!/bin/bash
# wg-udp2raw
# Manages `udp2raw` to run WireGuard over a fake TCP connection
#
# More about WireGuard: https://www.wireguard.com/
# More about `udp2raw`: https://github.com/wangyu-/udp2raw
# More about this project: https://github.com/PhrozenByte/wg-udp2raw
#
# Copyright (C) 2025 Daniel Rudolf (<https://www.daniel-rudolf.de>)
# License: The MIT License <http://opensource.org/licenses/MIT>
#
# SPDX-License-Identifier: MIT

print_usage() {
    echo "Usage:"
    echo "  ${BASH_SOURCE[0]} up <config> <endpoint_hostname> <endpoint_port> <local_port>"
    echo "  ${BASH_SOURCE[0]} down <config>"
    echo "  ${BASH_SOURCE[0]} watchdog <config> <interval>"
}

print_version() {
    echo "wg-udp2raw.sh 1.0 (build 20250316)"
    echo
    echo "Copyright (C) 2025  Daniel Rudolf"
    echo "This work is licensed under the terms of the MIT license."
    echo "For a copy, see LICENSE file or <https://opensource.org/licenses/MIT>."
    echo
    echo "Written by Daniel Rudolf <https://www.daniel-rudolf.de/>"
    echo "See also: <https://github.com/PhrozenByte/wg-udp2raw>"
    exit 0
}

quote() {
    local QUOTED=
    for ARG in "$@"; do
        [ "$(printf '%q' "$ARG")" == "$ARG" ] \
            && QUOTED+=" $ARG" \
            || QUOTED+=" ${ARG@Q}"
    done
    echo "${QUOTED:1}"
}

cmd() {
    echo + "$(quote "$@")" >&2
    "$@"
}

[ "${1:-}" != "--help" ] || { print_usage; exit 0; }
[ "${1:-}" != "--version" ] || { print_version; exit 0; }
[ $# -ge 2 ] || { print_usage >&2; exit 1; }

[ -x "$(which ip)" ] || { echo "Missing script dependency: ip" >&2; exit 1; }
[ -x "$(which sed)" ] || { echo "Missing script dependency: sed" >&2; exit 1; }
[ -x "$(which gawk)" ] || { echo "Missing script dependency: gawk" >&2; exit 1; }
[ -x "$(which grep)" ] || { echo "Missing script dependency: grep" >&2; exit 1; }
[ -x "$(which getent)" ] || { echo "Missing script dependency: getent" >&2; exit 1; }
[ -x "$(which udp2raw)" ] || { echo "Missing script dependency: udp2raw" >&2; exit 1; }

COMMAND="$1"
[ "$COMMAND" == "up" ] || [ "$COMMAND" == "down" ] || [ "$COMMAND" == "watchdog" ] \
    || { echo "Invalid command: $COMMAND" >&2; exit 1; }

CONFIG="$2"
[ -n "$CONFIG" ] && [ -f "/etc/udp2raw/$CONFIG.conf" ] || { echo "Unknown config: $CONFIG" >&2; exit 1; }

# setup command
if [ "$COMMAND" == "up" ]; then
    [ $# -ge 5 ] || { print_usage >&2; exit 1; }
    [ ! -e "/run/wg-udp2raw/$CONFIG" ] || { echo "Duplicate instance of config: $CONFIG" >&2; exit 1; }

    ENDPOINT_HOST="$3"
    [ -n "$ENDPOINT_HOST" ] || { echo "Invalid endpoint hostname: $ENDPOINT_HOST" >&2; exit 1; }

    ENDPOINT_PORT="$4"
    [[ "$ENDPOINT_PORT" =~ ^[0-9]+$ ]] && (( ENDPOINT_PORT > 0 && ENDPOINT_PORT <= 65535 )) || { echo "Invalid endpoint port: $ENDPOINT_PORT" >&2; exit 1; }

    LOCAL_PORT="$5"
    [[ "$LOCAL_PORT" =~ ^[0-9]+$ ]] && (( LOCAL_PORT > 0 && LOCAL_PORT <= 65535 )) || { echo "Invalid local port: $LOCAL_PORT" >&2; exit 1; }

    WATCHDOG_INTERVAL=
    WATCHDOG_PID=

    # check config
    grep -q -Fx -- '-c' "/etc/udp2raw/$CONFIG.conf" || { echo "Invalid udp2raw client config: $CONFIG" >&2; exit 1; }
    grep -q '^-k wg-udp2raw ' "/etc/udp2raw/$CONFIG.conf" || { echo "Invalid wg-udp2raw config: $CONFIG" >&2; exit 1; }
    ! systemctl is-active -q "udp2raw@$CONFIG.service" || { echo "Systemd unit already running: udp2raw@$CONFIG.service" >&2; exit 1; }

    # get the endpoint's IP address and a direct route to it
    if [ $# -ge 8 ] && [ "$6" == "-!" ]; then
        # use the endpoint IP address and route given by watchdog (internal -! option)
        ENDPOINT_IP="$7"
        ENDPOINT_ROUTE="$8"
    else
        # resolve endpoint hostname
        ENDPOINT_IP="$(getent ahostsv4 "$ENDPOINT_HOST" | gawk '$2 == "RAW" { print $1 }')"
        [ -n "$ENDPOINT_IP" ] || { echo "Failed to resolve endpoint hostname: $ENDPOINT_HOST" >&2; exit 1; }

        # get direct route to endpoint via default interface (i.e. bypassing any VPN)
        ENDPOINT_ROUTE_INTERFACE="$(ip -4 route show default | sed -ne 's/^.*\bdev \(\S*\)\b.*$/\1/p')"
        [ -n "$ENDPOINT_ROUTE_INTERFACE" ] || { echo "Failed to get default route interface" >&2; exit 1; }

        ENDPOINT_ROUTE="$(ip -4 route get "$ENDPOINT_IP" dport "$ENDPOINT_PORT" oif "$ENDPOINT_ROUTE_INTERFACE" | sed -n -e 's/\buid [0-9]*\b//g' -e '1p')"
        [ -n "$ENDPOINT_ROUTE" ] || { echo "Failed to get route to endpoint: $ENDPOINT_HOST $ENDPOINT_IP" >&2; exit 1; }
    fi

    # add direct route to endpoint
    cmd ip route add $ENDPOINT_ROUTE
    [ $? -eq 0 ] || { echo "Failed to add route to endpoint: $ENDPOINT_ROUTE" >&2; exit 1; }

    # prepare udp2raw config
    echo + "wg-udp2raw_config" >&2
    gawk -i inplace -v port="$LOCAL_PORT" '{print gensub(/^-l ([^ ]+):([0-9]+)$/, "-l \\1:" port, 1)}' "/etc/udp2raw/$CONFIG.conf"
    gawk -i inplace -v ip="$ENDPOINT_IP" -v port="$ENDPOINT_PORT" '{print gensub(/^-r ([^ ]+):([0-9]+)$/, "-r " ip ":" port, 1)}' "/etc/udp2raw/$CONFIG.conf"
    gawk -i inplace -v ident="$ENDPOINT_HOST:$ENDPOINT_PORT" '{print gensub(/^-k wg-udp2raw (.+)$/, "-k wg-udp2raw " ident, 1)}' "/etc/udp2raw/$CONFIG.conf"

    # start udp2raw Systemd service
    cmd systemctl start "udp2raw@$CONFIG.service"

    # create /run/wg-udp2raw directory, if necessary
    [ -d "/run/wg-udp2raw" ] || cmd mkdir -m 700 /run/wg-udp2raw

    # setup done, write status
    echo + "wg-udp2raw_status > $(quote "/run/wg-udp2raw/$CONFIG")" >&2
    declare -p CONFIG ENDPOINT_HOST ENDPOINT_IP ENDPOINT_PORT ENDPOINT_ROUTE LOCAL_PORT WATCHDOG_INTERVAL WATCHDOG_PID \
        | sed -e 's/^declare -- //g' > "/run/wg-udp2raw/$CONFIG"
    exit 0
fi

# teardown command
if [ "$COMMAND" == "down" ]; then
    [ -f "/run/wg-udp2raw/$CONFIG" ] || { echo "No running instance of config: $CONFIG" >&2; exit 1; }
    . "/run/wg-udp2raw/$CONFIG"

    # stop udp2raw Systemd service
    cmd systemctl stop "udp2raw@$CONFIG.service"

    # remove direct route to endpoint
    cmd ip route del $ENDPOINT_ROUTE

    # kill watchdog, if running and if teardown wasn't issued by watchdog (internal -! option)
    [ -z "$WATCHDOG_PID" ] || [ "${3:-}" == "-!" ] \
        || { echo + "kill $WATCHDOG_PID # wg-udp2raw watchdog" >&2; kill "$WATCHDOG_PID"; }

    # teardown done, clear status
    cmd rm -f "/run/wg-udp2raw/$CONFIG"
    exit 0
fi

# watchdog command
if [ "$COMMAND" == "watchdog" ]; then
    [ $# -ge 3 ] || { print_usage >&2; exit 1; }

    [ -f "/run/wg-udp2raw/$CONFIG" ] || { echo "No running instance of config: $CONFIG" >&2; exit 1; }
    . "/run/wg-udp2raw/$CONFIG"

    WATCHDOG_INTERVAL="$3"
    [[ "$WATCHDOG_INTERVAL" =~ ^[0-9]+$ ]] && (( WATCHDOG_INTERVAL > 0 )) || { echo "Invalid watchdog interval: $WATCHDOG_INTERVAL" >&2; exit 1; }

    # check for other watchdog
    [ -z "$WATCHDOG_PID" ] || [ "$WATCHDOG_PID" == $$ ] || ! ps -p "$WATCHDOG_PID" > /dev/null 2>&1 \
        || { echo "Duplicate watchdog: $CONFIG (PID $WATCHDOG_PID)" >&2; exit 1; }

    # watchdog service process (internal -! option)
    if [ $# -ge 4 ] && [ "$4" == "-!"  ]; then
        while true; do
            sleep "$WATCHDOG_INTERVAL"
            RESTART="y"

            # check whether the endpoint's IP address has changed
            NEW_ENDPOINT_IP="$(getent ahostsv4 "$ENDPOINT_HOST" | gawk '$2 == "RAW" { print $1 }')"
            NEW_ENDPOINT_IP="${NEW_ENDPOINT_IP:-$ENDPOINT_IP}"

            if [ "$NEW_ENDPOINT_IP" == "$ENDPOINT_IP" ]; then
                # check whether the direct route to the endpoint has changed
                NEW_ENDPOINT_ROUTE_INTERFACE="$(ip -4 route show default | sed -ne 's/^.*\bdev \(\S*\)\b.*$/\1/p')"
                NEW_ENDPOINT_ROUTE_INTERFACE="${NEW_ENDPOINT_ROUTE_INTERFACE:-$(sed -ne 's/^.*\bdev \(\S*\)\b.*$/\1/p' <<< "$ENDPOINT_ROUTE")}"

                NEW_ENDPOINT_ROUTE="$(ip -4 route get "$NEW_ENDPOINT_IP" dport "$ENDPOINT_PORT" oif "$NEW_ENDPOINT_ROUTE_INTERFACE" | sed -n -e 's/\buid [0-9]*\b//g' -e '1p')"
                NEW_ENDPOINT_ROUTE="${NEW_ENDPOINT_ROUTE:-$ENDPOINT_ROUTE}"

                if [ "$NEW_ENDPOINT_ROUTE" == "$ENDPOINT_ROUTE" ]; then
                    RESTART="n"
                fi
            fi

            # restart udp2raw and watchdog, if necessary
            if [ "$RESTART" == "y" ]; then
                cmd "${BASH_SOURCE[0]}" down "$CONFIG" -!
                cmd "${BASH_SOURCE[0]}" up "$CONFIG" "$ENDPOINT_HOST" "$ENDPOINT_PORT" "$LOCAL_PORT" -! "$NEW_ENDPOINT_IP" "$NEW_ENDPOINT_ROUTE"
                [ $? -ne 0 ] || cmd "${BASH_SOURCE[0]}" watchdog "$CONFIG" "$WATCHDOG_INTERVAL"
                break
            fi
        done
        exit 0
    fi

    # run watchdog
    echo + "$(quote "${BASH_SOURCE[0]}" watchdog "$CONFIG" "$WATCHDOG_INTERVAL" -!) &" >&2
    "${BASH_SOURCE[0]}" watchdog "$CONFIG" "$WATCHDOG_INTERVAL" -! &
    WATCHDOG_PID=$!

    # watchdog setup done, update status
    echo + "wg-udp2raw_status > $(quote "/run/wg-udp2raw/$CONFIG")" >&2
    declare -p CONFIG ENDPOINT_HOST ENDPOINT_IP ENDPOINT_PORT ENDPOINT_ROUTE LOCAL_PORT WATCHDOG_INTERVAL WATCHDOG_PID \
        | sed -e 's/^declare -- //g' > "/run/wg-udp2raw/$CONFIG"
    exit 0
fi
