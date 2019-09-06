#!/usr/bin/env bash

set -e  # abort on any unhandled error
set -u  # abort on use of uninitialized variable

# constants
declare -r DEBUG=

# global variables used internally to this script
declare PROFILE_DIR=
declare RESTIC_TAG=
declare PRE_HOOKS=
declare POST_HOOKS=
declare SERVE_COMMAND=
declare -i KEEP_LAST=
declare -i KEEP_HOURLY=
declare -i KEEP_DAILY=
declare -i KEEP_WEEKLY=
declare -i KEEP_MONTHLY=
declare -i KEEP_YEARLY=

function main() {
  # make sure we have a minimum number of arguments
  if [[ "$#" -lt 2 ]] ; then
    usage
    exit 1
  fi

  # work out what directory to use for our configs
  for dirpath in /etc/restic ~/.restic . ; do
    if [[ -d "$dirpath" && -w "$dirpath" ]] ; then
      PROFILE_DIR="$dirpath"
      dbg "PROFIE_DIR is $PROFILE_DIR"
      break
    fi
    abort "Unable to locate suitable configuration directory"
  done

  cmd="$1"
  shift
  dbg "Command is $cmd"

  # loop over remaining cmdline args, treating them as profiles
  for profile in "$@" ; do
    case "$cmd" in
      edit)
        profile_edit "$profile"
        ;;
      init)
        restic_init "$profile"
        ;;
      start)
        restic_start "$profile"
        ;;
      check)
        restic_check "$profile"
        ;;
      forget)
        restic_forget "$profile"
        ;;
      prune)
        restic_prune "$profile"
        ;;
      cleanup)
        restic_forget "$profile"
        restic_prune "$profile"
        ;;
      shell)
        restic_shell "$profile"
        ;;
      *)
        usage
        exit 1
    esac
  done
}

### SUBCOMMAND: INIT ###########################################################
function restic_init {
  local -r profile="$1"
  load_profile "$profile"
  restic init
}

### SUBCOMMAND: START ##########################################################
function restic_start {
  local -r profile="$1"
  local restic_args=''
  load_profile "$profile"

  [[ -n "$RESTIC_TAG" ]] && restic_args="$restic_args --tag $RESTIC_TAG"

  for epattern in "${BACKUP_EXCLUDE[@]}" ; do
    restic_args="$restic_args --exclude $epattern"
  done

  for ipattern in "${BACKUP_INCLUDE[@]}" ; do
    [[ ! -e "$ipattern" ]] && abort "Include path not found: $ipattern"
  done

  if [[ -n "$SERVE_COMMAND" ]] ; then
    dbg "Starting serve command: $SERVE_COMMAND"
    exec $SERVE_COMMAND &
    serve_command_pid=$!
    # give the serve process time to startup, then make sure it's still there
    sleep 1
    kill -0 $serve_command_pid &>/dev/null || abort "SERVE_COMMAND exited before we started work."
  fi
  for cmd in "${PRE_HOOKS[@]}" ; do
    exec $cmd
  done
  restic backup $restic_args "${BACKUP_INCLUDE[@]}"
  for cmd in "${POST_HOOKS[@]}" ; do
    exec $cmd
  done
  if [[ -n "$SERVE_COMMAND" ]] ; then
    kill $serve_command_pid
  fi
}

### SUBCOMMAND: forget #######################################################
function restic_forget {
  local -r profile="$1"
  local restic_args=''
  load_profile "$profile"

  [[ -n "$RESTIC_TAG" ]] && restic_args="$restic_args --tag $RESTIC_TAG"

  local keep_args=''
  [[ "$KEEP_LAST" -gt 0 ]]    && keep_args="$keep_args --keep-last $KEEP_LAST"
  [[ "$KEEP_HOURLY" -gt 0 ]]  && keep_args="$keep_args --keep-hourly $KEEP_HOURLY"
  [[ "$KEEP_DAILY" -gt 0 ]]   && keep_args="$keep_args --keep-daily $KEEP_DAILY"
  [[ "$KEEP_WEEKLY" -gt 0 ]]  && keep_args="$keep_args --keep-weekly $KEEP_WEEKLY"
  [[ "$KEEP_MONTHLY" -gt 0 ]] && keep_args="$keep_args --keep-monthly $KEEP_MONTHLY"
  [[ "$KEEP_YEARLY" -gt 0 ]]  && keep_args="$keep_args --keep-yearly $KEEP_YEARLY"
  restic_args="$restic_args $keep_args"

  restic forget $restic_args
}

### SUBCOMMAND: prune #########################################################
function restic_prune {
  local -r profile="$1"
  load_profile "$profile"

  restic prune
}

### SUBCOMMAND: check #########################################################
function restic_check {
  local -r profile="$1"
  load_profile "$profile"

  restic check
}

### SUBCOMMAND: shell #########################################################
function restic_shell {
  local -r profile="$1"
  load_profile "$profile"

  cat <<EOF
+-----------------------------------------------------------------------------+
 STARTING A NEW SHELL WITH ENVIRONMENT FOR RESTIC PROFILE '$profile'
 Type 'exit' when finished.
+-----------------------------------------------------------------------------+
EOF
  bash
  echo 'RESTIC SHELL EXITED.'
}

### PROFILE EDIT ##############################################################
function profile_edit {
  local -r profile_name="$1"
  local -r fname="$(get_profile_filename "$profile_name")"
  local -r tmpname="${fname}.tmp"

  # we want to work on a temporary file until the user is finished and we can
  # validate it as looking like a reasonable configuration
  if [[ -f "$fname" ]] ; then
    # copy the live file to a temp file
    cp -f "$fname" "$tmpname"
  else
    # no existing profile; make a temporary one
    create_profile_template "$profile_name" "$tmpname"
  fi

  # start the editor
  edit_cmd="$(get_editor)"
  while true ; do
    if $edit_cmd "$tmpname" ; then
      # editor exited successfully; test the file before moving back in-place
      # we need to temporarily disable the -e option because any errors inside
      # the config file will cause an abort, instead of being caught in our
      # script as part of the `source` commands
      set +eu
      if ! errs=$(bash -n "$tmpname" 2>&1); then
        echo "Invalid syntax: $errs"
        read -p 'Press enter to edit again' z
        continue
      fi
      set -eu

      if [[ ! -s "$tmpname" ]] ; then
        dbg "Config file returned with zero-bytes"
      elif cmp --silent "$fname" "$tmpname" ; then
        dbg "No changes"
      else
        dbg "Moving $tmpname => $fname"
        mv -f "$tmpname" "$fname"
      fi
    fi
    rm -f "$tmpname"
    break
  done
}

###############################################################################
### HELPER FUNCTIONS BELOW HERE
###############################################################################
function usage {
  cat <<EOF
Usage: $0 (init|start|edit|forget|prune|cleanup|check|shell) profile [profile2 profileX]

  init      Initialize \$RESTIC_REPOSITORY
  start     Start a backup
  edit      Edit profile configuration
  forget    Forget old snapshots based on retention policies
  prune     Prune old data from repository
  cleanup   'forget' and 'prune' together
  check     Check the repository for errors
  shell     Start a shell with the relevant environment variables set

If more than 1 profile is given, loop through each one in sequence.
EOF
  return 0
}

function dbg {
  [[ -z $DEBUG ]] && return 0
  echo "DEBUG: $1"
}

function abort {
  echo "ABORT: $1" >&2
  exit 1
}

function get_profile_filename {
  echo "$PROFILE_DIR/${1}.conf"
}

function load_profile {
  local -r profile_fname="$(get_profile_filename "$1")"

  clear_existing_profile_vars

  if [[ ! -f "$profile_fname" ]] ; then
    abort "Profile not found '$profile_fname'"
  fi

  if [[ ! -r "$profile_fname" ]] ; then
    abort "Unable to read profile '$profile_fname'"
  fi

  source "$profile_fname"
  dbg "Loaded profile: $profile_fname"

  # export restic configuration variables
  # we unset all variables earlier in this function, so testing if they're set
  # here will throw an undefined variable error (due to set -u at top of script)
  # see this page explanation of the syntax to check to defined/undefined:
  # https://stackoverflow.com/questions/3601515/how-to-check-if-a-variable-is-set-in-bash
  [[ -n "${RESTIC_REPOSITORY+x}" ]]     && export RESTIC_REPOSITORY
  [[ -n "${RESTIC_PASSWORD+x}" ]]       && export RESTIC_PASSWORD
  [[ -n "${AWS_ACCESS_KEY_ID+x}" ]]     && export AWS_ACCESS_KEY_ID
  [[ -n "${AWS_SECRET_ACCESS_KEY+x}" ]] && export AWS_SECRET_ACCESS_KEY

  check_minimum_viable_profile
}

function clear_existing_profile_vars {
  unset RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  RESTIC_TAG=
  PRE_HOOKS=
  POST_HOOKS=
  SERVE_COMMAND=
  KEEP_LAST=
  KEEP_HOURLY=
  KEEP_DAILY=
  KEEP_WEEKLY=
  KEEP_MONTHLY=
  KEEP_YEARLY=
}

function check_minimum_viable_profile {
  [[ -z "$RESTIC_REPOSITORY" ]] && abort 'Configuration not set: $RESTIC_REPOSITORY'
  [[ ${#BACKUP_INCLUDE[@]} -eq 0 ]] && abort 'BACKUP_INCLUDE cannot be empty'
  while true ; do
    [[ "$KEEP_LAST" -gt 0 ]]    && break
    [[ "$KEEP_HOURLY" -gt 0 ]]  && break
    [[ "$KEEP_DAILY" -gt 0 ]]   && break
    [[ "$KEEP_WEEKLY" -gt 0 ]]  && break
    [[ "$KEEP_MONTHLY" -gt 0 ]] && break
    [[ "$KEEP_YEARLY" -gt 0 ]]  && break
    abort 'At least one of KEEP_LAST, KEEP_HOURLY, KEEP_DAILY, KEEP_WEEKLY, KEEP_MONTHLY or KEEP_YEARLY must be specified'
  done
  return 0
}

function get_editor {
  # check the environment for an editor; fall back to well-known defaults but
  # abort if we can't find anything useful
  if [[ -n "$EDITOR" ]] ; then
    echo "$EDITOR"
  elif [[ -n "$VISUAL" ]] ; then
    echo "$VISUAL"
  elif hash nano 2>/dev/null ; then
    echo nano
  elif hash vim 2>/dev/null ; then
    echo vim
  elif hash vi 2>/dev/null ; then
    echo vi
  else
    abort "Could not find suitable editor. Try setting \$EDITOR"
  fi
}

function create_profile_template {
  local pname="$1"
  local fname="$2"
  cat > "$fname" <<EOF
# Configuration file for restic profile '$pname'
# Created at $(date) by $USER on $(uname -n)
#
# This file follows shell syntax:
#   1. Don't forget proper quoting where appropriate
#   2. Shell commands can be used (eg, subshells, variable expansion etc)

# restic repository and access options
RESTIC_REPOSITORY=
RESTIC_PASSWORD=
#AWS_ACCESS_KEY_ID=
#AWS_SECRET_ACCESS_KEY=
RESTIC_TAG=$pname

# what to backup and exclude
BACKUP_INCLUDE=(
  '/home'
  '/etc'
)
BACKUP_EXCLUDE=(
  '*.tmp'
)

# if you need to run commands before or after the backup, specify them here
# for example, running a backup of a database to a file
PRE_HOOKS=(
  'rclone serve restic MyServer:restic.repo &'
)
POST_HOOKS=(
)

# if you need a command to serve the restic repository (eg, rclone) then
# you can specify it here
#SERVE_COMMAND='rclone serve restic MyServer:restic.repo'

# options for the 'forget' command. Leave blank or
# comment whole line to disable the flag.
KEEP_LAST=
KEEP_HOURLY=
KEEP_DAILY=
KEEP_WEEKLY=
KEEP_MONTHLY=
KEEP_YEARLY=
EOF
  return 0
}

main "$@"
