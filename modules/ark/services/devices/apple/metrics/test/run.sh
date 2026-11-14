# apple-devices-metrics end to end: nanohub's and NanoDEP's APIs as static
# files (busybox httpd), a real push certificate and content token, and a
# device's answer through the webhook. Run by ../_metrics-check.nix.
set -euo pipefail
cd "$TMPDIR"

mkdir -p api/api/v1/ddm/declaration-status api/api/v1/ddm/status-values api/v1/tokens out
cat > api/api/v1/ddm/declaration-status/UDID-1 <<'J'
{"UDID-1":[{"identifier":"us.koon.devices.status","active":true,"valid":"valid"},
           {"identifier":"us.koon.devices.app.signal","active":false,"valid":"invalid"}]}
J
cat > api/api/v1/ddm/status-values/UDID-1 <<'J'
{"UDID-1":[{"path":".StatusItems.device.operating-system.version","value":"26.1","timestamp":"2026-11-14T09:00:00-06:00"},
           {"path":".StatusItems.device.model.identifier","value":"iPhone16,1","timestamp":"2026-11-14T09:00:00-06:00"}]}
J
echo '{"consumer_key":"x","access_token_expiry":"2027-11-13T19:43:06Z"}' > api/v1/tokens/abm
"$BUSYBOX" httpd -f -p 127.0.0.1:18100 -h api &

openssl req -x509 -newkey rsa:2048 -nodes -keyout /dev/null -subj "/UID=com.apple.mgmt.External.x/CN=push" \
  -days 365 -out push.pem 2>/dev/null
printf '{"token":"t","expDate":"2027-11-13T13:43:06-0600","orgName":"o"}' | base64 -w0 > content.vpptoken
echo key > key
cat > config.json <<J
{ "listen": "127.0.0.1:18101", "output": "$TMPDIR/out/apple_devices.prom",
  "nanohub": "http://127.0.0.1:18100", "nanohubKey": "$TMPDIR/key",
  "depserver": "http://127.0.0.1:18100", "depserverKey": "$TMPDIR/key", "depNames": ["abm"],
  "pushCert": "$TMPDIR/push.pem", "vppToken": "$TMPDIR/content.vpptoken",
  "devices": [{ "name": "max-iphone", "udid": "UDID-1", "owner": "max" }],
  "refresh": 1, "query": 3600 }
J
apple-devices-metrics config.json &
for _ in $(seq 50); do [ -s out/apple_devices.prom ] && break; sleep 0.2; done

# The device answers DeviceInformation, through nanohub's webhook.
answer=$(printf '<plist><dict><key>QueryResponses</key><dict><key>BatteryLevel</key><real>0.5</real><key>AvailableDeviceCapacity</key><real>40.5</real><key>DeviceCapacity</key><real>128</real></dict><key>Status</key><string>Acknowledged</string></dict></plist>' | base64 -w0)
printf '{"topic":"mdm.Connect","acknowledge_event":{"udid":"UDID-1","status":"Acknowledged","raw_payload":"%s"}}' "$answer" \
  | curl -fsS -X POST --data-binary @- 127.0.0.1:18101/webhook
for _ in $(seq 50); do grep -q "^apple_device_battery_level_ratio{" out/apple_devices.prom && break; sleep 0.2; done

m=out/apple_devices.prom
expect() {
  if ! grep -qF -- "$2" "$m"; then echo "FAIL $1: no $2 in"; cat "$m"; exit 1; fi
  echo "ok   $1"
}
expect "push certificate expiry" "apple_mdm_push_certificate_expiry_timestamp_seconds $(date -d "$(openssl x509 -noout -enddate -in push.pem | cut -d= -f2)" +%s)"
expect "content token expiry" "apple_vpp_token_expiry_timestamp_seconds $(date -d 2027-11-13T19:43:06Z +%s)"
expect "ABM token expiry" "apple_abm_token_expiry_timestamp_seconds{name=\"abm\"} $(date -d 2027-11-13T19:43:06Z +%s)"
expect "device up" 'apple_device_up{device="max-iphone",owner="max"} 1'
expect "its model and OS" 'apple_device_info{device="max-iphone",owner="max",os_version="26.1",model="iPhone16,1"} 1'
expect "a failing declaration" 'apple_device_declaration_valid{device="max-iphone",owner="max",declaration="us.koon.devices.app.signal"} 0'
expect "last report" "apple_device_last_report_timestamp_seconds{device=\"max-iphone\",owner=\"max\"} $(date -d 2026-11-14T15:00:00Z +%s)"
expect "battery" 'apple_device_battery_level_ratio{device="max-iphone",owner="max"} 0.5'
expect "free storage" 'apple_device_storage_available_bytes{device="max-iphone",owner="max"} 40500000000'
expect "no errors" "apple_devices_metrics_errors 0"
