# conf/ — pin do builder + overrides locais (opcional)

Esta pasta nao fica mais vazia: dois arquivos versionados definem a identidade
do kernel que este builder empacota e extrai (fail-closed: sem eles o builder
morre na inicializacao, antes de tocar em qualquer cache):

- `conf/release.conf` — `KERNEL_RELEASE` + `KERNEL_SUFFIX` pinados (hoje
  `7.3.0-rc7-mainline`). Todos os guards (checkpoint, pos-compilacao, status)
  morrem com mensagem clara se um release divergir do pin.
- `conf/modules.conf` — contrato de extracao de modulos: `MODULES_ARCHIVE`
  (nome do tar dentro do checkpoint, derivado do pin), `MODULES_TARGET`
  (caminho lib/modules/<release>), `MODULES_REQUIRED` (modulos obrigatorios
  conferidos no tar antes de montar qualquer rootfs) e `MODULES_SHA_MANIFEST`.

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

## Ritual de bump (quando a base msm8953/latest mudar)

A label do release no lado do repo tambem e pinnada (`repo:conf/release-label.config`
na secao do `conf/mainline.conf`), entao o kernel compilado sai exatamente
como o pin espera: CONFIG_LOCALVERSION="-mainline" com LOCALVERSION_AUTO
desligado. Se a BASE mudar (novo rc/soplevel no Makefile), o guard recusa o
checkpoint antigo: edite UMA linha em `conf/release.conf` (novo
`KERNEL_RELEASE`) e recompile — nada migra silenciosamente.
