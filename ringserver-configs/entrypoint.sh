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
  cp -r /app/ring "${ring_dir}"
fi

if [[ ! -d "${auth_dir}" ]]; then
  echo "Initializing auth directory..."
  cp -r /app/auth "${auth_dir}"
fi

# Compose variants use distinct private subnets. Keep the trusted monitoring
# client explicit instead of trusting an entire Docker range.
if [[ -n "${RINGSERVER_TRUSTED_IPS:-}" ]]; then
  IFS=',' read -r -a trusted_ips <<< "${RINGSERVER_TRUSTED_IPS}"
  for trusted_ip in "${trusted_ips[@]}"; do
    trusted_ip="${trusted_ip//[[:space:]]/}"
    [[ -z "${trusted_ip}" ]] && continue
    if ! grep -Fq "TrustedIP ${trusted_ip}" "${ring_conf_file}"; then
      printf '\nTrustedIP %s # Compose monitoring backend\n' "${trusted_ip}" >> "${ring_conf_file}"
    fi
  done
fi

echo "Configuration files and directories initialized."

# Run ringserver
/app/ringserver -vv "${ring_conf_file}"
