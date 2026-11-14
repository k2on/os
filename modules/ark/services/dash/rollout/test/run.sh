# ark-rollout end to end, with git and nix stood in for: main moves, the
# host list and each host's system are "evaluated", one host fails.
# Run by ../_rollout-check.nix.
set -euo pipefail
cd "$TMPDIR"
mkdir -p bin
echo 1111111111111111111111111111111111111111 > head
printf '#!%s\n' "$(command -v bash)" > bin/git
cat >> bin/git <<'S'
[ "$1" = ls-remote ] && printf '%s\trefs/heads/main\n' "$(cat "$TMPDIR/head")"
S
printf '#!%s\n' "$(command -v bash)" > bin/nix
cat >> bin/nix <<'S'
case "$*" in
  *arkHosts*) printf 'adam\nbenj' ;;
  *nixosConfigurations.adam.*) rev=$(echo "$*" | sed -n 's/.*rev=\([0-9a-f]*\).*/\1/p'); printf '/nix/store/%s-adam' "${rev:0:4}" ;;
  *nixosConfigurations.benj.*) echo "warning: noise" >&2; echo "error: attribute 'x' missing" >&2; exit 1 ;;
esac
S
chmod +x bin/*
export PATH=$TMPDIR/bin:$PATH

ark-rollout https://git.example/os.git out.prom 1 &
until grep -q 'ark_rollout_evaluated{commit="1111111111111111111111111111111111111111"} 1' out.prom 2>/dev/null; do sleep 0.2; done

expect() {
  if ! grep -qF -- "$2" out.prom; then echo "FAIL $1: no $2 in"; cat out.prom; exit 1; fi
  echo "ok   $1"
}
expect "adam's system" 'ark_rollout_expected_system{commit="1111111111111111111111111111111111111111",target_host="adam",path="/nix/store/1111-adam"} 1'
expect "benj fails, with nix's last line" "ark_rollout_eval_failed{commit=\"1111111111111111111111111111111111111111\",target_host=\"benj\",error=\"nix eval benj failed: error: attribute 'x' missing\"} 1"

# main moves: the new commit is evaluated in its place.
echo 2222222222222222222222222222222222222222 > head
until grep -q 'ark_rollout_evaluated{commit="2222222222222222222222222222222222222222"} 1' out.prom; do sleep 0.2; done
expect "the new commit's system" 'path="/nix/store/2222-adam"'
if grep -q 1111111111111111111111111111111111111111 out.prom; then echo "FAIL the old commit is still there"; exit 1; fi
echo "ok   only the newest commit"
