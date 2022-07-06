#!/bin/zsh
# Title: OC Backup Script
# Description: Creates a backup of the whole owncloud/nextcloud installation incl. Postgresql database.
# Author: Julian Poemp
# Version: 1.0.1
# LICENSE: MIT
# Check for updates: https://github.com/julianpoemp/oc-backup

OCB_VERSION="1.0.0"
SECONDS=0
CONF_PATH="./oc_backup.cfg"

# constants ot configuration file
OC_COMPOSE_DIRECTORY=""
OC_INSTALLATION_PATH=""
OC_DATA_PATH=""
OC_DB_NAME=""
OC_DB_USER=""
OC_DB_PASSWORD=""
OC_DB_PORT=""
OC_DB_HOST=""
OC_DATA_BACKUP_DESTINATION=""
OC_DATABASE_BACKUP_DESTINATION=""
OC_BACKUP_LOG_DESTINATION=""
CREATE_LOGFILE=true
OCB_TYPE=""
OC_CONTAINER_NAME=""

cmd_zip_exists=false
cmd_pg_dump_exists=false
missing_constants=""
is_config_valid=false
show_help=false
time_stamp=$(date "+%Y-%m-%d_%H-%M-%S")

errors_found=0

POSITIONAL=()
while [[ $# -gt 0 ]]; do
  key="$1"

  case $key in
  -c | --conf)
    CONF_PATH="$2"
    shift # past argument
    shift # past value
    ;;
  -h | --help)
    show_help=true
    shift # past argument
    shift # past value
    ;;
  *) # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift              # past argument
    ;;
  esac
done
set -- "${POSITIONAL[@]}"

source "${CONF_PATH}"

# FUNCTIONS
log() {
  if [ "${1}" != "" ]; then
    if [ "${CREATE_LOGFILE}" = true ]; then
      mkdir "${OC_BACKUP_LOG_DESTINATION}" &>/dev/null
      echo "* $(get_current_timestamp) | ${1}" | tee -a "${OC_BACKUP_LOG_DESTINATION}/${time_stamp}_log.txt"
    else
      echo "* $(get_current_timestamp) | ${1}"
    fi
  fi
}

check_cosuccess() {
  stdout=$("${1}" 2>stderr.txt)
  stderr=$(cat stderr.txt)

  log "${stdout}"
  log "Error: ${stderr}"

  echo "" >stderr.txt

  echo 0
}

check_available_commands() {
  if type "zip" &>/dev/null; then
    cmd_zip_exists=true
  else
    cmd_zip_exists=false
  fi

  if type "pg_dump" &>/dev/null; then
    cmd_pg_dump_exists=true
  else
    cmd_pg_dump_exists=false
  fi
}

check_config() {
  if ! [[ "${OCB_TYPE}" = "owncloud" ]] && ! [[ "${OCB_TYPE}" = "nextcloud" ]]; then
    OCB_TYPE="owncloud"
  fi

  if [ "${OC_INSTALLATION_PATH}" = "" ]; then
    missing_constants="OC_INSTALLATION_PATH, "
  fi

  if [ "${OC_DB_NAME}" = "" ]; then
    missing_constants="${missing_constants}OC_DB_NAME, "
  fi

  if [ "${OC_DB_USER}" = "" ]; then
    missing_constants="${missing_constants}OC_DB_USER, "
  fi

  if [ "${OC_DB_PASSWORD}" = "" ]; then
    missing_constants="${missing_constants}OC_DB_PASSWORD, "
  fi

  if [ "${OC_DATA_BACKUP_DESTINATION}" = "" ]; then
    missing_constants="${missing_constants}OC_DATA_BACKUP_DESTINATION, "
  fi

  if [ "${OC_DATABASE_BACKUP_DESTINATION}" = "" ]; then
    missing_constants="${missing_constants}OC_DATABASE_BACKUP_DESTINATION, "
  fi

  if [ "${OC_BACKUP_LOG_DESTINATION}" = "" ]; then
    missing_constants="${missing_constants}OC_BACKUP_LOG_DESTINATION, "
  fi

  if [ "${OC_CONTAINER_NAME}" = "" ]; then
    missing_constants="${missing_constants}OC_CONTAINER_NAME, "
  fi

  if [ "${missing_constants}" = "" ]; then
    is_config_valid=true
  else
    is_config_valid=false
  fi
}

enable_maintenance_mode() {
  maintenance_mode_enable="'maintenance' => true,"
  maintenance_mode_disable="'maintenance' => false,"
  log "-> Enable maintenance mode..."
  if [ ${maintenance_mode_disable} ]; then
    sed -i "s/${maintenance_mode_disable}/${maintenance_mode_enable}/" "${configPath}"
  fi
  log "-> Maintenance mode enabled..."
}

disable_maintenance_mode() {
  maintenance_mode_enable="'maintenance' => true"
  maintenance_mode_disable="'maintenance' => false"
  log "-> Disable maintenance mode..."
  if [ ${maintenance_mode_enable} ]; then
    sed -i "s/${maintenance_mode_enable}/${maintenance_mode_disable}/" "${configPath}"
  fi
  log "-> Maintenance mode disabled..."
}


restart_owncloud_instance() {
  log "-> RESTART OWNCLOUD DOCKER INSTANCE..."
  stdout=$(cd "${OC_COMPOSE_DIRECTORY}" && docker-compose restart)
  log "-> OWNCLOUD DOCKER INSTANCE RESTARTED..."
}

create_data_config_zip_backup() {
  log "-> Create zip archive of ${OCB_TYPE} files, sessions and config..."

  stdout=$(zip -r -s 1000m "${OC_DATA_BACKUP_DESTINATION}/${time_stamp}_${OCB_TYPE}.zip" "${OC_INSTALLATION_PATH}" "${OC_DATA_PATH}" 2>stderr.txt)
  stderr=$(cat stderr.txt)

  echo "${stdout}" >> "${OC_BACKUP_LOG_DESTINATION}/${time_stamp}_log.txt"
  log "${stderr}"

  if [ "${#stderr}" -gt 0 ]; then
    log "Error: Zip creation failed."
    errors_found=$((errors_found + 1))
  fi

  echo "" >stderr.txt
}

create_database_backup() {
  log "-> Create database backup..."

  stdout=$(pg_dump -U "${OC_DB_USER}" -h "${OC_DB_HOST}" -p "${OC_DB_PORT}" "${OC_DB_NAME}" >"${OC_DATABASE_BACKUP_DESTINATION}/${time_stamp}_${OCB_TYPE}.dump" 2> stderr.txt)
  stderr=$(cat stderr.txt)

  log "${stdout}"
  log "${stderr}"

  if [ "${#stderr}" -gt 0 ]; then
    if ! [[ "${stderr}" =~ ^pg_dump:[[:space:]]\[Warning\] ]]; then
      log "Error: Postgresql backup failed."
      log "_${stderr}_"
      errors_found=$((errors_found + 1))
    fi
  fi

  echo "" > stderr.txt
}

delete_config_backup_file() {
  log "-> Delete config backup file..."

  backupFile="${OC_INSTALLATION_PATH}/config.php.back"

  stdout=$(rm "${backupFile}")
  stderr=$(cat stderr.txt)

  log "${stdout}"
  log "${stderr}"

  if [ "${#stderr}" -gt 0 ] ; then
    log "Error: Deletion of config backup file failed."
    errors_found=$((errors_found + 1))
  fi

  echo "" > stderr.txt
}

backup_config_file() {
  log "-> Backup ${OCB_TYPE} configuration file..."

  stdout=$(cp "${configPath}" "${configPath}.back" 2>stderr.txt)
  stderr=$(cat stderr.txt)

  log "${stdout}"
  log "${stderr}"

  if [ "${#stderr}" -gt 0 ] ; then
    log "Error: Backup of config file failed."
    errors_found=$((errors_found + 1))
  fi

  echo "" >stderr.txt
}

get_current_timestamp() {
  date "+%Y-%m-%d_%H-%M-%S"
}

doBackup() {

  configPath="${OC_INSTALLATION_PATH}/config.php"
  backup_config_file

  log "-> Read ${OCB_TYPE} configuration file..."
  configFile=$(<"${configPath}")

  enable_maintenance_mode
  restart_owncloud_instance

  if [ ! -d "${OC_DATA_BACKUP_DESTINATION}" ]; then
    log "-> Create data backup folder"
    mkdir "${OC_DATA_BACKUP_DESTINATION}" &>/dev/null
  else
    log "-> Data backup folder aleady exists"
  fi

  if [ ! -d "${OC_DATABASE_BACKUP_DESTINATION}" ]; then
    log "-> Create database_backup folder"
    mkdir "${OC_DATABASE_BACKUP_DESTINATION}" &>/dev/null
  else
    log "-> Database backup folder aleady exists"
  fi

  create_database_backup
  create_data_config_zip_backup
  delete_config_backup_file
  
  disable_maintenance_mode
  restart_owncloud_instance

  duration=$SECONDS
  log "-> Finished after $(($duration / 60)) minutes with ${errors_found} errors."
}

cleanup() {
  rm stderr.txt &>/dev/null
}

showHelp() {
  echo "oc-backup v${OCB_VERSION}"
  echo "usage: ./oc_backup [options]"
  echo ""
  echo "options:"
  echo "  -c|--conf"
  echo "    path to oc_backup.conf file. Use absolute path for use in cronjob."
  echo "  -h|--help"
  echo "    show help."
}
# FUNCTIONS END

if [ "${show_help}" = false ]; then
  log "Start oc-backup v${OCB_VERSION}..."

  check_available_commands
  check_config

  if [ "${cmd_zip_exists}" = true ] && [ "${cmd_pg_dump_exists}" = true ]; then
    if [ "${is_config_valid}" = true ]; then
      doBackup
    else
      echo "OC Backup Error: Invalid config file. Missing constants: ${missing_constants}."
    fi
  else
    output="OC Backup Error: can not start backup, because of missing commands ("

    if [ "${cmd_zip_exists}" != true ]; then
      output="${output}zip"
    fi

    if [ "${cmd_pg_dump_exists}" != true ]; then
      if [ "${cmd_zip_exists}" != true ]; then
        output="${output}, "
      fi

      output="${output}pg_dump"
    fi

    echo "${output})."
  fi

  cleanup
else
  showHelp
fi