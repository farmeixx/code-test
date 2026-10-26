# channel — builder local (somente compilacao local)

Camada **full sh** para construir o kernel mainline e os rootfs do
[farmeixx/channel-rootfs](https://github.com/farmeixx/channel-rootfs) na sua
propria maquina, em qualquer **distro com apt** em **x86_64** (no Windows:
WSL2). Sem Actions, sem CI, sem validacoes: **duas camadas** —

- **local** (`sh/`): fila de comandos, confs e helpers; decide **tudo**;
- **mirror** (`recipes/`): builders do channel-rootfs vendored como **fork
  com patches** — so passos funcionais (proveniencia e patches em
  `recipes/.vendored-from`).

Toda customizacao mora em **4 confs**; os scripts consomem o que esta la.
Nao existe guard: se algo quebrar, quebra alto no log do run.

## Compilar

```sh
bash sh/build.sh kernel              # compila o mainline (checkpoint + modulos)
bash sh/build.sh ubuntu              # monta o rootfs do checkpoint (alpine|debian|ubuntu)
bash sh/build.sh all                 # kernel uma vez + DISTROS do rootfs.conf
bash sh/build.sh status              # reporte local (kernel, modulos, ccache, imagens)
bash sh/build.sh help
```

1. **kernel** (`sh/mainline/build.sh`): deps naturais via apt
   (`recipes/main/sh/deps.sh`: gcc-aarch64 cross, ccache, dtc, zstd...),
   clone do kernel uma vez em `sources/linux` (GitLab `msm8953/latest`,
   persistente), fragments + simbolos (`KERNEL_ENABLE_*`) + label via
   scripts/config, compilacao com ccache persistente, empacotamento do
   `boot-channel.img` com mkbootimg fixado (AOSP, commit fixado).
   Publica `cache/mainline/checkpoint/` + copia datada em `build/mainline/`.
   `--reuse` reporta o checkpoint existente sem compilar.
2. **rootfs** (`sh/rootfs/build.sh <distro>`): nunca recompila o kernel; usa
   checkpoint + modulos de `cache/mainline/`, instala o firmware do device
   (clona o `channel-firmware` do GitLab; offline, aponte
   `FIRMWARE_SOURCE_DIR` para uma copia local), gera o builder cru da distro
   via `sh/lib/raw-rootfs-builder.py` e monta o rootfs em
   `build/rootfs/<distro>/<distro>-STAMP.ext4` + boot.img correspondente.
3. **all**: kernel uma vez + cada distro de `DISTROS`.

## Os 4 confs (a API de customizacao)

| arquivo | chaves | efeito |
|---|---|---|
| `conf/device.conf` | `DEVICE` | nome do device (paths, builds, metadados) |
| `conf/build.conf` | `JOBS` (vazio = nproc), `CCACHE_MAXSIZE`, `CCACHE_COMPRESS`, `MODULES_ARCHIVE_BASE` | paralelismo, cache C, nome base do tar de modulos |
| `conf/kernel.conf` | `KERNEL_LOCALVERSION` | label exata do release; aplicada com `CONFIG_LOCALVERSION_AUTO` off (deterministica) |
| `conf/rootfs.conf` | `IMAGE_SIZE_MB`, `IMAGE_FREE_MIN_ALPINE`, `IMAGE_FREE_MIN_DEBIAN_UBUNTU`, `DISTROS` | tamanho do ext4 cru, minimos livres, ordem do `all` |

A configuracao de device kernel vive em `recipes/main/conf/mainline.conf`
(`KERNEL_MAINLINE_CONF` sobrepoe o caminho), firmware em
`recipes/rootfs/conf/firmware.conf` (`FIRMWARE_CONFIG` sobrepoe), USB/rede
em `recipes/rootfs/conf/usb.conf`.

Ritual de bump de label: mude `KERNEL_LOCALVERSION` em `conf/kernel.conf`,
recompile. O release sai byte-exato com o conf.

## Atualizar o kernel (manual)

O git e o estado sao seus: atualize o checkout quando quiser e recompile.

```sh
git -C sources/linux pull --ff-only
```

(mkbootimg fica fixado no commit de `mainline.conf`.)

## Mirror vendored

`recipes/` e um fork do channel-rootfs retido no repo: logs (`ui_step`/`ui.sh`),
wrappers e validacoes removidos; `build.sh` do kernel le `KERNEL_LOCALVERSION`
e `MODULES_ARCHIVE_BASE` do conf local; `firmware.sh` e installer puro (o
firmware em si agora e clonado do GitLab em tempo de build, para dentro de
`recipes/rootfs/.work/`, ignorado pelo git). Atualizacao do upstream e manual
(clone novo + re-aplica o shape) e registra SHAs em `recipes/.vendored-from`.

## Diretorios

```text
sh/build.sh          entry point (kernel|distro|all|status|help)
sh/mainline/         estagio de kernel
sh/rootfs/           estagio de rootfs (um script, tres distros)
sh/lib/              helpers + gerador raw rootfs (python3)
recipes/             builders vendored (fork com patches)
conf/                os 4 confs
sources/linux/       clone mainline msm8953/latest (persistente)
sources/mkbootimg/   clone AOSP mkbootimg com commit fixado
cache/mainline/      checkpoint + modulos + ccache
build/mainline/      IMG/DTB/config/modules datados
build/rootfs/<d>/    EXT4 cru + build-info + boot.img
```

## Requisitos

- Distro **apt** x86_64 (ou WSL2 Ubuntu); chain e x86_64.
- sudo com senha (root em container tambem funciona: `sudo` e instalado se faltar).
- Internet na primeira compilacao (fontes + pacotes + firmware do device
  clonado do GitLab; scripts vendored no repo) e uns **10+ GB livres**.
- A primeira compilacao demora (mitigada por ccache + fontes persistentes);
  rootfs seguintes reusam checkpoint e modulos sem recompilar kernel.
- O `boot.img` Android grava via fastboot; nunca como ext4 dd.
