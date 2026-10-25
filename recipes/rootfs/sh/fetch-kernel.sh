#!/usr/bin/env bash
# Reuse an already successful mainline.yml checkpoint (never dispatch a build).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "${GITHUB_ACTIONS:-}" = true ] || { echo 'ERROR: Local builds reuse out/kernel/checkpoint; no CI download needed.' >&2; exit 1; }
[ -n "${GITHUB_REPOSITORY:-}" ] || { echo 'ERROR: GITHUB_REPOSITORY missing.' >&2; exit 1; }
command -v gh >/dev/null || { echo 'ERROR: GitHub CLI missing.' >&2; exit 1; }
[ -n "${GH_TOKEN:-}" ] || { echo 'ERROR: GH_TOKEN missing.' >&2; exit 1; }
# Verify the workflow ID; selecting by path alone can reject real mainline runs.

#------------------------------------------------------------------#
source "$ROOT/sh/ui.sh"

mainline_workflow_id="$(gh api "repos/$GITHUB_REPOSITORY/actions/workflows/mainline.yml" --jq '.id')"
[[ "$mainline_workflow_id" =~ ^[0-9]+$ ]] || { echo 'ERROR: Kernel workflow ID unavailable.' >&2; exit 1; }
is_mainline_run() {
  local run="$1"
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$run" \
    --jq "select(.conclusion == \"success\" and .head_branch == \"main\" and .workflow_id == $mainline_workflow_id) | .id" | grep -Fxq "$run"
}
artifact_for_run() {
  gh api "repos/$GITHUB_REPOSITORY/actions/runs/$1/artifacts?per_page=100" \
    --jq '[.artifacts[] | select(.expired == false and (.name | startswith("channel-mainline-kernel-"))) | .name] | first // empty'
}

#------------------------------------------------------------------#

ui_step "selecting the newest successful mainline run with a valid checkpoint artifact"
selected_run=''
selected_artifact=''
# Use the newest successful mainline run with a nonexpired kernel artifact.
while IFS= read -r candidate; do
  [ -n "$candidate" ] || continue
  is_mainline_run "$candidate" || continue
  artifact="$(artifact_for_run "$candidate")"
  if [ -n "$artifact" ]; then
    selected_run="$candidate"
    selected_artifact="$artifact"
    break
  fi
done < <(gh run list --repo "$GITHUB_REPOSITORY" --workflow mainline.yml \
    --branch main --status success --limit 50 --json databaseId --jq '.[].databaseId')
[ -n "$selected_run" ] || { echo 'ERROR: No usable successful mainline kernel checkpoint. Run the dedicated mainline workflow once.' >&2; exit 1; }

#------------------------------------------------------------------#

checkpoint="$ROOT/out/kernel/checkpoint"
rm -rf "$checkpoint"
mkdir -p "$checkpoint"
echo "Reusing kernel checkpoint $selected_artifact (run $selected_run)"
gh run download "$selected_run" --repo "$GITHUB_REPOSITORY" --name "$selected_artifact" --dir "$checkpoint"
KERNEL_CHECKPOINT_DIR="$checkpoint" bash "$ROOT/sh/validate.sh" --basic
printf 'Kernel run: %s\nArtifact: %s\n' "$selected_run" "$selected_artifact"
