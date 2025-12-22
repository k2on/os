default:
  @just --list

list:
  @just --list

add-secrets:
  git -C secrets add .

rebuild:
  just add-secrets

  git add .
  sudo nixos-rebuild switch --flake '.?submodules=1#max'

rebuild-offline:
  just add-secrets

  git add .
  sudo nixos-rebuild switch --flake '.?submodules=1#max' --offline

rebuild-ark:
  just add-secrets

  git add .
  nixos-rebuild --flake '.?submodules=1#ark' --build-host admin@100.98.252.15 --target-host admin@100.98.252.15 --use-remote-sudo --fast switch

push-secrets:
  just add-secrets

  git -C secrets commit
  git -C secrets push

push:
  git add .
  git commit
  git push
