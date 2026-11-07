default:
  @just --list

list:
  @just --list

add-secrets:
  git -C secrets add .

rebuild:
  just add-secrets

  git add .
  sudo nixos-rebuild switch --flake '.?submodules=1#cale'

rebuild-boot:
  just add-secrets

  git add .
  sudo nixos-rebuild boot --flake '.?submodules=1#cale'

rebuild-offline:
  just add-secrets

  git add .
  sudo nixos-rebuild switch --flake '.?submodules=1#cale' --offline

# comin deploys every host from main (modules/aspects/deploy.nix). By hand,
# for when comin itself is broken: the host builds and switches its own
# system, with you signed in (sudo asks for your Kanidm POSIX password).
#
# Deploy one host by hand
deploy host:
  git add .
  nixos-rebuild --flake '.?submodules=1#{{host}}' --build-host {{host}} --target-host {{host}} --sudo --ask-sudo-password --fast switch

# comin there switches with `switch-to-configuration test`, so a reboot goes
# back to main. HEAD must be on top of main, and signed like any commit comin
# deploys.
#
# Try HEAD on one host before main
try host:
  git push --force origin HEAD:refs/heads/testing-{{host}}

# comin follows main again once testing-<host> is gone.
#
# Put one host back on main
untry host:
  git push origin --delete testing-{{host}}

push-secrets:
  just add-secrets

  git -C secrets commit
  git -C secrets push

push:
  git add .
  git commit
  git push
