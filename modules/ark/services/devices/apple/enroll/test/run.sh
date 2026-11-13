# apple-enroll end to end: a MachineInfo signed as a device signs it,
# POSTed the way Setup Assistant does. Run by ../_check.nix.
set -euo pipefail
cd "$TMPDIR"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=device \
  -keyout device.key -out device.crt 2>/dev/null
info() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n\t<key>SERIAL</key>\n\t<string>%s</string>\n\t<key>UDID</key>\n\t<string>00008130-0000000000000000</string>\n</dict>\n</plist>\n' "$1" \
    | openssl cms -sign -nodetach -binary -outform DER -signer device.crt -inkey device.key -out "$2"
}
info KN2QHVKC9J declared.der
info ZZZZZZZZZZ stranger.der

echo "the profile" > profile
printf '# a comment\nkn2qhvkc9j\n\n' > serials

apple-enroll 127.0.0.1:18080 profile serials &
for _ in $(seq 50); do curl -s 127.0.0.1:18080 >/dev/null && break; sleep 0.1; done

post() {
  curl -s -o body -w '%{http_code}' -X POST \
    -H 'Content-Type: application/pkcs7-signature' --data-binary "@$1" 127.0.0.1:18080/enroll
}
expect() {
  if [ "$2" != "$3" ]; then echo "FAIL $1: got $2, wanted $3"; exit 1; fi
  echo "ok   $1"
}

expect "declared serial gets the profile" "$(post declared.der)" 200
expect "  and it is the profile" "$(cat body)" "the profile"
expect "undeclared serial refused" "$(post stranger.der)" 403
echo junk > junk
expect "unsigned body refused" "$(post junk)" 400
expect "GET refused" "$(curl -s -o /dev/null -w '%{http_code}' 127.0.0.1:18080/enroll)" 405

# The serials are read per request: one added is let in without a restart.
echo zzzzzzzzzz >> serials
expect "serial added while running" "$(post stranger.der)" 200
