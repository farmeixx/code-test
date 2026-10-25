# channel — builder-nodepsinstall local (sem instalar dependências do host)

Camada local **full sh** para construir o kernel mainline e os rootfs do
[farmeixx/channel-rootfs](https://github.com/farmeixx/channel-rootfs) na sua
própria máquina, em **x86_64** (Debian/Ubuntu nativo, Mint/Pop!_OS/Kali,
Zorin..., ou **WSL2** no Windows). Este builder **nunca instala nada no host**:
a lista completa de pacotes está em **`REQUISITOS.txt`**, você resolve o host
com ela **antes** (um único apt), e a camada apenas **verifica** as ferramentas
(fail-closed) e aponta o que falta. Sem Actions, sem Run ID, sem cloud: clone
o repo e rode um comando — a conf do device vem do repo (`conf/mainline.conf`,
`conf/firmware.conf` e `conf/usb.conf`).

## Preparar o host (uma vez; é VOCÊ quem instala, não o builder)

```sh
sudo apt-get update
xargs sudo apt-get install -y < REQUISITOS.txt
```

`REQUISITOS.txt` cobre o perfil **kernel** (toolchain cross aarch64, ccache,
pahole/dwarves, dtc) e os perfis **rootfs** (mkfs/e2fsprogs, qemu-user-static +
binfmt, mmdebstrap/debian-archive-keyring, kmod, openssl...). Rodar as fases
sem isso falha **limpa** com a lista do que está faltando — nada é instalado
no meio do caminho.

## Compilar

Da pasta do builder:

```sh
bash test.sh                        # auto-teste da camada (parse + gates)
bash sh/sources/prepare.sh all    # (opcional) baixa as receitas main + rootfs
bash sh/build.sh kernel             # compila o mainline
bash sh/build.sh ubuntu             # monta o rootfs a partir do checkpoint
# tambem: alpine | debian | all | sources | status | help
```

O que cada fase faz:

1. **kernel** (`sh/mainline/build.sh`): verifica as ferramentas do perfil
   kernel (`command -v`, fail-closed, mensagem apontando para
   `REQUISITOS.txt` — **não instala nada**), clona o kernel (GitLab
   `msm8953/latest`) **uma vez** (persistente em `sources/linux`), aplica a
   conf nova do repo (fragments, símbolos y/m exigidos, DTB, boot e cmdline),
   compila com ccache persistente, empacota o `boot-channel.img` com mkbootimg
   fixado, desempacota pra conferir o payload byte-a-byte, valida o checkpoint
   completo e publica em `cache/mainline/checkpoint/` + cópia datada em
   `build/mainline/`. `--reuse` usa o checkpoint pronto sem compilar (não
   exige a toolchain, porque não compila).
2. **alpine|debian|ubuntu** (`sh/rootfs/<distro>.sh`): valida o checkpoint
   (básico cedo, completo depois + vermagic), verifica o firmware do device
   (vendored no repo, sem rede), verifica as ferramentas do perfil rootfs
   (`require_tools`, fail-closed, aponta `REQUISITOS.txt`), gera uma **cópia
   crua redimensionada** do builder upstream via `sh/lib/raw-rootfs-builder.py`
   (sentinels versionados: nada editado silenciosamente) e monta o rootfs
   **1024 MiB ext4 sem compressão**, com SHA256, blkid, e2fsck e metadados
   conferidos. Publica `build/rootfs/<distro>/<distro>-STAMP.ext4`.
3. **all**: kernel uma vez + os três rootfs, sequencial.
4. **sources** (`sh/sources/prepare.sh`): baixa/renova as duas receitas
   explicitamente (`--update` ff-only; clones existentes nunca são removidos).
5. **status**: relatório local (checkpoint, módulos, ccache, imagens prontas).

## Diretórios

```text
REQUISITOS.txt      lista apt completa do host (o usuário roda, o builder verifica)
sh/mainline/       scripts de kernel
sh/rootfs/         scripts de Alpine, Debian e Ubuntu
sh/lib/            helpers commons + gerador raw (python3)
sources/recipes/   clones main e rootfs do projeto channel
sources/linux/     clone mainline msm8953/latest (persistente)
sources/mkbootimg/ clone AOSP mkbootimg com SHA fixado
cache/mainline/modules/     módulos do kernel para os rootfs
cache/mainline/checkpoint/  kernel, DTB, config e hashes verificados
cache/mainline/ccache/      cache do compilador
build/mainline/    <device>-mainline-AAAAMMDDHHMMSS.img e DTB etc
build/rootfs/<d>/  <distro>-AAAAMMDDHHMMSS.ext4 (cru)
```

## Tamanhos fixos das imagens ext4 (sem compressão)

- Alpine, Debian e Ubuntu: **1024 MiB** (alinhado com o builder upstream
  atual), mínimo livre 32 MiB (Alpine) / 64 MiB (Debian e Ubuntu), inodes e
  journal conferidos na criação (16384/8 e 32768/16).
- O build falha se a imagem não couber; ele não corta arquivos silenciosamente.
- O build do kernel gera um **boot.img Android**, que NÃO deve ser gravado
  como ext4. Detalhes em `TAMANHOS.txt`.

## conf local (nova lógica de conf)

O device inteiro vem do repo por **conf, não por lógica fixada em script**:

- Kernel: `conf/mainline.conf` do repo — `KERNEL_MAINLINE_CONF` sobrepõe o
  caminho (ponha um `.conf` seu nesta pasta `conf/` e exporte a variável).
- Firmware: `conf/firmware.conf` do repo — `FIRMWARE_CONFIG` sobrepõe.
- USB/identidade de rede: `conf/usb.conf` do repo (usado pelos builders).

## Pin do release do kernel (conf do builder)

Além da conf do device, o builder também versiona a própria identidade em
`conf/` (fail-closed):

- `conf/release.conf` — `KERNEL_RELEASE` + `KERNEL_SUFFIX` pinados (hoje
  `7.3.0-rc7-mainline`): reuse do checkpoint, pós-compilação e status conferem
  o valor e morrem com mensagem clara em qualquer divergência.
- `conf/modules.conf` — contrato de extração (`MODULES_ARCHIVE`,
  `MODULES_TARGET`, `MODULES_REQUIRED`, `MODULES_SHA_MANIFEST`): os módulos
  são conferidos no tar antes de montar qualquer rootfs.

Ritual de bump (a base msm8953/latest mudou): edita UMA linha em
`conf/release.conf` e recompila; o checkpoint antigo é recusado pelos guards
(comportamento esperado). No lado do repo a mesma label é pinnada via
`repo:conf/release-label.config` (CONFIG_LOCALVERSION="-mainline" com
LOCALVERSION_AUTO desligado), então o build sai deterministicamente com o
release pinado e o pin local só confirma.

## Requisitos

- Distro **apt** em x86_64 (Debian/Ubuntu nativo, Mint/Pop!_OS/Kali/Zorin/
  etc. ou WSL2 Ubuntu); o chain é x86_64 preciso.
- **O host é preparado por você** com `REQUISITOS.txt` (o builder nunca roda
  apt nem inicia qualquer instalação; ele só verifica e falha limpa).
- sudo já vem na lista: os scripts do repo chamam sudo direto; em container
  como root garanta o binário presente (está em `REQUISITOS.txt`).
- Internet na primeira compilação (fontes; firmware vem vendored no repo) e
  uns **10+ GB livres** (.work/sources/cache/build).
- A primeira compilação de kernel demora (compilação real, mitigada pelo
  ccache + fontes persistentes); rootfs seguintes reutilizam checkpoint e
  módulos sem recompilar.

## Testado

- Auto-teste `bash test.sh` (sintaxe de todos os scripts, gates de erro,
  status sem host-dependência e o gate "nunca instala dependências").
- GitHub **Codespace** (Ubuntu x86_64 sandbox): teste completo + `--reuse`
  reportando checkpoint ausente de forma limpa + `prepare.sh` clonando as
  receitas de verdade no Linux + fases de compilação provando o fail-closed
  das ferramentas em falta (sem instalar nada, sem compilar).
- Builds de verdade (kernel/rootfs) rodam na SUA máquina Linux, nunca aqui.
- Nenhuma branch ou workflow do GitHub é modificado.
