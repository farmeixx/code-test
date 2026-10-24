# conf/ — overrides locais (opcional)

Esta pasta fica vazia por padrao: sem override, o builder usa a configuracao
do proprio repo (a nova logica de conf vive la, versionada):

- `conf/mainline.conf` (branch main) — fonte do kernel (URL/REF), cross-compile,
  fragments, simbolos exigidos, DTB, boot image, cmdline e mkbootimg fixado.
- `conf/firmware.conf` (branch rootfs) — firmware do device (vendored ou clone).
- `conf/usb.conf` (branch rootfs) — identidade USB-RNDIS (MACs, IP, iface).

## Como sobreporem localmente

O repo aceita ponteiros de conf por variavel. Crie aqui o seu arquivo e
exporte a variavel antes de rodar:

```sh
export KERNEL_MAINLINE_CONF="$PWD/conf/mainline-local.conf"   # kernel
bash sh/mainline/build.sh

export FIRMWARE_CONFIG="$PWD/conf/firmware-local.conf"       # firmware
bash sh/rootfs/ubuntu.sh
```

Precisa em cada conf: os mesmos campos do repo (o local morre com mensagem
clara se faltar algo — fail-closed, sem valores implícitos).
