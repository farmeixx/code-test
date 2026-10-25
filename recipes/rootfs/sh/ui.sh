#!/usr/bin/env bash
# Shared build-log presentation: phase banners, step subtitles, artifact
# lists and result banners. Presentation only: these helpers print text and
# never change build logic, generated files or exit codes. Bars adapt to the
# text width and the blank lines separating phase blocks are managed here,
# so build scripts never need spacing choreography.

# Last presentation event of this run (banner|step|success|saved|failed).
# It is exported, so a script that starts a child build hands the child a
# spaced banner instead of gluing it under the parent's last output.
UI_LAST="${UI_LAST:-}"

#------------------------------------------------------------------#

# Letter-space words: "BUILD ROOTFS" -> " B U I L D   R O O T F S".
ui_spaced_text() {
  printf '%s' " $(printf '%s' "$*" | sed -E 's/(.)/\1 /g;s/ $//')"
}

# Letter-space words for banner readability and print one line.
ui_spaced() {
  printf '%s\n' "$(ui_spaced_text "$@")"
}

# Bar of '=' that completes the text: spaced-text width plus one margin
# column on each side, so the frame never ends before the banner text.
ui_bar_for() {
  local s
  s="$(ui_spaced_text "$@")"
  printf '%s\n' "$(printf '%*s' $(( ${#s} + 2 )) '' | tr ' ' '=')"
}

# Phase banner, e.g.: ui_banner "BUILDING" "ROOTFS" "UBUNTU". A new phase
# gets a blank line above when something was already on screen and a blank
# line below before the first step of the phase.
ui_banner() {
  local prev
  prev="$UI_LAST"
  export UI_LAST='banner'
  if [ -n "$prev" ]; then printf '\n'; fi
  ui_bar_for "$@"
  ui_spaced "$@"
  ui_bar_for "$@"
  printf '\n'
}

# One-line step subtitle beneath a phase banner. Steps separate from the
# previous block with a blank line; right after a banner that separation
# already exists (the banner's trailing blank), so no extra gap.
ui_step() {
  if [ "$UI_LAST" != 'banner' ]; then
    printf '\n'
  fi
  printf '%s\n' "$*"
  export UI_LAST='step'
}

# Success summary line, e.g.: ui_saved "boot.img" "out/kernel/images/boot.img".
ui_saved() {
  if [ "$UI_LAST" = 'success' ] || [ "$UI_LAST" = 'saved' ]; then
    printf '\n'
  fi
  printf '%s\n' "$1 saved in $2"
  export UI_LAST='saved'
}

# Final success banner; callers list ui_saved lines below it.
ui_success() {
  ui_bar_for "BUILD SUCCESSFUL"
  ui_spaced "BUILD SUCCESSFUL"
  ui_bar_for "BUILD SUCCESSFUL"
  export UI_LAST='success'
}

# Final failure banner. Printed to stderr so failures stand out.
ui_failed() {
  local prev
  prev="$UI_LAST"
  export UI_LAST='failed'
  if [ -n "$prev" ]; then printf '\n' >&2; fi
  ui_bar_for "BUILD FAILED" >&2
  ui_spaced "BUILD FAILED" >&2
  ui_bar_for "BUILD FAILED" >&2
}
