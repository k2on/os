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

# ark builds its own system: 4 cores, 8 GB and no swap, most of it in use.
# One build job on two cores keeps a large build (the Hermes Python tree)
# from thrashing the host into silence; adam's nix.settings say the same
# for builds started there.
rebuild-ark:
  just add-secrets

  git add .
  nixos-rebuild --flake '.?submodules=1#adam' --build-host admin@ark --target-host admin@ark --use-remote-sudo --fast --max-jobs 1 --cores 2 switch


rebuild-ark-boot:
  just add-secrets

  git add .
  nixos-rebuild --flake '.?submodules=1#adam' --build-host admin@10.0.0.28 --target-host admin@10.0.0.28 --use-remote-sudo --fast boot

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

# ephr (the backup server) builds its own system from its own store; its
# admin needs a password for sudo.
rebuild-ephr:
  git add .
  nixos-rebuild --flake '.?submodules=1#ephr' --build-host admin@ephr --target-host admin@ephr --sudo --ask-sudo-password --fast switch

push-secrets:
  just add-secrets

  git -C secrets commit
  git -C secrets push

push:
  git add .
  git commit
  git push
