#!/bin/bash
#
# BASH Shell script to flash a Sonoff MINI with Tasmota Over The Air.
#

FIRMWARE_URL="http://sonoff-ota.aelius.com/tasmota-latest-lite.bin"
SHA256SUM="5c1aecd2a19a49ae1bec0c863f69b83ef40812145c8392eebe5fd2677a6250cc"
IPADDRESS=
DEVICEID=

# JSON Pretty Print by Evgeny Karpov
# https://stackoverflow.com/a/38607019/1156096
json_pretty_print() {
  grep -Eo '"[^"]*" *(: *([0-9]*|"[^"]*")[^{}\["]*|,)?|[^"\]\[\}\{]*|\{|\},?|\[|\],?|[0-9 ]*,?' | \
  awk '{if ($0 ~ /^[}\]]/ ) offset-=4; printf "%*c%s\n", offset, " ", $0; if ($0 ~ /^[{\[]/) offset+=4}'
}

sonoff_http_request() {
  local path="${1}"
  local body="${2:-}"
  local url="http://${IPADDRESS}:8081/zeroconf/${path}"

  if [ -z "${body}" ]; then
    body="{\"deviceid\":\"${DEVICEID}\",\"data\":{}}"
  fi

  echo "Sending request to: ${url}"
  echo "Request body: ${body}"

  cmd=('curl' '--silent' '--show-error')
  cmd+=('-XPOST')
  cmd+=('--header' "Content-Type: application/json")
  cmd+=('--data-raw' "${body}")
  cmd+=("${url}")

  output=$("${cmd[@]}")
  exit_code=$?

  if [ "$exit_code" -ne 0 ]; then
    echo "Error posting to: ${url}"
    echo "${output}"
    exit $exit_code
  fi

  echo "Response: ${output}"
  echo "${output}" | json_pretty_print
  sleep 1
}

lookup_ip_address() {
  local hostname="${1}"
  if command -v dscacheutil &> /dev/null; then
    dscacheutil -q host -a name "${hostname}" | grep -m 1 'ip_address:' | awk '{print $2}'
  elif command -v getent &> /dev/null; then
    getent ahostsv4 "${hostname}" | grep -m 1 -oE "^([0-9]{1,3}\.){3}[0-9]{1,3}"
  else
    echo "Unable to resolve hostname to ip address: didn't find dscacheutil or getent." >&2
    exit 1
  fi
}

mdns_browse() {
  local service="${1}"
  local domain="${2:-local.}"
  if command -v dns-sd &> /dev/null; then
    output=$(expect <<-EOD
			set timeout 10
			spawn -noecho dns-sd -B ${service} ${domain}
			expect {
			  "  Add  " {exit 0}
			  timeout   {exit 1}
			  eof       {exit 2}
			  default   {exp_continue}
			}
		EOD
    )
    echo "${output}" | grep -m 1 '  Add  ' | awk '{sub("\r", "", $NF); print $NF}'
  elif command -v avahi-browse &> /dev/null; then
    avahi-browse -pt -d "${domain}" "${service}" | awk 'BEGIN {FS=";"} {if ($1=="+" && $3=="IPv4") print $4}'
  else
    echo "Unable to perform multicast DNS discovery: didn't find dns-sd or avahi-browse." >&2
    exit 1
  fi
}

discover_module() {
  echo "Searching for Sonoff module on network..."
  hostname=$(mdns_browse '_ewelink._tcp')
  if [ -z "${hostname}" ]; then
    echo "Failed to find a Sonoff module on the local network." >&2
    exit 2
  else
    echo "Found module on network."
    echo "Hostname: ${hostname}"
  fi

  DEVICEID=$(echo "${hostname}" | grep -o '100[0-9a-fA-F]\+')
  IPADDRESS=$(lookup_ip_address "${hostname}.local.")
  if [ -z "${IPADDRESS}" ]; then
    echo "Failed to resolve IP address for ${hostname}" >&2
    exit 3
  fi
  echo "IPv4 Address: ${IPADDRESS}"
  echo "Device ID: ${DEVICEID}"
  echo
}

display_info() {
  echo "Getting Module Info..."
  sonoff_http_request "info"
  echo
}

ota_unlock() {
  echo "Unlocking for OTA flashing..."
  sonoff_http_request "ota_unlock" "{\"deviceid\":\"${DEVICEID}\",\"data\":{}}"
  echo
}

ota_flash() {
  read -p "Proceed with flashing? [N/y] " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Requesting OTA flashing..."
    sonoff_http_request "ota_flash" "{\"deviceid\":\"${DEVICEID}\",\"data\":{\"downloadUrl\":\"${FIRMWARE_URL}\",\"sha256sum\":\"${SHA256SUM}\"}}"
    echo
  else
    echo "Aborting"
    exit 1
  fi
}

check_firmware_exists() {
  echo "Checking new firmware file exists"
  output=$(curl '--fail' '--silent' '--show-error' '--head' "${FIRMWARE_URL}")
  exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    if [ "$exit_code" -eq 22 ]; then
      echo "The firmware file does not exist: ${FIRMWARE_URL}" >&2
    else
      echo "There was an error checking if firmware exists: ${FIRMWARE_URL}" >&2
    fi
    exit $exit_code
  else
    echo "OK"
    echo
  fi
}

main() {
  check_firmware_exists

  if [ -z "${IPADDRESS:-}" ]; then
    discover_module
  fi

  display_info

  ota_unlock

  display_info

  ota_flash
  
  echo "Please wait for your device to finish flashing."
}

main
