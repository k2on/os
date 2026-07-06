default:
  @just --list

list:
  @just --list

add-secrets:
  git -C secrets add .

rebuild:
  just add-secrets

  git add .
  sudo nixos-rebuild switch --flake '.?submodules=1#koonMax'

rebuild-boot:
  just add-secrets

  git add .
  sudo nixos-rebuild boot --flake '.?submodules=1#koonMax'

rebuild-offline:
  just add-secrets

  git add .
  sudo nixos-rebuild switch --flake '.?submodules=1#koonMax' --offline

rebuild-ark:
  just add-secrets

  git add .
  nixos-rebuild --flake '.?submodules=1#ark' --build-host ark --target-host ark --use-remote-sudo --fast switch


rebuild-ark-boot:
  just add-secrets

  git add .
  nixos-rebuild --flake '.?submodules=1#ark' --build-host ark --target-host ark --use-remote-sudo --fast boot

push-secrets:
  just add-secrets

  git -C secrets commit
  git -C secrets push

push:
  git add .
  git commit
  git push
