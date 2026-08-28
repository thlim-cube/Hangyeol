#!/bin/bash

classify_hangyeol_installation() {
    if [ "$#" -ne 7 ]; then
        return 64
    fi

    local was_installed=$1
    local previous_bundle_identifier=$2
    local previous_connection_name=$3
    local previous_input_mode_schema=$4
    local current_bundle_identifier=$5
    local current_connection_name=$6
    local current_input_mode_schema=$7

    case "$was_installed" in
        1|true|TRUE|YES)
            if [ -n "$previous_bundle_identifier" ] \
                && [ "$previous_bundle_identifier" = "$current_bundle_identifier" ] \
                && [ -n "$previous_connection_name" ] \
                && [ "$previous_connection_name" = "$current_connection_name" ] \
                && [ -n "$previous_input_mode_schema" ] \
                && [ "$previous_input_mode_schema" = "$current_input_mode_schema" ]; then
                printf '%s\n' "ordinary-update"
            else
                printf '%s\n' "registration-change"
            fi
            ;;
        0|false|FALSE|NO)
            printf '%s\n' "first-installation"
            ;;
        *)
            # Unknown snapshot state must never trigger live TIS writes.
            printf '%s\n' "registration-change"
            ;;
    esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    classify_hangyeol_installation "$@"
fi
