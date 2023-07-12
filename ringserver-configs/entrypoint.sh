#!/bin/bash

config_dir="/app/host-configs"
ring_conf_file="${config_dir}/ring.conf"
ring_dir="${config_dir}/ring"
auth_dir="${config_dir}/auth"

# Check if the necessary files and directories exist
if [[ ! -f "${ring_conf_file}" && ! -d "${ring_dir}" && ! -d "${auth_dir}" ]]; then
  echo "Initializing configuration files and directories..."
  mkdir -p "${config_dir}"
  mv /app/ring.conf "${ring_conf_file}"
  mv /app/ring "${ring_dir}"
  mv /app/auth "${auth_dir}"

  # Modify ring.conf file
  sed -i 's#RingDirectory ring#RingDirectory host-configs/ring#' "${ring_conf_file}"
  sed -i 's#AuthDir auth#AuthDir host-configs/auth#' "${ring_conf_file}"
fi

# Run ringserver
/app/ringserver -vv "${ring_conf_file}"

