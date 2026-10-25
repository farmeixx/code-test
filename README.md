# channel — builder-deb local (somente compilacao local)

Camada local **full sh** para construir o kernel mainline e os rootfs do
[farmeixx/channel-rootfs](https://github.com/farmeixx/channel-rootfs) na sua
propria maquina, em qualquer **distro com apt** (Debian, Ubuntu, Mint,
Pop!_OS, Kali, Zorin...) em **x86_64**. No Windows: **WSL2**. Sem Actions,
sem Run ID, sem cloud: clone o repo e rode um comando — as deps do host
entram pelo apt sozinhas (a conf do device vem do repo, `conf/mainline.conf`,
`conf/firmware.conf` e `conf/usb.conf`).

## Compilar

Da pasta do builder:

```sh
bash test.sh                        # auto-teste da camada (parse + gates)
bash sh/build.sh kernel             # compila o mainline (perfil kernel)
bash sh/build.sh ubuntu             # monta o rootfs a partir do checkpoint
# tambem: alpine | debian | all | status | help
```

O que cada fase faz:

1. **kernel** (`sh/mainline/build.sh`): instala deps automaticas pelo
   `sh/deps.sh` do repo (perfil kernel: gcc-aarch64 cross, ccache,
   device-tree-compiler, zstd...), clona o kernel (GitLab `msm8953/latest`) **uma vez** (persistente em
   `sources/linux`), aplica a conf nova do repo (fragments, simbolos y/m
   exigidos, DTB, boot e cmdline), compila com ccache persistente, empacota
   o `boot-channel.img` com mkbootimg fixado, desempacota pra conferir o
   payload byte-a-byte, valida o checkpoint completo e publica em
   `cache/mainline/checkpoint/` + copia datada em `build/mainline/`.
   `--reuse` usa o checkpoint pronto sem compilar.
2. **alpine|debian|ubuntu** (`sh/rootfs/<distro>.sh`): valida o checkpoint
   (basico cedo, completo depois + vermagic), verifica o firmware do device
   (vendored no repo, sem rede), instala deps do perfil, gera uma **copia
   crua redimensionada** do builder upstream via `sh/lib/raw-rootfs-builder.py`
   (sentinels versionados: nada editado silenciosamente) e monta o rootfs
   **1024 MiB ext4 sem compressao**, com SHA256, blkid, e2fsck e metadados
   conferidos. Publica `build/rootfs/<distro>/<distro>-STAMP.ext4`.
3. **all**: kernel uma vez + os tres rootfs, sequencial.
4. **status**: relatorio local (checkpoint, modulos, ccache, imagens prontas).

## Diretorios

```text
sh/mainline/       scripts de kernel
sh/rootfs/         scripts de Alpine, Debian e Ubuntu
sh/lib/            helpers commons + gerador raw (python3)
recipes/           builders upstream VENDORED (main + rootfs), copiados
                   fixos neste repo; proveniencia em recipes/.vendored-from
sources/linux/     clone mainline msm8953/latest (persistente)
sources/mkbootimg/ clone AOSP mkbootimg com SHA fixado
cache/mainline/modules/     modulos do kernel para os rootfs
cache/mainline/checkpoint/  kernel, DTB, config e hashes verificados
cache/mainline/ccache/      cache do compilador
build/mainline/    <device>-mainline-AAAAMMDDHHMMSS.img e DTB etc
build/rootfs/<d>/  <distro>-AAAAMMDDHHMMSS.ext4 (cru)
```

## Tamanhos fixos das imagens ext4 (sem compressao)

- Alpine, Debian e Ubuntu: **1024 MiB** (alinhado com o builder upstream
  atual), minimo livre 32 MiB (Alpine) / 64 MiB (Debian e Ubuntu), inodes e
  journal conferidos na criacao (16384/8 e 32768/16).
- O build falha se a imagem nao couber; ele nao corta arquivos silenciosamente.
- O build do kernel gera um **boot.img Android**, que NAO deve ser gravado
  como ext4. Detalhes em `TAMANHOS.txt`.

## conf local (nova logica de conf)

O device inteiro vem do repo por **conf, nao por logica fixada em script**:

- Kernel: `conf/mainline.conf` do repo — `KERNEL_MAINLINE_CONF` sobrepoe o
  caminho (ponha um `.conf` seu nesta pasta `conf/` e exporte a variavel).
- Firmware: `conf/firmware.conf` do repo — `FIRMWARE_CONFIG` sobrepoe.
- USB/identidade de rede: `conf/usb.conf` do repo (usado pelos builders).

## Pin do release do kernel (conf do builder)

Alem da conf do device, o builder tambem versiona a propria identidade em
`conf/` (fail-closed):

- `conf/release.conf` — `KERNEL_RELEASE` + `KERNEL_SUFFIX` pinados (hoje
  `7.3.0-rc7-mainline`): reuse do checkpoint, pos-compilacao e status conferem
  o valor e morrem com mensagem clara em qualquer divergencia.
- `conf/modules.conf` — contrato de extracao (`MODULES_ARCHIVE`,
  `MODULES_TARGET`, `MODULES_REQUIRED`, `MODULES_SHA_MANIFEST`): os modulos
  sao conferidos no tar antes de montar qualquer rootfs.

Ritual de bump (a base msm8953/latest mudou): edita UMA linha em
`conf/release.conf` e recompila; o checkpoint antigo e recusado pelos guards
(comportamento esperado). A mesma label tambem vive vendored em
`recipes/main/conf/release-label.config` (CONFIG_LOCALVERSION="-mainline" com
LOCALVERSION_AUTO desligado) e no `KERNEL_PIN_RELEASE` de
`recipes/main/conf/mainline.conf`; quando o pin mudar no channel-rootfs,
atualize as copias vendored (a proveniencia fica em `recipes/.vendored-from`),
confirme as duas fontes e recompile: o build sai deterministicamente com o
release pinado e o pin local so confirma.

## Requisitos

- Distro **apt** em x86_64 (Debian/Ubuntu nativo, Mint/Pop!_OS/Kali/Zorin/
  etc. ou WSL2 Ubuntu); o chain e x86_64 preciso.
- sudo com senha uma vez em usuario normal; root em container funciona (a
  camada instala o `sudo` sozinha se faltar, porque os scripts vendored
  chamam sudo direto).
- Internet na primeira compilacao (fontes + pacotes; scripts e firmware do
  device vem vendored no repo) e uns **10+ GB livres**
  (.work/sources/cache/build).
- A primeira compilacao de kernel demora (compilacao real, mitigada pelo
  ccache + fontes persistentes); rootfs seguintes reutilizam checkpoint e
  modulos sem recompilar.

## Testado

- Auto-teste `bash test.sh` (sintaxe bash de todos os scripts vendored e
  locais, gates de erro, recipes vendored completos, status sem
  host-dependencia).
- GitHub **Codespace** (Ubuntu x86_64 sandbox): teste completo + `--reuse`
  reportando checkpoint ausente de forma limpa, tudo sem rede para os scripts.
- Builds de verdade (kernel/rootfs) rodam na SUA maquina Linux, nunca aqui.
- Nenhuma branch ou workflow do GitHub e modificado.
