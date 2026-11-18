#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fixed engine boundary. Transmission is the only supported backend.
# Inputs are supplied by the caller; no plugin loading or backend autodetection.
# Import is coordinated while the engine is stopped, using explicit context.
#
# Contract of the action wrappers below (those with an operation scope):
# each backend action is called on a line of its own, never in a condition
# (if, ||, &&, !), so that « set -e » stays in force in all its steps. Under
# seedtunnel (set -Eeuo pipefail) a failure ends the command there, and the
# lock goes with its descriptor: the status kept after the call is then
# always 0. It serves a caller that runs without « set -e »: the unit tests,
# which check these statuses. Never call these wrappers, nor what calls them,
# in a condition either: bash would turn « set -e » off in the whole chain
# and a step that fails in the middle would pass unseen. The test
# actions_never_called_in_a_condition holds them to it. The queries
# (engine_archive_*, engine_is_active…) may be conditions. To run an action
# apart: subshell_run, itself on a line of its own. The same holds for the
# « call; status=$? » of seedbox.sh, backup.sh and
# engine_transmission_backup.sh. The undo script of a restore has no error
# trap: a failure there may stop it without a message.

engine_configure() {
    local OPERATION_FD=${OPERATION_FD-} _engine_owner="" _engine_status
    operation_begin _engine_owner || return $?
    transmission_configure "$@"
    _engine_status=$?
    operation_end "$_engine_owner" || return 1
    return "$_engine_status"
}

engine_apply_confinement() {
    local OPERATION_FD=${OPERATION_FD-} _engine_owner="" _engine_status
    operation_begin _engine_owner || return $?
    transmission_apply_apparmor "$1"
    _engine_status=$?
    operation_end "$_engine_owner" || return 1
    return "$_engine_status"
}

engine_remove_confinement() {
    local OPERATION_FD=${OPERATION_FD-} _engine_owner="" _engine_status
    operation_begin _engine_owner || return $?
    transmission_remove_apparmor "$1"
    _engine_status=$?
    operation_end "$_engine_owner" || return 1
    return "$_engine_status"
}

engine_install() {
    local OPERATION_FD=${OPERATION_FD-} _engine_owner="" _engine_status
    operation_begin _engine_owner || return $?
    transmission_install "$@"
    _engine_status=$?
    operation_end "$_engine_owner" || return 1
    return "$_engine_status"
}
engine_purge_packages() {
    local OPERATION_FD=${OPERATION_FD-} _engine_owner="" _engine_status
    operation_begin _engine_owner || return $?
    transmission_purge_packages "$@"
    _engine_status=$?
    operation_end "$_engine_owner" || return 1
    return "$_engine_status"
}
engine_package() { transmission_package; }
engine_service_name() { transmission_service_name; }
engine_start() { engine_service_call transmission_start; }
engine_stop() { engine_service_call transmission_stop; }
engine_restart() { engine_service_call transmission_restart; }
engine_disable() { engine_service_call transmission_disable; }
engine_is_active() { transmission_is_active; }
engine_remove_override() {
    local OPERATION_FD=${OPERATION_FD-} _engine_owner="" _engine_status
    operation_begin _engine_owner || return $?
    transmission_remove_override
    _engine_status=$?
    operation_end "$_engine_owner" || return 1
    return "$_engine_status"
}

engine_account() { transmission_account; }
engine_group() { transmission_group; }

engine_display_name() { transmission_display_name; }
engine_web_path() { transmission_web_path; }
engine_rpc_path() { transmission_rpc_path; }
engine_observe() { transmission_observe "$1"; }

# Fixed observation selectors; result arrays contain facts, never messages.
engine_inspect() { transmission_inspect "$1" "$2" "$3"; }
engine_probe() { transmission_probe "$1" "$2"; }

engine_runtime_state() { transmission_runtime_state; }

# Only raw, single-command backend service methods belong here. A multi-step
# action must use a direct scope so its errexit semantics are retained.
engine_service_call() {
    local OPERATION_FD=${OPERATION_FD-} _engine_service_owner="" _engine_service_status=0
    operation_begin _engine_service_owner || return $?
    "$@" || _engine_service_status=$?
    if ! operation_end "$_engine_service_owner"; then
        if ((_engine_service_status == 0)); then _engine_service_status=1; fi
    fi
    return "$_engine_service_status"
}

# Archive paths and recognition are backend-owned; common tar validation is
# independent. Patterns are code constants, never obtained from an archive.
engine_export_paths() { transmission_export_paths "$1"; }
engine_archive_pattern() { transmission_archive_pattern; }
engine_archive_native() {
    local pattern
    pattern="^($(engine_archive_pattern))(/|$)"
    [[ $1 =~ $pattern ]]
}
engine_archive_has_items() { transmission_archive_has_items; }

# EXTRACTED DATA_DIR MANUAL_MAGNETS RESULT_ARRAY. The coordinator has validated the archive
# and stopped the daemon; this scope borrows its operation when nested.
engine_import() {
    local -n _engine_import_receipt=$4
    _engine_import_receipt=([state]=failed)
    local OPERATION_FD=${OPERATION_FD-} _engine_import_owner="" _engine_import_status
    operation_begin _engine_import_owner || return $?
    transmission_import "$@"
    _engine_import_status=$?
    operation_end "$_engine_import_owner" || return 1
    return "$_engine_import_status"
}

engine_archive_check() { transmission_archive_check "$1"; }
engine_recovery_script() { transmission_recovery_script "$1" "$2"; }

engine_checkpoint_create() {
    local OPERATION_FD=${OPERATION_FD-} _engine_checkpoint_owner="" _engine_checkpoint_status
    operation_begin _engine_checkpoint_owner || return $?
    transmission_checkpoint_create "$1"
    _engine_checkpoint_status=$?
    operation_end "$_engine_checkpoint_owner" || return 1
    return "$_engine_checkpoint_status"
}

engine_checkpoint_restore() {
    local OPERATION_FD=${OPERATION_FD-} _engine_checkpoint_owner="" _engine_checkpoint_status
    operation_begin _engine_checkpoint_owner || return $?
    transmission_checkpoint_restore "$1"
    _engine_checkpoint_status=$?
    operation_end "$_engine_checkpoint_owner" || return 1
    return "$_engine_checkpoint_status"
}

engine_recovery_stop() {
    local OPERATION_FD=${OPERATION_FD-} _engine_recovery_owner="" _engine_recovery_status
    operation_begin _engine_recovery_owner || return $?
    transmission_stop_for_restore
    _engine_recovery_status=$?
    operation_end "$_engine_recovery_owner" || return 1
    return "$_engine_recovery_status"
}
