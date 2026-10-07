<p align="center">
<img height="400px" src="https://imgur.com/HgmQVZD.jpg" />
<br>
<br>
<b style="text-size: 30px">Koon Family OS</b>
<br>
</p>

## Post Clone

When cloning the repo, you have to initalize the secrets submodule.

```
git submodule update --init secrets
```

## Secrets

The `secrets/` submodule is also a module root: `secrets/ark.nix` holds
the people side (persons, per-service `members`/`admin` groups, the
identity provider name, the admin age key).

Services declare what they need under the `secrets` quirk (see
`modules/ark/lib/secrets.nix`). Whatever is declared but not yet in
`secrets/vars/` is created by:

```sh
ark secrets
```

Generated secrets (OIDC client secrets, tokens) are filled in for you,
the rest are prompted for. `ark secrets --dry-run` only lists what is
missing or needs rekeying. A host whose secret file is missing refuses to
build until this has been run and committed in the secrets repo.

Creating secrets needs no key. Whenever something has to be decrypted,
`ark` asks the yubikey for its identity and, if it is not plugged in, asks
you to plug it in; the dev shell itself works without it. To run sops by
hand with that identity: `ark sops <file>.yaml` (in `secrets/vars`).

Provider API tokens (Hetzner, Cloudflare, Porkbun) use the same `secrets`
key on their provider aspect. They share one admin-only file,
`secrets/vars/infra.yaml`, which `ark plan`, `ark push` and `ark destroy`
decrypt once into their environment; they refuse to run if a token is
missing from it.

## Tailnet

Every host, and the sivrad VM, is a node of the headscale tailnet
(`modules/ark/services/headscale/default.nix`), and joins at boot with no
secret in the repo: headscale's host mints a pre-auth key per node,
encrypts it to the node's age recipient (its ed25519 ssh host key, the
`ark.hostKey` sops needs anyway) and serves the ciphertext; the node
fetches and decrypts it with that key. A VM's key is encrypted to its
host, which hands it in (adam does for sivrad). Nothing is ordered: a node
whose key is not served yet keeps trying and joins once the vps is
deployed. A new host is on the tailnet once its recipient is in the config
(`ssh-to-age < /etc/ssh/ssh_host_ed25519_key.pub` after its first boot).
To throw a node out: `headscale preauthkeys expire --id $(cat
/var/lib/tailnet-keys/<node>.id)` on the vps, and a new key is minted
there when the node's recipient changes.

## Deploy

### Ark

```sh
nix-shell -p neofetch --run "neofetch"
          ▗▄▄▄       ▗▄▄▄▄    ▄▄▄▖            admin@ark
          ▜███▙       ▜███▙  ▟███▛            ---------
           ▜███▙       ▜███▙▟███▛             OS: NixOS 25.11.20250806.c2ae88e (Xantusia) x86_64
            ▜███▙       ▜██████▛              Host: HP 829A
     ▟█████████████████▙ ▜████▛     ▟▙        Kernel: 6.12.40
    ▟███████████████████▙ ▜███▙    ▟██▙       Uptime: 12 days, 1 hour, 39 mins
           ▄▄▄▄▖           ▜███▙  ▟███▛       Packages: 373 (nix-system), 111 (nix-user)
          ▟███▛             ▜██▛ ▟███▛        Shell: bash 5.3.0
         ▟███▛               ▜▛ ▟███▛         Terminal: /dev/pts/0
▟███████████▛                  ▟██████████▙   CPU: Intel i5-6500T (4) @ 3.100GHz
▜██████████▛                  ▟███████████▛   GPU: Intel HD Graphics 530
      ▟███▛ ▟▙               ▟███▛            Memory: 2259MiB / 7818MiB
     ▟███▛ ▟██▙             ▟███▛
    ▟███▛  ▜███▙           ▝▀▀▀▀
    ▜██▛    ▜███▙ ▜██████████████████▛
     ▜▛     ▟████▙ ▜████████████████▛
           ▟██████▙       ▜███▙
          ▟███▛▜███▙       ▜███▙
         ▟███▛  ▜███▙       ▜███▙
         ▝▀▀▀    ▀▀▀▀▘       ▀▀▀▘
```

```sh
just rebuild-ark
```

### Max's Laptop

```sh
nix-shell -p neofetch --run "neofetch"
          ▗▄▄▄       ▗▄▄▄▄    ▄▄▄▖            max@nixos
          ▜███▙       ▜███▙  ▟███▛            ---------
           ▜███▙       ▜███▙▟███▛             OS: NixOS 25.05.20250807.e728d7a (Warbler) aarch64
            ▜███▙       ▜██████▛              Host: Apple MacBook Pro (14-inch, M2 Pro, 2023)
     ▟█████████████████▙ ▜████▛     ▟▙        Kernel: 6.14.8-asahi
    ▟███████████████████▙ ▜███▙    ▟██▙       Uptime: 3 days, 2 hours, 11 mins
           ▄▄▄▄▖           ▜███▙  ▟███▛       Packages: 1936 (nix-system), 1277 (nix-user)
          ▟███▛             ▜██▛ ▟███▛        Shell: bash 5.2.37
         ▟███▛               ▜▛ ▟███▛         Resolution: 3024x1890
▟███████████▛                  ▟██████████▙   DE: Plasma 6.3.6 (Wayland)
▜██████████▛                  ▟███████████▛   WM: kwin
      ▟███▛ ▟▙               ▟███▛            Icons: breeze [GTK2/3]
     ▟███▛ ▟██▙             ▟███▛             Terminal: alacritty
    ▟███▛  ▜███▙           ▝▀▀▀▀              CPU: (12) @ 2.424GHz
    ▜██▛    ▜███▙ ▜██████████████████▛        Memory: 10290MiB / 15424MiB
     ▜▛     ▟████▙ ▜████████████████▛
           ▟██████▙       ▜███▙
          ▟███▛▜███▙       ▜███▙
         ▟███▛  ▜███▙       ▜███▙
         ▝▀▀▀    ▀▀▀▀▘       ▀▀▀▘
```

```sh
just rebuild
```


## Services from the laptop

`ark` is installed on the laptop by the `arkCli` home module (modules/ark/lib/cli.nix),
which also gives zsh tab completion for every command, down to the linked
banks. `ark service <name> <command>` runs a service's own commands here,
against the repo, so a service can be set up before its host is even deployed. Each
service that has some ships them in `modules/ark/services/<name>/cli/mod.rs`
(Rust, compiled into `ark`; `ark help` lists them). For example, money:

```sh
ark service money link chase   # connect a bank through Plaid; saves
                               # secrets/services/money/links/chase.nix and the
                               # money_plaid_chase secret, then asks which
                               # accounts should show up in Actual
ark service money select chase # change that choice
ark service money accounts     # what is linked and what syncs
ark service money sync         # import now, on the host, and show the log
```

The budget itself is run the same way: `budget` (the month, `budget set
Groceries 450`), `categories` / `category add Bills Internet`, `transactions
--uncategorized`, `categorize Groceries 3f9a`, `spending --by payee`,
`payees`, `rules` / `rule add Groceries --contains COSTCO`, `balances`.
`ark service money --help` has the whole list; each runs one operation on
the host over ssh through Actual's official client library.

Commands that reach a host find it through `ark hosts`: which host runs
which service (from the `service-<name>` aspects it includes) and how to
ssh to it (its sudo user at its tailnet name), all derived from the nix
config.
