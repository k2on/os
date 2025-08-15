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

