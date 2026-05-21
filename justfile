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
  nixos-rebuild --flake '.?submodules=1#ark' --build-host admin@192.168.1.192 --target-host admin@192.168.1.192 --use-remote-sudo --fast switch

push-secrets:
  just add-secrets

  git -C secrets commit
  git -C secrets push

push:
  git add .
  git commit
  git push
