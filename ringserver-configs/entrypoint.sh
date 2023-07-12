#!/bin/bash

config_dir="/app/host-configs"
ring_conf_file="${config_dir}/ring.conf"
ring_dir="${config_dir}/ring"
auth_dir="${config_dir}/auth"

# Check if the necessary files and directories exist
if [[ ! -f "${ring_conf_file}" ]]; then
  echo "Initializing ring.conf file..."
  cp /app/ring.conf "${ring_conf_file}"

  # Modify ring.conf file (since dirs are moved)
  sed -i 's#RingDirectory ring#RingDirectory host-configs/ring#' "${ring_conf_file}"
  sed -i 's#AuthDir auth#AuthDir host-configs/auth#' "${ring_conf_file}"

fi

if [[ ! -d "${ring_dir}" ]]; then
  echo "Initializing ring directory..."
  cp /app/ring "${ring_dir}"
fi

if [[ ! -d "${auth_dir}" ]]; then
  echo "Initializing auth directory..."
  cp /app/auth "${auth_dir}"
fi

echo "Configuration files and directories initialized."

# Run ringserver
/app/ringserver -vv "${ring_conf_file}"

